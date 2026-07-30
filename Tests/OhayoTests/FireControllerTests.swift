import XCTest
@testable import Ohayo

private extension FireController {
    /// Mantém os cenários legados legíveis sem reintroduzir um adapter de
    /// `Message` no módulo de produção: o teste atravessa a fronteira tipada.
    @discardableResult
    func fire(
        message: Message,
        origin: FireOrigin,
        taskName: String? = nil
    ) async -> DispatchOutcome {
        await fire(.direct(
            message,
            origin: origin,
            taskName: taskName
        ))
    }
}

/// Relógio fake para testes determinísticos (compartilhado com RenewalEngineTests).
final class FakeClock: Clock {
    var now: Date
    init(now: Date) { self.now = now }
}

final class MockDetector: SessionDetecting {
    var end: Date?
    var stateOverride: QuotaWindowState?
    var lastAccount: URL?
    var lastProvider: Provider?
    var calls = 0
    func quotaWindowState(
        account: URL,
        provider: Provider
    ) async -> QuotaWindowState {
        calls += 1
        lastAccount = account
        lastProvider = provider
        if let stateOverride { return stateOverride }
        guard let end else { return .inactive }
        return .active(until: end)
    }
}

final class MockRunner: CommandRunning {
    var result: Result<String, RunnerError> = .success("")
    var calls = 0
    var lastMessage: Message?
    var lastDispatch: PreparedDispatch?
    func run(
        _ dispatch: PreparedDispatch
    ) async -> Result<String, RunnerError> {
        calls += 1
        lastDispatch = dispatch
        lastMessage = dispatch.message
        return result
    }
}

final class MockNotifier: Notifying {
    var messages: [String] = []
    var titles: [String] = []
    var responses: [(messageText: String, response: String)] = []
    var successes: [(title: String, body: String)] = []
    func notifyFailure(title: String, message: String) {
        titles.append(title)
        messages.append(message)
    }
    func notifyResponse(title: String, response: String) {
        responses.append((title, response))
    }
    func notifySuccess(title: String, body: String) {
        successes.append((title, body))
    }
}

final class MockResponseFileWriter: ResponseFileWriting {
    struct Call: Equatable {
        let response: String
        let format: ResponseFileFormat
        let directory: URL
        let taskName: String?
        let date: Date
    }

    var result: Result<URL, ResponseFileWriteError> = .success(
        URL(fileURLWithPath: "/tmp/resposta.md")
    )
    var calls: [Call] = []

    func write(
        response: String,
        format: ResponseFileFormat,
        directory: URL,
        taskName: String?,
        date: Date
    ) async -> Result<URL, ResponseFileWriteError> {
        calls.append(Call(
            response: response,
            format: format,
            directory: directory,
            taskName: taskName,
            date: date
        ))
        return result
    }
}

final class MockTerminalLauncher: TerminalLaunching {
    var result: Result<Void, RunnerError> = .success(())
    var calls = 0
    var lastMessage: Message?
    var lastDispatch: PreparedDispatch?
    func launch(
        _ dispatch: PreparedDispatch
    ) async -> Result<Void, RunnerError> {
        calls += 1
        lastDispatch = dispatch
        lastMessage = dispatch.message
        return result
    }
}

final class MockAuthenticationChecker: AuthenticationChecking {
    var status: AuthenticationStatus = .authenticated
    var calls = 0
    var lastProvider: Provider?
    var lastConfigDir: URL?
    var lastAccount: ProviderAccountContext?

    func status(
        for account: ProviderAccountContext
    ) async -> AuthenticationStatus {
        calls += 1
        lastAccount = account
        lastProvider = account.provider
        lastConfigDir = account.configDirectory
        return status
    }
}

actor SuspendingAuthenticationChecker: AuthenticationChecking {
    private var gate: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var entered = false

    func status(
        for account: ProviderAccountContext
    ) async -> AuthenticationStatus {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { gate = $0 }
        return .authenticated
    }

    func waitUntilChecking() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func resume() {
        gate?.resume()
        gate = nil
    }
}

/// Runner que suspende dentro de `run()` até `resume()` — permite iniciar um
/// segundo disparo enquanto o primeiro ainda está em andamento, para exercitar
/// o guard `isRunning` do FireController.
final class SuspendingRunner: CommandRunning {
    var result: Result<String, RunnerError> = .success("")
    private(set) var calls = 0
    /// Quando true, `run()` fica suspenso até `resume()`; o teste desliga para
    /// os disparos posteriores não pendurarem.
    var suspend = true
    private var gate: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var entered = false

    func run(
        _ dispatch: PreparedDispatch
    ) async -> Result<String, RunnerError> {
        calls += 1
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        if suspend { await withCheckedContinuation { self.gate = $0 } }
        return result
    }

    /// Aguarda `run()` ter entrado (o disparo passou o guard e está executando).
    func waitUntilRunning() async {
        if entered { return }
        await withCheckedContinuation { self.entryWaiter = $0 }
    }

    func resume() { gate?.resume(); gate = nil }
}

