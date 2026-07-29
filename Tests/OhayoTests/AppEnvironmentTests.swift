import XCTest
@testable import Ohayo

/// Regressão do bug "um passo atrás": `@Published` publica no willSet, então
/// o sink de `$tasks` NÃO pode ler `state.tasks` sincronamente — leria a
/// lista antiga e reconfiguraria os motores sem a mudança recém-feita.
@MainActor
final class AppEnvironmentTests: XCTestCase {
    private struct NoopTerminalLauncher: TerminalLaunching {
        func launch(_ message: Message) async -> Result<Void, RunnerError> { .success(()) }
    }

    private final class BlockingTerminalLauncher: TerminalLaunching {
        private(set) var calls = 0
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?

        func launch(
            _ message: Message
        ) async -> Result<Void, RunnerError> {
            calls += 1
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { release = $0 }
            return .success(())
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func finish() {
            release?.resume()
            release = nil
        }
    }

    private final class MutableClock: Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "ohayo-test-\(UUID().uuidString)")!
        d.set([String](), forKey: "registeredAccounts")
        return d
    }

    // O scheduler usa NSTimer real, mas o launcher é fake: mesmo uma data fake
    // vencida nunca abre Terminal.app durante a suíte.
    private var activeScheduler: TaskScheduler?

    override func tearDown() async throws {
        await activeScheduler?.configure(tasks: [], paused: true)
        activeScheduler = nil
        try await super.tearDown()
    }

    private func makeEnv(clock: MutableClock) -> (AppEnvironment, AppState, TaskScheduler) {
        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        let env = AppEnvironment(state: state, taskScheduler: scheduler,
                                 terminalLauncher: NoopTerminalLauncher(),
                                 authenticationChecker: AllowAllAuthenticationChecker(),
                                 probeCLIs: false)
        activeScheduler = scheduler
        return (env, state, scheduler)
    }

    private func fixedTask(times: [Int]) -> ScheduledTask {
        ScheduledTask(uid: UUID(), repetition: .fixed, times: times, weekdays: Set(1...7))
    }

    private func drain(_ env: AppEnvironment) async {
        await env.reconfigureTask?.value
    }

    func testCriarTarefaRefleteNoSchedulerImediatamente() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, scheduler) = makeEnv(clock: clock)
        await drain(env)

        let t = fixedTask(times: [764]) // 12:44
        state.tasks.append(t)
        await drain(env)

        XCTAssertEqual(scheduler.nextFires[t.uid], date(2099, 7, 9, 12, 44))
    }

    func testEditarTarefaAplicaOConteudoNovoNaoOAnterior() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, scheduler) = makeEnv(clock: clock)
        let t = fixedTask(times: [764]) // 12:44
        state.tasks.append(t)
        await drain(env)

        var editada = t
        editada.times = [770] // 12:50
        state.tasks[0] = editada
        await drain(env)

        XCTAssertEqual(scheduler.nextFires[t.uid], date(2099, 7, 9, 12, 50))
    }

    func testRemoverTarefaSaiDoScheduler() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, scheduler) = makeEnv(clock: clock)
        let t = fixedTask(times: [764])
        state.tasks.append(t)
        await drain(env)
        XCTAssertNotNil(scheduler.nextFires[t.uid])

        state.tasks.removeAll { $0.uid == t.uid }
        await drain(env)

        XCTAssertNil(scheduler.nextFires[t.uid])
    }

    func testReconfigureAntigoNaoRessuscitaTarefaFixaRemovida() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        let detector = MockDetector()
        let launcher = BlockingTerminalLauncher()
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: launcher,
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        activeScheduler = scheduler
        await drain(env)

        let fixed = fixedTask(times: [764])
        var continuous = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        continuous.bootstrapWhenInactive = true
        state.tasks = [fixed, continuous]
        let oldReconfigure = try! XCTUnwrap(env.reconfigureTask)
        await launcher.waitUntilEntered()

        state.tasks = [continuous]
        let newestReconfigure = try! XCTUnwrap(env.reconfigureTask)
        await newestReconfigure.value
        XCTAssertNil(scheduler.nextFires[fixed.uid])

        launcher.finish()
        await oldReconfigure.value

        XCTAssertNil(scheduler.nextFires[fixed.uid])
        XCTAssertEqual(launcher.calls, 1)
    }

    func testContaContinuaVoltaSozinhaQuandoPastaReaparece() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-offline-return-\(UUID().uuidString)")
        let account = root.appendingPathComponent("account")
        defer { try? fm.removeItem(at: root) }
        let detector = MockDetector()
        let expectedEnd = Date().addingTimeInterval(3_600)
        detector.end = expectedEnd
        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler()
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: NoopTerminalLauncher(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        activeScheduler = scheduler
        var task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "status",
                kind: .claude,
                configDir: account.path
            ),
            repetition: .continuous
        )
        task.bootstrapWhenInactive = false
        state.tasks = [task]
        await drain(env)
        XCTAssertTrue(state.nextRenewals.isEmpty)

        try fm.createDirectory(
            at: account.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        await env.statusTick()
        await drain(env)

        let canonical =
            ProviderAccountContext.canonicalAccountDirectory(account)
        XCTAssertEqual(state.nextRenewals[canonical], expectedEnd)
    }

    /// Regressão do bug "menu não atualiza a próxima schedule": o tick periódico
    /// precisa publicar uma mudança em `AppState` para o menu (que lê horários
    /// via `Date()` em computed properties) recomputar. Sem o pulso, `rearmAll`
    /// faz early-return sem mutar nada e o `objectWillChange` nunca dispara.
    func testStatusTickPublicaPulsoDeUI() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, _) = makeEnv(clock: clock)
        await drain(env)

        let antes = state.uiHeartbeat
        await env.statusTick()

        XCTAssertNotEqual(state.uiHeartbeat, antes)
    }

    func testRefreshWindowEndsPublicaFimDeJanelaPorContaAgendada() async {
        let defaults = UserDefaults(suiteName: "ohayo-test-\(UUID().uuidString)")!
        let state = AppState(defaults: defaults)
        var task = ScheduledTask(uid: UUID(), command: AppState.defaultMessage)
        task.repetition = .fixed // sem times: nenhum timer arma
        state.tasks = [task]
        let detector = MockDetector()
        let end = Date().addingTimeInterval(3600)
        detector.end = end
        let env = AppEnvironment(state: state, taskScheduler: TaskScheduler(),
                                 detector: detector, probeCLIs: false)
        await env.refreshWindowEnds()
        XCTAssertEqual(state.windowEnds[AppState.defaultConfigDir.standardizedFileURL], end)

        // Janela que sumiu (nil) sai do dicionário no próximo refresh.
        detector.end = nil
        await env.refreshWindowEnds()
        XCTAssertTrue(state.windowEnds.isEmpty)
    }

    func testRefreshWindowEndsPublicaQuotaIndisponivelSemInventarJanela() async {
        let defaults = UserDefaults(suiteName: "ohayo-test-\(UUID().uuidString)")!
        let state = AppState(defaults: defaults)
        state.tasks = [
            ScheduledTask(uid: UUID(), command: AppState.defaultMessage)
        ]
        let detector = MockDetector()
        detector.stateOverride = .unavailable(reason: "schema changed")
        let env = AppEnvironment(
            state: state,
            taskScheduler: TaskScheduler(),
            detector: detector,
            probeCLIs: false
        )

        await env.refreshWindowEnds()

        XCTAssertTrue(state.windowEnds.isEmpty)
        XCTAssertEqual(
            state.quotaUnavailableReasons[
                AppState.defaultConfigDir.standardizedFileURL
            ],
            "schema changed"
        )
    }

    /// Disparo manual do botão "Executar agora": comando padrão (Claude,
    /// runInTerminal resolvido = true) passa pelo launcher fake e registra
    /// launch com origem manual (abrir o Terminal não prova conclusão).
    func testFireNowRegistraSucessoComOrigemManual() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, _) = makeEnv(clock: clock)
        await drain(env)

        let t = fixedTask(times: [764])
        await env.fireNow(t)

        XCTAssertEqual(state.history.first?.origin, .manual)
        XCTAssertEqual(state.history.first?.result, .launched)
    }

    /// Conta explícita cuja pasta sumiu: não dispara; registra a falha com
    /// origem manual (mesmo guard do taskScheduler.onFire).
    func testFireNowComPastaAusenteRegistraFalhaSemDisparar() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, _) = makeEnv(clock: clock)
        await drain(env)

        var msg = AppState.defaultMessage
        msg.uid = nil
        msg.configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-inexistente-\(UUID().uuidString)").path
        let t = ScheduledTask(uid: UUID(), command: msg, repetition: .fixed,
                              times: [764], weekdays: Set(1...7))

        await env.fireNow(t)

        XCTAssertEqual(state.history.first?.origin, .manual)
        guard case .failure = state.history.first?.result else {
            return XCTFail("esperava .failure, veio \(String(describing: state.history.first?.result))")
        }
    }

    /// Ação explícita do usuário sobrepõe a pausa da conta: "Executar agora"
    /// numa conta pausada dispara mesmo assim e registra launch (ao contrário
    /// dos disparos agendados/renovação, descartados enquanto pausada).
    func testFireNowSobrepoePausaDaConta() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, _) = makeEnv(clock: clock)
        await drain(env)

        // A tarefa padrão mira a conta Claude padrão (~/.claude); pausa ela.
        state.setPaused(AppState.defaultConfigDir, true)
        let t = fixedTask(times: [764])
        await env.fireNow(t)

        XCTAssertEqual(state.history.first?.origin, .manual)
        XCTAssertEqual(state.history.first?.result, .launched)
    }

    func testComposicaoCodexSemContaExplicitaUsaCodexHomePadrao() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-codex-home-\(UUID().uuidString).txt")
        let binary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-codex-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        printf '%s' "$CODEX_HOME" > '\(envFile.path)'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path
        )
        defer {
            try? FileManager.default.removeItem(at: binary)
            try? FileManager.default.removeItem(at: envFile)
        }

        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler()
        activeScheduler = scheduler
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            terminalLauncher: NoopTerminalLauncher(),
            runner: CommandRunner(timeout: 5, binaryOverride: binary),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        var command = Message(text: "1+1", kind: .codex)
        command.runInTerminal = false
        let task = ScheduledTask(uid: UUID(), command: command)

        await env.fireNow(task)

        XCTAssertEqual(
            try String(contentsOf: envFile, encoding: .utf8),
            AppState.defaultCodexConfigDir.path
        )
        XCTAssertEqual(state.history.first?.result, .success)
    }

    func testMudancaDeFusoReconfiguraSchedulers() async {
        let clock = MutableClock(date(2099, 7, 9, 12, 40))
        let (env, state, _) = makeEnv(clock: clock)
        let task = fixedTask(times: [764]) // 12:44
        state.tasks.append(task)
        await drain(env)
        XCTAssertTrue(state.history.isEmpty)

        // Simula o relógio local já depois da ocorrência armada e publica a
        // mesmo caminho que os observers de mudança de fuso/wake chamam. O
        // catch-up prova que o AppEnvironment encaminha o evento aos motores.
        clock.now = date(2099, 7, 9, 12, 45)
        await env.handleWake()

        XCTAssertEqual(state.history.first?.origin, .agenda)
        XCTAssertEqual(state.history.first?.result, .launched)
    }

    func testContinuoNovoSemOptInNaoDisparaSemJanelaAtiva() async {
        let detector = MockDetector()
        detector.end = nil
        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler()
        activeScheduler = scheduler
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: NoopTerminalLauncher(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        await drain(env)

        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = false
        state.tasks = [task]
        await drain(env)

        XCTAssertTrue(state.history.isEmpty)
    }

    func testBootstrapJaEnfileiradoRevalidaOptOutAntesDoDispatch() async {
        let detector = MockDetector()
        let launcher = MockTerminalLauncher()
        let state = AppState(defaults: freshDefaults())
        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = false
        state.tasks = [task]
        let scheduler = TaskScheduler()
        activeScheduler = scheduler
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: launcher,
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        await drain(env)

        let outcome = await env.dispatchRenewal(
            account: AppState.defaultConfigDir,
            trigger: .bootstrap
        )

        XCTAssertEqual(outcome, .paused)
        XCTAssertEqual(launcher.calls, 0)
        XCTAssertTrue(state.history.isEmpty)
    }

    func testContinuoComOptInFazBootstrapSemJanelaAtiva() async {
        let detector = MockDetector()
        detector.end = nil
        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler()
        activeScheduler = scheduler
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: NoopTerminalLauncher(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        await drain(env)

        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        state.tasks = [task]
        await drain(env)

        XCTAssertEqual(state.history.first?.origin, .renewal)
        XCTAssertEqual(state.history.first?.result, .launched)
    }

    func testContaPausadaNaoConsomeBootstrapERetomaAoDespausar() async {
        let detector = MockDetector()
        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler()
        activeScheduler = scheduler
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: NoopTerminalLauncher(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        state.setPaused(AppState.defaultConfigDir, true)
        state.tasks = [task]
        await drain(env)
        XCTAssertTrue(state.history.isEmpty)

        state.setPaused(AppState.defaultConfigDir, false)
        await drain(env)

        XCTAssertEqual(state.history.count, 1)
        XCTAssertEqual(state.history.first?.result, .launched)
    }

    func testContinuosDuplicadosNoMesmoAccountFalhamFechado() async {
        let detector = MockDetector()
        let state = AppState(defaults: freshDefaults())
        let scheduler = TaskScheduler()
        activeScheduler = scheduler
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: NoopTerminalLauncher(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        var optOut = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        optOut.bootstrapWhenInactive = false
        var optIn = optOut
        optIn.uid = UUID()
        optIn.bootstrapWhenInactive = true

        state.tasks = [optOut, optIn]
        await drain(env)

        XCTAssertTrue(state.history.isEmpty)
    }

    func testRestartImediatoNaoRepeteBootstrapPersistido() async {
        let defaults = freshDefaults()
        let detector = MockDetector()
        let state = AppState(defaults: defaults)
        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        state.tasks = [task]
        let firstScheduler = TaskScheduler()
        activeScheduler = firstScheduler
        let first = AppEnvironment(
            state: state,
            taskScheduler: firstScheduler,
            detector: detector,
            terminalLauncher: NoopTerminalLauncher(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        await drain(first)
        XCTAssertEqual(state.history.count, 1)

        let reloaded = AppState(defaults: defaults)
        let secondScheduler = TaskScheduler()
        activeScheduler = secondScheduler
        let second = AppEnvironment(
            state: reloaded,
            taskScheduler: secondScheduler,
            detector: MockDetector(),
            terminalLauncher: NoopTerminalLauncher(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        await drain(second)

        XCTAssertEqual(reloaded.history.count, 1)
    }

    func testFalhaTransitoriaDeBootstrapPreservaBackoffAposRestart() async {
        let defaults = freshDefaults()
        let detector = MockDetector()
        let runner = MockRunner()
        runner.result = .failure(.timeout)
        let state = AppState(defaults: defaults)
        var command = AppState.defaultMessage
        command.runInTerminal = false
        var task = ScheduledTask(
            uid: UUID(),
            command: command,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        state.tasks = [task]
        let scheduler = TaskScheduler()
        activeScheduler = scheduler
        let env = AppEnvironment(
            state: state,
            taskScheduler: scheduler,
            detector: detector,
            terminalLauncher: NoopTerminalLauncher(),
            runner: runner,
            notifier: MockNotifier(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )

        await drain(env)

        XCTAssertEqual(runner.calls, 1)
        guard case .retry(let retryAt, let attempt, let bootstrapOrigin) =
                state.renewalRecoveryState(for: task) else {
            return XCTFail("esperava retry persistido")
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertTrue(bootstrapOrigin)
        XCTAssertGreaterThan(retryAt, Date())
        XCTAssertFalse(state.shouldBootstrap(task))

        let reloaded = AppState(defaults: defaults)
        let persistedTask = try! XCTUnwrap(reloaded.tasks.first)
        XCTAssertEqual(
            reloaded.renewalRecoveryState(for: persistedTask),
            .retry(
                notBefore: retryAt,
                attempt: 1,
                bootstrapOrigin: true
            )
        )

        let restartedRunner = MockRunner()
        restartedRunner.result = .success("")
        let restartedScheduler = TaskScheduler()
        activeScheduler = restartedScheduler
        let restarted = AppEnvironment(
            state: reloaded,
            taskScheduler: restartedScheduler,
            detector: MockDetector(),
            terminalLauncher: NoopTerminalLauncher(),
            runner: restartedRunner,
            notifier: MockNotifier(),
            authenticationChecker: AllowAllAuthenticationChecker(),
            probeCLIs: false
        )
        await drain(restarted)

        XCTAssertEqual(restartedRunner.calls, 0)
        XCTAssertEqual(
            reloaded.nextRenewals[AppState.defaultConfigDir.standardizedFileURL],
            retryAt
        )
    }
}
