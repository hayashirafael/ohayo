import XCTest
@testable import Ohayo

@MainActor
final class RenewalEngineTests: XCTestCase {
    var detector: MockDetector!
    var clock: FakeClock!
    var engine: RenewalEngine!
    var renewed: [URL] = []
    /// Ancorado no relógio real: os Timers do engine armam no RunLoop de
    /// verdade — datas fake no passado fariam o timer disparar durante o teste.
    let now = Date()
    let conta = URL(fileURLWithPath: "/tmp/conta-renew").standardizedFileURL

    override func setUp() async throws {
        detector = MockDetector()
        clock = FakeClock(now: now)
        engine = RenewalEngine(
            detector: detector,
            clock: clock,
            retryJitter: { _, _ in 1 }
        )
        renewed = []
        engine.onRenew = { [weak self] url, _ in
            self?.renewed.append(url)
            return .completed
        }
    }

    func testArmaNoFimDaJanelaAtiva() async {
        detector.end = now.addingTimeInterval(3600)
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(engine.nextRenewal[conta], now.addingTimeInterval(3600))
        XCTAssertTrue(renewed.isEmpty)
    }

    /// Criar um agendamento contínuo não pode consumir quota sem uma escolha
    /// explícita do usuário.
    func testContaSemJanelaNaoFazBootstrapSemOptIn() async {
        detector.end = nil
        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        XCTAssertNil(engine.nextRenewal[conta])
        XCTAssertTrue(renewed.isEmpty)

        await engine.rearmAll()
        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        XCTAssertTrue(renewed.isEmpty)
    }

    func testCooldownPersistidoArmaDeadlineEDisparaQuandoExpira() async {
        detector.end = nil
        let notBefore = now.addingTimeInterval(300)

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
            bootstrapNotBefore: [conta: notBefore],
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
        await engine.configure(
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
        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
            bootstrapNotBefore: [
                conta: now.addingTimeInterval(SessionDetector.blockDuration)
            ],
            paused: false
        )
        XCTAssertEqual(renewed, [conta])
    }

    func testCooldownEhSubstituidoQuandoTranscriptCriaJanela() async {
        detector.end = nil
        await engine.configure(
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

        await engine.configure(
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
        engine.onRenew = { _, _ in
            attempts += 1
            return .needsAttention
        }

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
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

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
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
        engine.onRenew = { _, _ in
            attempts += 1
            return .retryableFailure
        }
        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
            paused: false
        )
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(engine.nextRenewal[conta])

        await engine.configure(
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
        engine.onRenew = { _, _ in
            attempts += 1
            return .retryableFailure
        }
        await engine.configure(
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
        engine.onRenew = { _, _ in
            attempts += 1
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { release = $0 }
            return .retryableFailure
        }

        let initialConfigure = Task { @MainActor in
            await self.engine.configure(
                accounts: [self.conta],
                bootstrapAccounts: [self.conta],
                paused: false
            )
        }
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        release?.resume()
        release = nil
        await initialConfigure.value

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
        engine.onRenew = { _, _ in
            attempts += 1
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { release = $0 }
            return .completed
        }

        let initialConfigure = Task { @MainActor in
            await self.engine.configure(
                accounts: [self.conta],
                bootstrapAccounts: [self.conta],
                paused: false
            )
        }
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [],
            paused: false
        )
        release?.resume()
        release = nil
        await initialConfigure.value

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
        var recoveries: [RenewalRecoveryState?] = []
        engine.onRecoveryState = { _, recovery in
            recoveries.append(recovery)
        }
        engine.onRenew = { _, _ in
            attempts += 1
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { release = $0 }
            return .retryableFailure
        }

        let initialConfigure = Task { @MainActor in
            await self.engine.configure(
                accounts: [self.conta],
                bootstrapAccounts: [self.conta],
                recoveryStates: [:],
                accountRevisions: [self.conta: "v1"],
                paused: false
            )
        }
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
            recoveryStates: [:],
            accountRevisions: [conta: "v2"],
            paused: false
        )
        XCTAssertEqual(attempts, 1)

        release?.resume()
        release = nil
        await initialConfigure.value

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            engine.nextRenewal[conta],
            now.addingTimeInterval(SessionDetector.blockDuration)
        )
        XCTAssertEqual(
            recoveries.compactMap { $0 }.last,
            .cooldown(
                notBefore: now.addingTimeInterval(
                    SessionDetector.blockDuration
                ),
                bootstrapOrigin: true
            )
        )
    }