@MainActor
final class FireControllerTests: XCTestCase {
    var state: AppState!
    var detector: MockDetector!
    var runner: MockRunner!
    var notifier: MockNotifier!
    var responseFileWriter: MockResponseFileWriter!
    var authentication: MockAuthenticationChecker!
    var controller: FireController!
    let now = Date(timeIntervalSince1970: 1_783_000_000)

    override func setUp() async throws {
        state = AppState(defaults: UserDefaults(suiteName: "ohayo-test-\(UUID().uuidString)")!)
        // A maioria dos testes abaixo cobre o conteúdo detalhado legado. A
        // privacidade default-off é exercitada separadamente.
        state.showSensitiveNotificationDetails = true
        detector = MockDetector()
        runner = MockRunner()
        notifier = MockNotifier()
        responseFileWriter = MockResponseFileWriter()
        authentication = MockAuthenticationChecker()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    notifier: notifier, clock: FakeClock(now: now),
                                    authenticationChecker: authentication,
                                    responseFileWriter: responseFileWriter)
    }

    func testRenovacaoComQuotaIndisponivelFalhaFechadoSemDisparar() async {
        detector.stateOverride = .unavailable(reason: "schema changed")

        let outcome = await controller.fire(
            message: AppState.defaultMessage,
            origin: .renewal
        )

        XCTAssertEqual(outcome, .needsAttention)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(authentication.calls, 0)
        XCTAssertEqual(
            state.history.first?.result,
            .failure(message: state.strings.quotaUnavailableEvent)
        )
    }

    func testIntentDeAgendaComContaExplicitaAusenteFalhaFechado() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-missing-\(UUID().uuidString)")
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "não pode cair no default",
                kind: .claude,
                configDir: missing.path,
                runInTerminal: false
            )
        )

        let outcome = await controller.fire(.agenda(task))

        XCTAssertEqual(outcome, .needsAttention)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(authentication.calls, 0)
        XCTAssertEqual(
            state.history.first?.result,
            .failure(message: state.strings.accountFolderMissingEvent)
        )
        XCTAssertEqual(state.history.first?.accountPath, missing.path)
    }

    func testIntentPreparaContaCanonicaUmaVezParaTodosOsAdapters() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-dispatch-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: real
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "revise",
                kind: .codex,
                configDir: alias.path,
                runInTerminal: false
            )
        )
        state.tasks = [task]

        let outcome = await controller.fire(.agenda(task))

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(
            runner.lastDispatch?.account?.configDirectory,
            real.standardizedFileURL
        )
        XCTAssertEqual(
            authentication.lastAccount?.configDirectory,
            real.standardizedFileURL
        )
        XCTAssertEqual(
            runner.lastDispatch?.account,
            authentication.lastAccount
        )
    }

    func testHistoricoUsaContaJaPreparadaSemReinferirMensagem() async {
        let message = Message(
            text: "revise",
            kind: .claude,
            configDir: " \n ",
            runInTerminal: false
        )

        let outcome = await controller.fire(
            .direct(message, origin: .agenda)
        )

        XCTAssertEqual(outcome, .completed)
        let preparedAccount = try! XCTUnwrap(
            runner.lastDispatch?.accountDirectory
        )
        XCTAssertEqual(
            state.history.first?.accountPath,
            preparedAccount.path
        )
    }

    func testNotificacoesOcultamPromptRespostaEErroPorPadrao() async {
        state.showSensitiveNotificationDetails = false

        runner.result = .failure(.failed("token secreto"))
        await controller.fire(
            message: Message(text: "prompt secreto", kind: .claude),
            origin: .scheduled
        )
        XCTAssertEqual(notifier.titles, [state.strings.genericNotificationFailureTitle])
        XCTAssertEqual(notifier.messages, [state.strings.genericNotificationFailureBody])

        notifier.titles.removeAll()
        notifier.messages.removeAll()
        runner.result = .success("resposta secreta")
        await controller.fire(
            message: Message(
                text: "prompt secreto", kind: .claude,
                showResponse: true, runInTerminal: false
            ),
            origin: .scheduled
        )
        XCTAssertEqual(
            notifier.responses.first?.messageText,
            state.strings.genericNotificationResponseTitle
        )
        XCTAssertEqual(
            notifier.responses.first?.response,
            state.strings.genericNotificationResponseBody
        )

        notifier.responses.removeAll()
        await controller.fire(
            message: Message(
                text: "prompt secreto", kind: .shell,
                notifyOnSuccess: true
            ),
            origin: .scheduled,
            taskName: "tarefa secreta"
        )
        XCTAssertEqual(
            notifier.successes.first?.title,
            state.strings.genericNotificationSuccessTitle
        )
        XCTAssertEqual(
            notifier.successes.first?.body,
            state.strings.genericNotificationSuccessBody
        )
    }

    func testRenovacaoComJanelaAtivaPulaSemExecutar() async {
        let end = now.addingTimeInterval(3600)
        detector.end = end
        let outcome = await controller.fire(
            message: AppState.defaultMessage, origin: .renewal)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .skipped(activeUntil: end),
            message: AppState.defaultMessage, origin: .renewal))
    }

    func testFireConcorrenteDaMesmaContaEsperaENaoEhPerdido() async {
        // Regressão do "silenciador invisível": um segundo disparo para a
        // mesma conta deve entrar na fila, nunca ser descartado.
        let gate = SuspendingRunner()
        let controller = FireController(state: state, detector: detector, runner: gate,
                                        notifier: notifier, clock: FakeClock(now: now))
        // 1º disparo: entra em run() e fica suspenso.
        async let primeiro = controller.fire(message: AppState.defaultMessage, origin: .scheduled)
        await gate.waitUntilRunning()

        // 2º disparo enquanto o 1º roda: permanece pendente na fila.
        async let segundo = controller.fire(message: AppState.defaultMessage, origin: .scheduled)
        await Task.yield()
        XCTAssertEqual(gate.calls, 1, "a mesma conta deve executar serialmente")

        // Libera o 1º; o segundo deve assumir a execução automaticamente.
        gate.suspend = false
        gate.resume()
        let resultadoPrimeiro = await primeiro
        let resultadoSegundo = await segundo
        XCTAssertEqual(resultadoPrimeiro, .completed)
        XCTAssertEqual(resultadoSegundo, .completed)
        XCTAssertEqual(gate.calls, 2, "nenhum disparo concorrente pode ser perdido")
    }

    func testAgendaEnfileiradaEditadaAntesDoSlotNaoExecutaSnapshotAntigo() async {
        let gate = SuspendingRunner()
        let controller = FireController(
            state: state,
            detector: detector,
            runner: gate,
            notifier: notifier,
            clock: FakeClock(now: now)
        )
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "versão antiga",
                kind: .claude,
                runInTerminal: false
            ),
            repetition: .fixed,
            times: [9 * 60],
            weekdays: Set(1...7)
        )
        state.tasks = [task]

        let blocker = Task { @MainActor in
            await controller.fire(.direct(
                task.resolvedCommand,
                origin: .manual
            ))
        }
        await gate.waitUntilRunning()

        let queued = Task { @MainActor in
            await controller.fire(.agenda(task))
        }
        await Task.yield()
        var edited = task
        edited.command = Message(
            text: "versão atual",
            kind: .claude,
            runInTerminal: false
        )
        state.tasks = [edited]

        gate.suspend = false
        gate.resume()

        let blockerOutcome = await blocker.value
        let queuedOutcome = await queued.value
        XCTAssertEqual(blockerOutcome, .completed)
        XCTAssertEqual(queuedOutcome, .paused)
        XCTAssertEqual(
            gate.calls,
            1,
            "o payload revogado enquanto aguardava não pode chegar ao runner"
        )
    }

    func testAgendaEnfileiradaRemovidaAntesDoSlotNaoExecuta() async {
        let gate = SuspendingRunner()
        let controller = FireController(
            state: state,
            detector: detector,
            runner: gate,
            notifier: notifier,
            clock: FakeClock(now: now)
        )
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "removível",
                kind: .claude,
                runInTerminal: false
            ),
            repetition: .fixed,
            times: [9 * 60],
            weekdays: Set(1...7)
        )
        state.tasks = [task]

        let blocker = Task { @MainActor in
            await controller.fire(.direct(
                task.resolvedCommand,
                origin: .manual
            ))
        }
        await gate.waitUntilRunning()
        let queued = Task { @MainActor in
            await controller.fire(.agenda(task))
        }
        await Task.yield()
        state.tasks = []

        gate.suspend = false
        gate.resume()

        let blockerOutcome = await blocker.value
        let queuedOutcome = await queued.value
        XCTAssertEqual(blockerOutcome, .completed)
        XCTAssertEqual(queuedOutcome, .paused)
        XCTAssertEqual(gate.calls, 1)
    }

    func testAgendaEditadaDuranteAuthNaoExecutaSnapshotAntigo() async {
        let suspendingAuthentication = SuspendingAuthenticationChecker()
        controller = FireController(
            state: state,
            detector: detector,
            runner: runner,
            notifier: notifier,
            clock: FakeClock(now: now),
            authenticationChecker: suspendingAuthentication
        )
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "versão antiga",
                kind: .claude,
                runInTerminal: false
            ),
            repetition: .fixed,
            times: [9 * 60],
            weekdays: Set(1...7)
        )
        state.tasks = [task]

        let firing = Task { @MainActor in
            await controller.fire(.agenda(task))
        }
        await suspendingAuthentication.waitUntilChecking()
        var edited = task
        edited.command = Message(
            text: "versão atual",
            kind: .claude,
            runInTerminal: false
        )
        state.tasks = [edited]
        await suspendingAuthentication.resume()

        let outcome = await firing.value
        XCTAssertEqual(outcome, .paused)
        XCTAssertEqual(
            runner.calls,
            0,
            "o snapshot revogado durante o preflight não pode ser executado"
        )
        XCTAssertTrue(state.history.isEmpty)
    }

    func testAgendaPausadaDuranteAuthNaoEntregaAoTerminalNemRegistra() async {
        let suspendingAuthentication = SuspendingAuthenticationChecker()
        let terminal = MockTerminalLauncher()
        controller = FireController(
            state: state,
            detector: detector,
            runner: runner,
            terminalLauncher: terminal,
            notifier: notifier,
            clock: FakeClock(now: now),
            authenticationChecker: suspendingAuthentication
        )
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "não executar após pausa",
                kind: .claude
            ),
            repetition: .fixed,
            times: [9 * 60],
            weekdays: Set(1...7)
        )
        state.tasks = [task]

        let firing = Task { @MainActor in
            await controller.fire(.agenda(task))
        }
        await suspendingAuthentication.waitUntilChecking()
        state.setPaused(AppState.defaultConfigDir, true)
        await suspendingAuthentication.resume()

        let outcome = await firing.value
        XCTAssertEqual(outcome, .paused)
        XCTAssertEqual(terminal.calls, 0)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertTrue(state.history.isEmpty)
    }

    func testRenewalEnfileiradaDesabilitadaAntesDoSlotNaoExecuta() async {
        let gate = SuspendingRunner()
        let controller = FireController(
            state: state,
            detector: detector,
            runner: gate,
            notifier: notifier,
            clock: FakeClock(now: now)
        )
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "renovação",
                kind: .claude,
                runInTerminal: false
            ),
            repetition: .continuous
        )
        state.tasks = [task]

        let blocker = Task { @MainActor in
            await controller.fire(.direct(
                task.resolvedCommand,
                origin: .manual
            ))
        }
        await gate.waitUntilRunning()
        let queued = Task { @MainActor in
            await controller.fire(.renewal(task))
        }
        await Task.yield()
        var disabled = task
        disabled.enabled = false
        state.tasks = [disabled]

        gate.suspend = false
        gate.resume()

        let blockerOutcome = await blocker.value
        let queuedOutcome = await queued.value
        XCTAssertEqual(blockerOutcome, .completed)
        XCTAssertEqual(queuedOutcome, .paused)
        XCTAssertEqual(gate.calls, 1)
        XCTAssertNil(detector.lastAccount)
    }

    func testManualEnfileiradaPreservaAcaoExplicitaAposTaskSerRemovida() async {
        let gate = SuspendingRunner()
        let controller = FireController(
            state: state,
            detector: detector,
            runner: gate,
            notifier: notifier,
            clock: FakeClock(now: now)
        )
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "ação explícita",
                kind: .claude,
                runInTerminal: false
            )
        )
        state.tasks = [task]

        let blocker = Task { @MainActor in
            await controller.fire(.direct(
                task.resolvedCommand,
                origin: .manual
            ))
        }
        await gate.waitUntilRunning()
        let queued = Task { @MainActor in
            await controller.fire(.manual(task))
        }
        await Task.yield()
        state.tasks = []

        gate.suspend = false
        gate.resume()

        let blockerOutcome = await blocker.value
        let queuedOutcome = await queued.value
        XCTAssertEqual(blockerOutcome, .completed)
        XCTAssertEqual(queuedOutcome, .completed)
        XCTAssertEqual(gate.calls, 2)
    }

    func testDisparoEnfileiradoCanceladoNaoExecutaAoLiberarSlot() async {
        let gate = SuspendingRunner()
        let controller = FireController(
            state: state,
            detector: detector,
            runner: gate,
            notifier: notifier,
            clock: FakeClock(now: now)
        )
        let message = Message(
            text: "não execute",
            kind: .claude,
            runInTerminal: false
        )

        let blocker = Task { @MainActor in
            await controller.fire(.direct(message, origin: .manual))
        }
        await gate.waitUntilRunning()

        let cancelledFinished = expectation(
            description: "waiter cancelado foi resolvido"
        )
        let queued = Task { @MainActor in
            let outcome = await controller.fire(
                .direct(message, origin: .manual)
            )
            cancelledFinished.fulfill()
            return outcome
        }
        await Task.yield()
        queued.cancel()

        await fulfillment(of: [cancelledFinished], timeout: 1)
        let queuedOutcome = await queued.value
        XCTAssertEqual(queuedOutcome, .paused)
        XCTAssertEqual(
            gate.calls,
            1,
            "cancelar a espera precisa impedir o efeito externo"
        )

        gate.suspend = false
        gate.resume()

        let blockerOutcome = await blocker.value
        XCTAssertEqual(blockerOutcome, .completed)
    }

    func testContasDiferentesPodemExecutarEmParalelo() async {
        let gate = SuspendingRunner()
        let controller = FireController(state: state, detector: detector, runner: gate,
                                        notifier: notifier, clock: FakeClock(now: now))

        async let claude = controller.fire(
            message: AppState.defaultMessage, origin: .scheduled)
        await gate.waitUntilRunning()

        // O Claude continua suspenso, mas uma conta de outro provider não deve
        // ficar atrás da fila daquela conta.
        gate.suspend = false
        let codex = await controller.fire(
            message: Message(text: "revise", kind: .codex, runInTerminal: false),
            origin: .scheduled)

        XCTAssertEqual(codex, .completed)
        XCTAssertEqual(gate.calls, 2)
        gate.resume()
        let claudeResult = await claude
        XCTAssertEqual(claudeResult, .completed)
    }

    func testSucessoRegistraEventoNoHistorico() async {
        await controller.fire(message: AppState.defaultMessage, origin: .scheduled)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .success,
            message: AppState.defaultMessage, origin: .scheduled))
        XCTAssertEqual(state.history.count, 1)
        XCTAssertTrue(notifier.messages.isEmpty)
        XCTAssertTrue(notifier.successes.isEmpty)
    }

    func testFalhaAgendadaNotifica() async {
        runner.result = .failure(.failed("sem rede"))
        await controller.fire(message: AppState.defaultMessage, origin: .scheduled)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .failure(message: "sem rede"),
            message: AppState.defaultMessage, origin: .scheduled))
        XCTAssertEqual(notifier.titles, ["Ohayo: run failed"])
        XCTAssertEqual(notifier.messages, ["sem rede"])
    }

    func testContaNaoAutenticadaBloqueiaBatchEGravaLog() async {
        authentication.status = .unauthenticated(log: "Not logged in")
        let message = Message(text: "1+1", kind: .claude, runInTerminal: false)

        let outcome = await controller.fire(message: message, origin: .agenda)

        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(outcome, .needsAttention)
        XCTAssertEqual(state.lastEvent?.response, "Not logged in")
        guard case .failure(let summary) = state.lastEvent?.result else {
            return XCTFail("esperava falha de autenticação")
        }
        XCTAssertTrue(summary.contains("Claude"))
        XCTAssertEqual(notifier.messages.count, 1)
    }

    func testContaNaoAutenticadaBloqueiaTerminalInterativo() async {
        authentication.status = .unauthenticated(log: "Not logged in")
        let terminal = MockTerminalLauncher()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal, notifier: notifier,
                                    clock: FakeClock(now: now),
                                    authenticationChecker: authentication)

        await controller.fire(message: Message(text: "1+1", kind: .claude), origin: .agenda)

        XCTAssertEqual(terminal.calls, 0)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(state.lastEvent?.response, "Not logged in")
    }

    func testStatusDesconhecidoNaoBloqueiaExecucao() async {
        authentication.status = .unknown
        await controller.fire(message: Message(text: "1+1", kind: .claude,
                                               runInTerminal: false), origin: .agenda)
        XCTAssertEqual(authentication.calls, 1)
        XCTAssertEqual(runner.calls, 1)
    }

    func testFalhaManualNaoNotifica() async {
        runner.result = .failure(.failed("sem rede"))
        await controller.fire(message: AppState.defaultMessage, origin: .manual)
        XCTAssertTrue(notifier.messages.isEmpty)
    }

    func testCliNaoEncontradoMarcaCliFound() async {
        runner.result = .failure(.cliNotFound(.claude))
        let outcome = await controller.fire(
            message: AppState.defaultMessage, origin: .scheduled)
        XCTAssertEqual(state.cliFound[.claude], false)
        XCTAssertEqual(outcome, .needsAttention)
    }

    /// O controller envia exatamente a mensagem recebida (o chamador resolve).
    func testEnviaAMensagemRecebida() async {
        let msg = Message(text: "bom dia", kind: .claude)
        await controller.fire(message: msg, origin: .scheduled)
        XCTAssertEqual(runner.lastMessage, msg)
    }

    /// A janela é checada na conta efetiva da mensagem (conta por mensagem):
    /// o detector recebe a pasta da conta do override, não a da conta global.
    func testJanelaChecadaNaContaDaMensagem() async throws {
        let conta = FileManager.default.temporaryDirectory
            .appendingPathComponent("conta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: conta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: conta) }
        let msg = Message(text: "oi", kind: .claude, configDir: conta.path)
        await controller.fire(message: msg, origin: .renewal)
        XCTAssertEqual(detector.lastAccount?.standardizedFileURL, conta.standardizedFileURL)
        XCTAssertEqual(detector.lastProvider, .claude)
    }

    func testPreflightCodexUsaProviderDaMensagem() async {
        let msg = Message(text: "oi", kind: .codex)

        await controller.fire(message: msg, origin: .renewal)

        XCTAssertEqual(detector.lastProvider, .codex)
    }

    /// Comando cru ignora o skip de janela ativa e sempre executa.
    func testComandoCruRodaMesmoComJanelaAtiva() async {
        detector.end = now.addingTimeInterval(3600)
        let msg = Message(text: "echo oi", kind: .shell)
        await controller.fire(message: msg, origin: .scheduled)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(runner.lastMessage, msg)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .success, message: msg, origin: .scheduled))
    }

    func testRespostaSalvaENotificadaQuandoLigado() async {
        runner.result = .success("resposta do claude")
        let msg = Message(text: "resumo", kind: .claude, showResponse: true)
        await controller.fire(message: msg, origin: .scheduled)
        XCTAssertEqual(state.lastEvent?.response, "resposta do claude")
        XCTAssertEqual(notifier.responses.count, 1)
        XCTAssertEqual(notifier.responses.first?.messageText, "Ohayo: resumo")
    }

    func testRespostaClaudeMarkdownEhExportadaERegistradaNoHistorico() async {
        runner.result = .success("# Resultado\n\nTudo certo.")
        let directory = "/tmp/relatorios"
        let msg = Message(
            text: "resumo",
            kind: .claude,
            showResponse: true,
            runInTerminal: false,
            responseFileFormat: .markdown,
            responseDirectory: directory
        )

        let outcome = await controller.fire(
            message: msg,
            origin: .agenda,
            taskName: "Relatório diário"
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(responseFileWriter.calls, [
            .init(
                response: "# Resultado\n\nTudo certo.",
                format: .markdown,
                directory: URL(
                    fileURLWithPath: directory,
                    isDirectory: true
                ).standardizedFileURL,
                taskName: "Relatório diário",
                date: now
            ),
        ])
        XCTAssertEqual(state.lastEvent?.responseFileFormat, .markdown)
        XCTAssertEqual(state.lastEvent?.responseFilePath, "/tmp/resposta.md")
        XCTAssertNil(state.lastEvent?.responseFileError)
    }

    func testRespostaCodexTxtUsaMesmoFluxoDeExportacao() async {
        runner.result = .success("resultado")
        responseFileWriter.result = .success(
            URL(fileURLWithPath: "/tmp/resultado.txt")
        )
        let msg = Message(
            text: "resumo",
            kind: .codex,
            showResponse: true,
            runInTerminal: false,
            responseFileFormat: .plainText,
            responseDirectory: "/tmp"
        )

        await controller.fire(message: msg, origin: .agenda)

        XCTAssertEqual(responseFileWriter.calls.first?.format, .plainText)
        XCTAssertEqual(state.lastEvent?.responseFileFormat, .plainText)
        XCTAssertEqual(state.lastEvent?.responseFilePath, "/tmp/resultado.txt")
    }

    func testFalhaAoExportarNaoReexecutaComandoEPermaneceVisivel() async {
        runner.result = .success("resposta útil")
        responseFileWriter.result = .failure(.failed("sem permissão"))
        let msg = Message(
            text: "resumo",
            kind: .claude,
            showResponse: true,
            runInTerminal: false
        )

        let outcome = await controller.fire(message: msg, origin: .agenda)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(state.lastEvent?.result, .success)
        XCTAssertEqual(state.lastEvent?.response, "resposta útil")
        XCTAssertEqual(state.lastEvent?.responseFileError, "sem permissão")
        XCTAssertNil(state.lastEvent?.responseFilePath)
    }

    func testRespostaIgnoradaQuandoDesligado() async {
        runner.result = .success("resposta do claude")
        await controller.fire(message: Message(text: "1+1", kind: .claude), origin: .scheduled)
        XCTAssertNil(state.lastEvent?.response)
        XCTAssertTrue(notifier.responses.isEmpty)
        XCTAssertTrue(responseFileWriter.calls.isEmpty)
    }

    func testRespostaTruncadaEm4000() async {
        runner.result = .success(String(repeating: "a", count: 5000))
        let msg = Message(text: "resumo", kind: .claude, showResponse: true)
        await controller.fire(message: msg, origin: .scheduled)
        XCTAssertEqual(state.lastEvent?.response?.count, 4000)
    }

    func testRespostaVaziaNaoNotificaNemPersiste() async {
        runner.result = .success("")
        let msg = Message(text: "resumo", kind: .claude, showResponse: true)
        await controller.fire(message: msg, origin: .scheduled)
        XCTAssertNil(state.lastEvent?.response)
        XCTAssertTrue(notifier.responses.isEmpty)
    }

    // MARK: - Resumo de falha (histórico legível)

    func testFalhaLongaGravaResumoCurtoEDetalheCompleto() async {
        let stderrCompleto = """
        warning: Model metadata for `gpt-5.1-codex-mini` not found.

        ERROR: {"type":"error","status":400,"error":{"message":"The 'gpt-5.1-codex-mini' model is not supported"}}
        """
        runner.result = .failure(.failed(stderrCompleto))
        await controller.fire(message: Message(text: "1+1", kind: .codex), origin: .manual)

        guard case .failure(let message) = state.history.first?.result else {
            return XCTFail("esperava falha no histórico")
        }
        // Resumo = última linha não vazia, não o stderr inteiro.
        XCTAssertTrue(message.hasPrefix("ERROR: {\"type\":\"error\""))
        XCTAssertFalse(message.contains("warning:"))
        // Detalhe completo vai para response (vira DisclosureGroup na UI).
        XCTAssertEqual(state.history.first?.response, stderrCompleto)
    }

    func testResumoDeFalhaTruncaEm120Caracteres() {
        let linhaLonga = String(repeating: "x", count: 300)
        XCTAssertEqual(FireController.failureSummary(linhaLonga).count, 120)
    }

    func testDetalheDeFalhaIndicaQuandoLogFoiTruncado() async {
        runner.result = .failure(.failed(String(repeating: "x", count: 5000)))
        await controller.fire(message: Message(text: "1+1", kind: .claude,
                                               runInTerminal: false), origin: .manual)
        XCTAssertTrue(state.history.first?.response?.hasSuffix("[log truncated]") == true)
    }

    func testResumoUsaUltimaLinhaNaoVazia() {
        XCTAssertEqual(FireController.failureSummary("primeira\n\núltima  \n\n"), "última")
        XCTAssertEqual(FireController.failureSummary("só uma linha"), "só uma linha")
    }

    func testErroEstruturadoNaoGanhaDetalhe() async {
        runner.result = .failure(.timeout)
        let outcome = await controller.fire(
            message: Message(text: "1+1", kind: .claude), origin: .manual)

        guard case .failure(let message) = state.history.first?.result else {
            return XCTFail("esperava falha no histórico")
        }
        XCTAssertEqual(outcome, .retryableFailure)
        XCTAssertEqual(message, "the command timed out")
        XCTAssertNil(state.history.first?.response)
    }

    func testErroEstruturadoUsaIdiomaPortuguesQuandoSelecionado() async {
        state.language = .portuguese
        runner.result = .failure(.timeout)
        await controller.fire(message: Message(text: "1+1", kind: .claude), origin: .manual)

        guard case .failure(let message) = state.history.first?.result else {
            return XCTFail("esperava falha no histórico")
        }
        XCTAssertEqual(message, "o comando excedeu o tempo limite")
    }

    func testFalhasTransitoriasConhecidasEntramEmRetry() async {
        for log in [
            "network connection reset",
            "HTTP 503 service unavailable",
            "rate limit exceeded; try again",
        ] {
            runner.result = .failure(.failed(log))
            let outcome = await controller.fire(
                message: Message(text: "1+1", kind: .claude),
                origin: .scheduled
            )
            XCTAssertEqual(outcome, .retryableFailure, log)
        }
    }

    func testFalhaDeModeloOuDesconhecidaExigeAtencaoSemLoop() async {
        for log in [
            "The model is not supported for this account",
            "exit 2",
        ] {
            runner.result = .failure(.failed(log))
            let outcome = await controller.fire(
                message: Message(text: "1+1", kind: .claude),
                origin: .scheduled
            )
            XCTAssertEqual(outcome, .needsAttention, log)
        }
    }

    func testClaudeComTerminalInterativoAbreTerminalENaoChamaRunnerBatch() async {
        let terminal = MockTerminalLauncher()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now),
                                    responseFileWriter: responseFileWriter)

        let message = Message(text: "bom dia", kind: .claude)
        await controller.fire(message: message, origin: .scheduled)

        XCTAssertEqual(terminal.calls, 1)
        XCTAssertEqual(terminal.lastMessage, Message(text: "bom dia", kind: .claude))
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .launched, message: message, origin: .scheduled))
    }

    func testTerminalInterativoAbreMesmoComJanelaAtiva() async {
        let terminal = MockTerminalLauncher()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now))
        let end = now.addingTimeInterval(3600)
        detector.end = end

        let message = Message(text: "bom dia", kind: .claude)
        await controller.fire(message: message, origin: .agenda)

        XCTAssertEqual(terminal.calls, 1)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .launched, message: message, origin: .agenda))
    }

    func testAgendaBatchComRespostaExecutaMesmoComJanelaAtiva() async {
        let terminal = MockTerminalLauncher()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now),
                                    responseFileWriter: responseFileWriter)
        detector.end = now.addingTimeInterval(3600)
        runner.result = .success("Porto Alegre")

        let message = Message(text: "capital do RS", kind: .claude,
                              showResponse: true, runInTerminal: false)
        await controller.fire(message: message, origin: .agenda)

        XCTAssertEqual(terminal.calls, 0)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .success, message: message,
            origin: .agenda, response: "Porto Alegre",
            responseFileFormat: .markdown,
            responseFilePath: "/tmp/resposta.md"))
        XCTAssertEqual(notifier.responses.count, 1)
        XCTAssertEqual(notifier.responses.first?.response, "Porto Alegre")
    }

    func testRenovacaoInterativaComJanelaAtivaTambemPula() async {
        let terminal = MockTerminalLauncher()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now))
        let end = now.addingTimeInterval(3600)
        detector.end = end

        let message = Message(text: "1+1", kind: .claude)
        await controller.fire(message: message, origin: .renewal)

        XCTAssertEqual(terminal.calls, 0)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .skipped(activeUntil: end),
            message: message, origin: .renewal))
    }

    func testTerminalInterativoDesligadoUsaRunnerBatch() async {
        let terminal = MockTerminalLauncher()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now))

        await controller.fire(message: Message(text: "bom dia", kind: .claude,
                                               runInTerminal: false),
                              origin: .scheduled)

        XCTAssertEqual(terminal.calls, 0)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(runner.lastMessage, Message(text: "bom dia", kind: .claude,
                                                   runInTerminal: false))
    }

    // MARK: - Notificação de sucesso por tarefa (notifyOnSuccess)

    /// Corpo esperado, montado com os mesmos helpers da implementação
    /// (padrão dos testes que comparam com state.makeEvent).
    private func corpoDeSucesso(para msg: Message) -> String {
        let prepared = try? DispatchPreparer()
            .prepare(.direct(msg, origin: .agenda))
            .get()
        let conta = prepared?.accountDirectory.map(state.label)
        return state.strings.notificationSuccessBody(
            account: conta, time: Fmt.hhmm(now, language: state.language))
    }

    func testNotifyOnSuccessNotificaComNomeDaTarefa() async {
        let msg = Message(text: "1+1", kind: .claude, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda, taskName: "Renovar")
        XCTAssertEqual(notifier.successes.count, 1)
        XCTAssertEqual(notifier.successes.first?.title, "Ohayo: Renovar")
        XCTAssertEqual(notifier.successes.first?.body, corpoDeSucesso(para: msg))
    }

    func testNotifyOnSuccessSemNomeUsaTextoDoComando() async {
        let msg = Message(text: "bom dia", kind: .claude, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda)
        XCTAssertEqual(notifier.successes.first?.title, "Ohayo: bom dia")
    }

    func testNotifyOnSuccessDesligadoNaoNotifica() async {
        await controller.fire(message: Message(text: "1+1", kind: .claude), origin: .agenda)
        XCTAssertTrue(notifier.successes.isEmpty)
    }

    func testNotifyOnSuccessNaoNotificaEmFalha() async {
        runner.result = .failure(.failed("sem rede"))
        let msg = Message(text: "1+1", kind: .claude, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda)
        XCTAssertTrue(notifier.successes.isEmpty)
        XCTAssertEqual(notifier.messages, ["sem rede"]) // falha notifica como hoje
    }

    func testNotifyOnSuccessNaoNotificaEmSkip() async {
        detector.end = now.addingTimeInterval(3600)
        let msg = Message(text: "1+1", kind: .claude, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .renewal)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertTrue(notifier.successes.isEmpty)
    }

    func testNotifyOnSuccessComRespostaNaoDuplica() async {
        runner.result = .success("42")
        let msg = Message(text: "1+1", kind: .claude,
                          showResponse: true, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda)
        XCTAssertEqual(notifier.responses.count, 1)
        XCTAssertTrue(notifier.successes.isEmpty)
    }

    func testNotifyOnSuccessComRespostaVaziaNotificaSucesso() async {
        runner.result = .success("")
        let msg = Message(text: "1+1", kind: .claude,
                          showResponse: true, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda)
        XCTAssertTrue(notifier.responses.isEmpty)
        XCTAssertEqual(notifier.successes.count, 1)
    }

    func testNotifyOnSuccessNoTerminalNaoConfirmaAntesDaConclusao() async {
        let terminal = MockTerminalLauncher()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now))
        let msg = Message(text: "bom dia", kind: .claude, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda, taskName: "Interativa")
        XCTAssertEqual(terminal.calls, 1)
        XCTAssertTrue(notifier.successes.isEmpty)
        XCTAssertEqual(state.lastEvent?.result, .launched)
    }

    func testNotifyOnSuccessNoTerminalNaoNotificaEmFalha() async {
        let terminal = MockTerminalLauncher()
        terminal.result = .failure(.failed("Terminal nao abriu"))
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now))
        let msg = Message(text: "bom dia", kind: .claude, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda)
        XCTAssertTrue(notifier.successes.isEmpty)
    }

    func testNotifyOnSuccessCorpoSemContaParaShell() async {
        let msg = Message(text: "echo oi", kind: .shell, notifyOnSuccess: true)
        await controller.fire(message: msg, origin: .agenda)
        XCTAssertEqual(notifier.successes.count, 1)
        XCTAssertEqual(notifier.successes.first?.body,
                       state.strings.notificationSuccessBody(
                           account: nil, time: Fmt.hhmm(now, language: state.language)))
    }

    func testFalhaAoAbrirTerminalRegistraFalhaENotifica() async {
        let terminal = MockTerminalLauncher()
        terminal.result = .failure(.failed("Terminal nao abriu"))
        controller = FireController(state: state, detector: detector, runner: runner,
                                    terminalLauncher: terminal,
                                    notifier: notifier, clock: FakeClock(now: now))

        let message = Message(text: "bom dia", kind: .claude)
        let outcome = await controller.fire(message: message, origin: .scheduled)

        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(outcome, .needsAttention)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .failure(message: "Terminal nao abriu"),
            message: message, origin: .scheduled))
        XCTAssertEqual(notifier.messages, ["Terminal nao abriu"])
    }

    // MARK: - Pause por conta

    func testContaPausadaDescartaSemExecutarNemRegistrar() async {
        state.setPaused(AppState.defaultConfigDir, true)
        let outcome = await controller.fire(
            message: AppState.defaultMessage, origin: .renewal)
        XCTAssertEqual(outcome, .paused)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertTrue(notifier.messages.isEmpty)
    }

    func testOutraContaPausadaNaoAfetaODisparo() async {
        state.setPaused(AppState.defaultCodexConfigDir, true)
        await controller.fire(message: AppState.defaultMessage, origin: .agenda)
        XCTAssertEqual(runner.calls, 1)
    }

    func testShellNuncaEPausado() async {
        state.setPaused(AppState.defaultConfigDir, true)
        await controller.fire(message: Message(text: "echo oi", kind: .shell), origin: .agenda)
        XCTAssertEqual(runner.calls, 1)
    }
}
