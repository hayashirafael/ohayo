import XCTest
@testable import Ohayo

@MainActor
private final class RenewalTestDriver {
    var dispatch: (ScheduledTask, RenewalEngine.Trigger) async
        -> DispatchOutcome = { _, _ in .completed }
    var persistRecovery: (ScheduledTask, RenewalRecoveryState?) -> Void =
        { _, _ in }
}

@MainActor
final class RenewalEngineTests: XCTestCase {
    var detector: MockDetector!
    var clock: FakeClock!
    var engine: RenewalEngine!
    private var driver: RenewalTestDriver!
    var renewed: [URL] = []
    private var tasksByAccount: [URL: ScheduledTask] = [:]
    /// Ancorado no relógio real: os Timers do engine armam no RunLoop de
    /// verdade — datas fake no passado fariam o timer disparar durante o teste.
    let now = Date()
    let conta = URL(fileURLWithPath: "/tmp/conta-renew").standardizedFileURL

    override func setUp() async throws {
        detector = MockDetector()
        clock = FakeClock(now: now)
        driver = RenewalTestDriver()
        engine = makeEngine(driver: driver)
        renewed = []
        tasksByAccount = [:]
        driver.dispatch = { [weak self] task, _ in
            guard let self else { return .completed }
            self.renewed.append(self.account(of: task))
            return .completed
        }
    }

    private func makeEngine(driver: RenewalTestDriver) -> RenewalEngine {
        RenewalEngine(
            detector: detector,
            clock: clock,
            retryJitter: { _, _ in 1 },
            dispatch: { [driver] task, trigger in
                await driver.dispatch(task, trigger)
            },
            persistRecovery: { [driver] task, recovery in
                driver.persistRecovery(task, recovery)
            }
        )
    }

    private func account(of task: ScheduledTask) -> URL {
        ProviderAccountContext.canonicalAccountDirectory(
            URL(
                fileURLWithPath:
                    task.resolvedCommand.configDir ?? AppState.defaultConfigDir.path
            )
        )
    }

    private func synchronize(
        _ target: RenewalEngine? = nil,
        accounts: Set<URL>,
        bootstrapAccounts: Set<URL>,
        cooldowns: [URL: Date] = [:],
        recoveries: [URL: RenewalRecoveryState]? = nil,
        revisions: [URL: String]? = nil,
        providers: [URL: Provider]? = nil,
        paused: Bool
    ) async {
        let canonicalAccounts = Set(accounts.map {
            ProviderAccountContext.canonicalAccountDirectory($0)
        })
        let canonicalBootstrap = Set(bootstrapAccounts.map {
            ProviderAccountContext.canonicalAccountDirectory($0)
        })
        var canonicalCooldowns: [URL: Date] = [:]
        for (account, deadline) in cooldowns {
            let canonical =
                ProviderAccountContext.canonicalAccountDirectory(account)
            canonicalCooldowns[canonical] = max(
                canonicalCooldowns[canonical] ?? deadline,
                deadline
            )
        }
        let canonicalRecoveries = recoveries.map { values in
            Dictionary(uniqueKeysWithValues: values.map {
                (
                    ProviderAccountContext.canonicalAccountDirectory($0.key),
                    $0.value
                )
            })
        }
        let canonicalRevisions = revisions.map { values in
            Dictionary(uniqueKeysWithValues: values.map {
                (
                    ProviderAccountContext.canonicalAccountDirectory($0.key),
                    $0.value
                )
            })
        }
        let canonicalProviders = providers.map { values in
            Dictionary(uniqueKeysWithValues: values.map {
                (
                    ProviderAccountContext.canonicalAccountDirectory($0.key),
                    $0.value
                )
            })
        }

        let definitions = canonicalAccounts.map { account in
            let provider = canonicalProviders?[account] ?? .claude
            let uid = tasksByAccount[account]?.uid ?? UUID()
            var task = ScheduledTask(
                uid: uid,
                command: Message(
                    text: canonicalRevisions?[account] ?? "renovar",
                    kind: provider == .codex ? .codex : .claude,
                    configDir: account.path
                ),
                repetition: .continuous
            )
            task.bootstrapWhenInactive =
                canonicalBootstrap.contains(account)
            tasksByAccount[account] = task

            let recovery = canonicalRecoveries?[account]
                ?? canonicalCooldowns[account].map {
                    .cooldown(notBefore: $0, bootstrapOrigin: true)
                }
            return ContinuousScheduleDefinition(
                task: task,
                intendedAccount: account,
                availableAccount: account,
                recovery: recovery
            )
        }
        await (target ?? engine).synchronize(
            ContinuousScheduleInput(
                definitions: definitions,
                paused: paused
            )
        )
    }