    func testReinicioRestauraCooldownSemDuplicarBootstrap() async {
        detector.end = nil
        var persisted: RenewalRecoveryState?
        engine.onRecoveryState = { _, recovery in
            if recovery != nil { persisted = recovery }
        }
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(renewed, [conta])
        let recovery = try! XCTUnwrap(persisted)

        let restarted = RenewalEngine(detector: detector, clock: clock)
        restarted.onRenew = { [weak self] url, _ in
            self?.renewed.append(url)
            return .completed
        }
        await restarted.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
            recoveryStates: [conta: recovery],
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
        engine.onRecoveryState = { _, recovery in
            if recovery != nil { persisted = recovery }
        }
        var triggers: [RenewalEngine.Trigger] = []
        engine.onRenew = { _, trigger in
            triggers.append(trigger)
            return .launched
        }
        await engine.configure(
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

        let restarted = RenewalEngine(detector: detector, clock: clock)
        restarted.onRenew = { _, trigger in
            triggers.append(trigger)
            return .launched
        }
        await restarted.configure(
            accounts: [conta],
            bootstrapAccounts: [conta],
            recoveryStates: [conta: recovery],
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
        engine.onRecoveryState = { _, recovery in
            if recovery != nil { persisted = recovery }
        }
        engine.onRenew = { _, _ in .retryableFailure }
        await engine.configure(
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
        let restarted = RenewalEngine(
            detector: detector,
            clock: clock,
            retryJitter: { _, _ in 1 }
        )
        restarted.onRenew = { _, trigger in
            triggers.append(trigger)
            return .completed
        }
        await restarted.configure(
            accounts: [conta],
            bootstrapAccounts: [],
            recoveryStates: [conta: recovery],
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
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        clock.now = now.addingTimeInterval(2 * 3600)
        detector.end = nil
        await engine.handleWake()
        XCTAssertEqual(renewed, [conta])
    }

    /// Depois de renovar, re-arma no fim da janela recém-aberta (encadeia).
    func testRenovacaoEncadeiaProximaJanela() async {
        detector.end = now.addingTimeInterval(3600)
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        clock.now = now.addingTimeInterval(2 * 3600)
        detector.end = nil
        engine.onRenew = { [weak self] url, _ in
            guard let self else { return .completed }
            self.renewed.append(url)
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
        engine.onRenew = { [weak self] url, _ in
            attempts += 1
            guard attempts > 1 else { return .retryableFailure }
            self?.renewed.append(url)
            self?.detector.end = self?.clock.now.addingTimeInterval(5 * 3600)
            return .completed
        }
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
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
        engine.onRenew = { _, _ in
            attempts += 1
            return .retryableFailure
        }

        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
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
        engine.onRenew = { [weak self] _, _ in
            self?.clock.now = self?.now.addingTimeInterval(70) ?? Date()
            return .retryableFailure
        }

        await engine.configure(
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
        engine.onRenew = { _, trigger in
            triggers.append(trigger)
            return .launched
        }

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [],
            recoveryStates: [
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

        await engine.configure(
            accounts: [conta],
            bootstrapAccounts: [],
            accountProviders: [conta: .codex],
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

        await engine.configure(
            accounts: [real, alias],
            bootstrapAccounts: [real, alias],
            bootstrapNotBefore: [real: earlier, alias: later],
            paused: false
        )

        let canonical =
            ProviderAccountContext.canonicalAccountDirectory(real)
        XCTAssertEqual(engine.nextRenewal[canonical], later)
        XCTAssertTrue(renewed.isEmpty)
    }

    func testPausadoNaoArmaNemRenova() async {
        detector.end = now.addingTimeInterval(3600)
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: true)
        XCTAssertNil(engine.nextRenewal[conta])
        clock.now = now.addingTimeInterval(2 * 3600)
        await engine.handleWake()
        XCTAssertTrue(renewed.isEmpty)
    }

    /// Segundo wake logo após a renovação não renova de novo.
    func testWakeConsecutivoNaoRenovaDeNovo() async {
        detector.end = now.addingTimeInterval(60)
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        clock.now = now.addingTimeInterval(120)
        detector.end = nil
        await engine.handleWake() // catch-up renova
        await engine.handleWake() // nada armado, nada perdido
        XCTAssertEqual(renewed, [conta])
    }

    func testContaRemovidaDoSetDesarma() async {
        detector.end = now.addingTimeInterval(3600)
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertNotNil(engine.nextRenewal[conta])
        await engine.configure(accounts: [], bootstrapAccounts: [], paused: false)
        XCTAssertNil(engine.nextRenewal[conta])
    }

    func testContaRemovidaEReadicionadaSemJanelaFazNovoBootstrap() async {
        detector.end = nil
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)
        XCTAssertEqual(renewed, [conta])

        await engine.configure(accounts: [], bootstrapAccounts: [], paused: false)
        await engine.configure(accounts: [conta], bootstrapAccounts: [conta], paused: false)

        XCTAssertEqual(renewed, [conta, conta])
    }
}
