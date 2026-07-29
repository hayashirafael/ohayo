import XCTest
@testable import Ohayo

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
    func quotaWindowState(
        account: URL,
        provider: Provider
    ) async -> QuotaWindowState {
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
    func run(_ message: Message) async -> Result<String, RunnerError> {
        calls += 1
        lastMessage = message
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

final class MockTerminalLauncher: TerminalLaunching {
    var result: Result<Void, RunnerError> = .success(())
    var calls = 0
    var lastMessage: Message?
    func launch(_ message: Message) async -> Result<Void, RunnerError> {
        calls += 1
        lastMessage = message
        return result
    }
}

final class MockAuthenticationChecker: AuthenticationChecking {
    var status: AuthenticationStatus = .authenticated
    var calls = 0
    var lastProvider: Provider?
    var lastConfigDir: URL?

    func status(for provider: Provider, configDir: URL) async -> AuthenticationStatus {
        calls += 1
        lastProvider = provider
        lastConfigDir = configDir
        return status
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

    func run(_ message: Message) async -> Result<String, RunnerError> {
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
        authentication = MockAuthenticationChecker()
        controller = FireController(state: state, detector: detector, runner: runner,
                                    notifier: notifier, clock: FakeClock(now: now),
                                    authenticationChecker: authentication)
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

    func testRespostaIgnoradaQuandoDesligado() async {
        runner.result = .success("resposta do claude")
        await controller.fire(message: Message(text: "1+1", kind: .claude), origin: .scheduled)
        XCTAssertNil(state.lastEvent?.response)
        XCTAssertTrue(notifier.responses.isEmpty)
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
                                    notifier: notifier, clock: FakeClock(now: now))

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
                                    notifier: notifier, clock: FakeClock(now: now))
        detector.end = now.addingTimeInterval(3600)
        runner.result = .success("Porto Alegre")

        let message = Message(text: "capital do RS", kind: .claude,
                              showResponse: true, runInTerminal: false)
        await controller.fire(message: message, origin: .agenda)

        XCTAssertEqual(terminal.calls, 0)
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(state.lastEvent, state.makeEvent(
            date: now, result: .success, message: message,
            origin: .agenda, response: "Porto Alegre"))
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
        let conta = msg.kind == .shell ? nil : state.label(for: state.effectiveConfigDir(for: msg))
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