    func testArmaNoFimDaJanelaAtiva() async {
        detector.end = now.addingTimeInterval(3600)
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(engine.nextRenewal[conta], now.addingTimeInterval(3600))
        XCTAssertTrue(renewed.isEmpty)
    }

    /// Criar um agendamento contínuo não pode consumir quota sem uma escolha
    /// explícita do usuário.
    func testContaSemJanelaNaoFazBootstrapSemOptIn() async {
        detector.end = nil
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        XCTAssertNil(engine.nextRenewal[conta])
        XCTAssertTrue(renewed.isEmpty)

        await engine.rearmAll()
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        XCTAssertTrue(renewed.isEmpty)
    }

    func testCooldownPersistidoArmaDeadlineEDisparaQuandoExpira() async {
        detector.end = nil
        let notBefore = now.addingTimeInterval(300)

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            cooldowns: [conta: notBefore],
            paused: false
        )
        XCTAssertTrue(renewed.isEmpty)
        XCTAssertEqual(engine.nextRenewal[conta], notBefore)

        clock.now = notBefore
        await engine.rearmAll()

        XCTAssertEqual(renewed, [conta])
    }

    /// Com opt-in explícito, faz no máximo um bootstrap enquanto a conta
    /// permanecer configurada nesta instância.
    func testContaSemJanelaFazBootstrapUmaVezComOptIn() async {
        detector.end = nil
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )
        XCTAssertEqual(
            engine.nextRenewal[conta],
            now.addingTimeInterval(SessionDetector.blockDuration)
        )
        XCTAssertEqual(renewed, [conta])

        clock.now = now.addingTimeInterval(121)
        await engine.rearmAll()
        XCTAssertEqual(
            engine.nextRenewal[conta],
            now.addingTimeInterval(SessionDetector.blockDuration)
        )
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            cooldowns: [
                conta: now.addingTimeInterval(SessionDetector.blockDuration)
            ],
            paused: false
        )
        XCTAssertEqual(renewed, [conta])
    }

    func testCooldownEhSubstituidoQuandoTranscriptCriaJanela() async {
        detector.end = nil
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )
        XCTAssertEqual(renewed, [conta])

        let detectedEnd = now.addingTimeInterval(2 * 3600)
        detector.end = detectedEnd
        await engine.rearmAll()

        XCTAssertEqual(engine.nextRenewal[conta], detectedEnd)
        XCTAssertEqual(renewed, [conta])
    }

    func testQuotaIndisponivelNaoFazBootstrapMesmoComOptIn() async {
        detector.stateOverride = .unavailable(reason: "schema changed")

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )

        XCTAssertTrue(renewed.isEmpty)
        XCTAssertNil(engine.nextRenewal[conta])
        XCTAssertEqual(
            engine.quotaUnavailableReasons[conta],
            "schema changed"
        )
    }

    func testNeedsAttentionNaoViraCooldownNemRepeteEmTicks() async {
        detector.end = nil
        var attempts = 0
        driver.dispatch = { _, _ in
            attempts += 1
            return .needsAttention
        }

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            revisions: [conta: "v1"],
            paused: false
        )
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(engine.nextRenewal[conta])

        clock.now = now.addingTimeInterval(
            SessionDetector.blockDuration + 1
        )
        await engine.rearmAll()
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(engine.nextRenewal[conta])

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            revisions: [conta: "v2"],
            paused: false
        )
        XCTAssertEqual(attempts, 2)

        let recoveredEnd = clock.now.addingTimeInterval(3_600)
        detector.end = recoveredEnd
        await engine.rearmAll()
        XCTAssertEqual(engine.nextRenewal[conta], recoveredEnd)
        XCTAssertEqual(attempts, 2)
    }

    func testRevogarOptInCancelaRetryDoBootstrapPendente() async {
        detector.end = nil
        var attempts = 0
        driver.dispatch = { _, _ in
            attempts += 1
            return .retryableFailure
        }
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(engine.nextRenewal[conta])

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        clock.now = now.addingTimeInterval(120)
        await engine.rearmAll()

        XCTAssertEqual(attempts, 1)
        XCTAssertNil(engine.nextRenewal[conta])
    }

    func testRetryPausaDuranteQuotaIndisponivelERetomaDepois() async {
        detector.end = nil
        var attempts = 0
        driver.dispatch = { _, _ in
            attempts += 1
            return .retryableFailure
        }
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )
        XCTAssertEqual(attempts, 1)

        detector.stateOverride = .unavailable(reason: "temporarily unreadable")
        clock.now = now.addingTimeInterval(60)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            engine.quotaUnavailableReasons[conta],
            "temporarily unreadable"
        )

        detector.stateOverride = .inactive
        clock.now = now.addingTimeInterval(61)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 2)
    }

    func testRevogarOptInDuranteDispatchNaoAgendaRetryDepois() async {
        detector.end = nil
        var attempts = 0
        var entered = false
        var entryWaiter: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        driver.dispatch = { _, _ in
            attempts += 1
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { release = $0 }
            return .retryableFailure
        }

        let initialSynchronization = Task { @MainActor in
            await self.synchronize(
                accounts: [self.conta],
                bootstrapAccounts: [self.conta],
                paused: false
            )
        }
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        release?.resume()
        release = nil
        await initialSynchronization.value

        clock.now = now.addingTimeInterval(120)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(engine.nextRenewal[conta])
    }

    func testRevogarOptInDuranteDispatchBemSucedidoNaoArmaCooldown() async {
        detector.end = nil
        var attempts = 0
        var entered = false
        var entryWaiter: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        driver.dispatch = { _, _ in
            attempts += 1
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { release = $0 }
            return .completed
        }

        let initialSynchronization = Task { @MainActor in
            await self.synchronize(
                accounts: [self.conta],
                bootstrapAccounts: [self.conta],
                paused: false
            )
        }
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        release?.resume()
        release = nil
        await initialSynchronization.value

        clock.now = now.addingTimeInterval(SessionDetector.blockDuration + 1)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(engine.nextRenewal[conta])
    }

    func testEditarTaskDuranteDispatchNaoDuplicaNemAplicaOutcomeAntigo() async {
        detector.end = nil
        var attempts = 0
        var entered = false
        var entryWaiter: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        var persisted: [(ScheduledTask, RenewalRecoveryState?)] = []
        driver.persistRecovery = { task, recovery in
            persisted.append((task, recovery))
        }
        driver.dispatch = { _, _ in
            attempts += 1
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { release = $0 }
            return .retryableFailure
        }

        let initialSynchronization = Task { @MainActor in
            await self.synchronize(
                accounts: [self.conta],
                bootstrapAccounts: [self.conta],
                recoveries: [:],
                revisions: [self.conta: "v1"],
                paused: false
            )
        }
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            recoveries: [:],
            revisions: [conta: "v2"],
            paused: false
        )
        XCTAssertEqual(attempts, 1)

        release?.resume()
        release = nil
        await initialSynchronization.value

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            engine.nextRenewal[conta],
            now.addingTimeInterval(SessionDetector.blockDuration)
        )
        XCTAssertEqual(
            persisted.compactMap(\.1).last,
            .cooldown(
                notBefore: now.addingTimeInterval(
                    SessionDetector.blockDuration
                ),
                bootstrapOrigin: true
            )
        )
        XCTAssertEqual(
            persisted.last?.0,
            tasksByAccount[conta],
            "a lease stale deve ser associada à task corrente da conta"
        )
    }

    func testReinicioRestauraCooldownSemDuplicarBootstrap() async {
        detector.end = nil
        var persisted: RenewalRecoveryState?
        driver.persistRecovery = { _, recovery in
            if recovery != nil { persisted = recovery }
        }
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(renewed, [conta])
        let recovery = try! XCTUnwrap(persisted)

        let restartedDriver = RenewalTestDriver()
        restartedDriver.dispatch = { [weak self] task, _ in
            guard let self else { return .completed }
            self.renewed.append(self.account(of: task))
            return .completed
        }
        let restarted = makeEngine(driver: restartedDriver)
        await synchronize(
            restarted,
            accounts: [conta],
            bootstrapAccounts: [conta],
            recoveries: [conta: recovery],
            paused: false
        )

        XCTAssertEqual(renewed, [conta])
        XCTAssertEqual(
            restarted.nextRenewal[conta],
            now.addingTimeInterval(SessionDetector.blockDuration)
        )
    }

    func testReinicioNaoDuplicaHandoffAgendadoComOptIn() async {
        detector.end = now.addingTimeInterval(60)
        var persisted: RenewalRecoveryState?
        driver.persistRecovery = { _, recovery in
            if recovery != nil { persisted = recovery }
        }
        var triggers: [RenewalEngine.Trigger] = []
        driver.dispatch = { _, trigger in
            triggers.append(trigger)
            return .launched
        }
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )
        clock.now = now.addingTimeInterval(120)
        detector.end = nil
        await engine.handleWake()
        XCTAssertEqual(triggers, [.scheduled])
        let recovery = try! XCTUnwrap(persisted)
        XCTAssertEqual(
            recovery,
            .cooldown(
                notBefore: clock.now.addingTimeInterval(
                    SessionDetector.blockDuration
                ),
                bootstrapOrigin: false
            )
        )

        let restartedDriver = RenewalTestDriver()
        restartedDriver.dispatch = { _, trigger in
            triggers.append(trigger)
            return .launched
        }
        let restarted = makeEngine(driver: restartedDriver)
        await synchronize(
            restarted,
            accounts: [conta],
            bootstrapAccounts: [conta],
            recoveries: [conta: recovery],
            paused: false
        )

        XCTAssertEqual(triggers, [.scheduled])
        XCTAssertEqual(
            restarted.nextRenewal[conta],
            clock.now.addingTimeInterval(SessionDetector.blockDuration)
        )
    }

    func testReinicioPreservaRetryAgendadoMesmoSemOptIn() async {
        detector.end = now.addingTimeInterval(60)
        var persisted: RenewalRecoveryState?
        driver.persistRecovery = { _, recovery in
            if recovery != nil { persisted = recovery }
        }
        driver.dispatch = { _, _ in .retryableFailure }
        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        clock.now = now.addingTimeInterval(120)
        detector.end = nil
        await engine.handleWake()
        let recovery = try! XCTUnwrap(persisted)
        XCTAssertEqual(
            recovery,
            .retry(
                notBefore: clock.now.addingTimeInterval(60),
                attempt: 1,
                bootstrapOrigin: false
            )
        )

        var triggers: [RenewalEngine.Trigger] = []
        let restartedDriver = RenewalTestDriver()
        restartedDriver.dispatch = { _, trigger in
            triggers.append(trigger)
            return .completed
        }
        let restarted = makeEngine(driver: restartedDriver)
        await synchronize(
            restarted,
            accounts: [conta],
            bootstrapAccounts: [],
            recoveries: [conta: recovery],
            paused: false
        )
        XCTAssertEqual(
            restarted.nextRenewal[conta],
            clock.now.addingTimeInterval(60)
        )
        XCTAssertTrue(triggers.isEmpty)

        clock.now = clock.now.addingTimeInterval(60)
        await restarted.rearmAll()
        XCTAssertEqual(triggers, [.scheduled])
    }

    /// Catch-up: a janela venceu enquanto o Mac dormia → renova ao acordar.
    func testCatchUpRenovaQuandoJanelaVenceuDormindo() async {
        detector.end = now.addingTimeInterval(3600)
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        clock.now = now.addingTimeInterval(2 * 3600)
        detector.end = nil
        await engine.handleWake()
        XCTAssertEqual(renewed, [conta])
    }

    /// Depois de renovar, re-arma no fim da janela recém-aberta (encadeia).
    func testRenovacaoEncadeiaProximaJanela() async {
        detector.end = now.addingTimeInterval(3600)
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        clock.now = now.addingTimeInterval(2 * 3600)
        detector.end = nil
        driver.dispatch = { [weak self] task, _ in
            guard let self else { return .completed }
            self.renewed.append(self.account(of: task))
            self.detector.end = self.clock.now.addingTimeInterval(5 * 3600) // hi abriu janela nova
            return .completed
        }
        await engine.handleWake()
        XCTAssertEqual(renewed, [conta])
        XCTAssertEqual(engine.nextRenewal[conta], clock.now.addingTimeInterval(5 * 3600))
    }

    /// Falha transitória não encerra a cadeia, mas também não pode criar loop:
    /// espera o backoff antes de tentar novamente.
    func testFalhaTransitoriaTentaDeNovoSomenteAposBackoff() async {
        detector.end = nil
        var attempts = 0
        driver.dispatch = { [weak self] task, _ in
            attempts += 1
            guard attempts > 1 else { return .retryableFailure }
            guard let self else { return .completed }
            self.renewed.append(self.account(of: task))
            self.detector.end = self.clock.now.addingTimeInterval(5 * 3600)
            return .completed
        }
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(renewed.isEmpty)
        XCTAssertEqual(engine.nextRenewal[conta], now.addingTimeInterval(60))

        await engine.rearmAll()
        XCTAssertEqual(attempts, 1)
        clock.now = now.addingTimeInterval(59)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 1)

        clock.now = now.addingTimeInterval(60)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(renewed, [conta])
        XCTAssertEqual(engine.nextRenewal[conta], clock.now.addingTimeInterval(5 * 3600))
    }

    func testFalhasRepetidasUsamBackoffExponencialLimitado() async {
        detector.end = nil
        var attempts = 0
        driver.dispatch = { _, _ in
            attempts += 1
            return .retryableFailure
        }

        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(engine.nextRenewal[conta], now.addingTimeInterval(60))

        clock.now = now.addingTimeInterval(60)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(engine.nextRenewal[conta], now.addingTimeInterval(180))

        clock.now = now.addingTimeInterval(180)
        await engine.rearmAll()
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(engine.nextRenewal[conta], now.addingTimeInterval(420))
    }

    func testBackoffComecaQuandoAFalhaRetorna() async {
        detector.end = nil
        driver.dispatch = { [weak self] _, _ in
            self?.clock.now = self?.now.addingTimeInterval(70) ?? Date()
            return .retryableFailure
        }

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )

        XCTAssertEqual(
            engine.nextRenewal[conta],
            now.addingTimeInterval(130)
        )
    }

    func testCooldownAgendadoRestauradoIndependeDeOptInBootstrap() async {
        detector.end = nil
        let deadline = now.addingTimeInterval(300)
        var triggers: [RenewalEngine.Trigger] = []
        driver.dispatch = { _, trigger in
            triggers.append(trigger)
            return .launched
        }

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            recoveries: [
                conta: .cooldown(
                    notBefore: deadline,
                    bootstrapOrigin: false
                )
            ],
            paused: false
        )
        XCTAssertEqual(engine.nextRenewal[conta], deadline)
        XCTAssertTrue(triggers.isEmpty)

        clock.now = deadline
        await engine.rearmAll()

        XCTAssertEqual(triggers, [.scheduled])
    }

    func testDetectorRecebeProviderPersistidoSemReinferirConta() async {
        detector.end = nil

        await synchronize(
            accounts: [conta],
            bootstrapAccounts: [],
            providers: [conta: .codex],
            paused: false
        )

        XCTAssertEqual(detector.lastProvider, .codex)
    }

    func testCooldownsDeAliasEContaRealDeduplicamSemTrap() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-renew-alias-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? fm.removeItem(at: root) }
        detector.end = nil
        let earlier = now.addingTimeInterval(60)
        let later = now.addingTimeInterval(120)

        await synchronize(
            accounts: [real, alias],
            bootstrapAccounts: [real, alias],
            cooldowns: [real: earlier, alias: later],
            paused: false
        )

        let canonical =
            ProviderAccountContext.canonicalAccountDirectory(real)
        XCTAssertEqual(engine.nextRenewal[canonical], later)
        XCTAssertTrue(renewed.isEmpty)
    }

    func testPausadoNaoArmaNemRenova() async {
        detector.end = now.addingTimeInterval(3600)
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: true)
        XCTAssertNil(engine.nextRenewal[conta])
        clock.now = now.addingTimeInterval(2 * 3600)
        await engine.handleWake()
        XCTAssertTrue(renewed.isEmpty)
    }

    /// Segundo wake logo após a renovação não renova de novo.
    func testWakeConsecutivoNaoRenovaDeNovo() async {
        detector.end = now.addingTimeInterval(60)
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        clock.now = now.addingTimeInterval(120)
        detector.end = nil
        await engine.handleWake() // catch-up renova
        await engine.handleWake() // nada armado, nada perdido
        XCTAssertEqual(renewed, [conta])
    }

    func testContaRemovidaDoSetDesarma() async {
        detector.end = now.addingTimeInterval(3600)
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertNotNil(engine.nextRenewal[conta])
        await synchronize(accounts: [], bootstrapAccounts: [], paused: false)
        XCTAssertNil(engine.nextRenewal[conta])
    }

    func testContaRemovidaEReadicionadaSemJanelaFazNovoBootstrap() async {
        detector.end = nil
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(renewed, [conta])

        await synchronize(accounts: [], bootstrapAccounts: [], paused: false)
        await synchronize(accounts: [conta], bootstrapAccounts: [conta], paused: false)

        XCTAssertEqual(renewed, [conta, conta])
    }
}
