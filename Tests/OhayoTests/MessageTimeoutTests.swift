import XCTest
@testable import Ohayo

@MainActor
final class MessageTimeoutTests: XCTestCase {
    private func makeState() -> AppState {
        let defaults = UserDefaults(
            suiteName: "ohayo-timeout-test-\(UUID().uuidString)"
        )!
        defaults.set([String](), forKey: "registeredAccounts")
        return AppState(
            defaults: defaults,
            home: URL(fileURLWithPath: "/tmp/ohayo-timeout-home")
        )
    }

    func testTimeoutDesabilitadoPorPadraoMesmoEmBatch() {
        var claudeBatch = Message(text: "revise", kind: .claude)
        claudeBatch.runInTerminal = false
        var codexBatch = Message(text: "revise", kind: .codex)
        codexBatch.runInTerminal = false
        let shell = Message(text: "make test", kind: .shell)
        let claudeTerminal = Message(text: "revise", kind: .claude)

        XCTAssertNil(claudeBatch.resolvedTimeoutSeconds)
        XCTAssertNil(codexBatch.resolvedTimeoutSeconds)
        XCTAssertNil(shell.resolvedTimeoutSeconds)
        XCTAssertNil(claudeTerminal.resolvedTimeoutSeconds)

        var terminalComOverride = claudeTerminal
        terminalComOverride.timeoutSeconds = 1_800
        XCTAssertNil(terminalComOverride.resolvedTimeoutSeconds)
    }

    func testTimeoutConfiguradoEhAplicadoAoBatch() {
        let shell = Message(
            text: "make test",
            kind: .shell,
            timeoutSeconds: 1_800
        )

        XCTAssertEqual(shell.resolvedTimeoutSeconds, 1_800)
    }

    func testIgualdadeConsideraTimeoutPersistido() {
        let padrao = Message(text: "revise", kind: .claude)
        let customizado = Message(
            text: "revise",
            kind: .claude,
            timeoutSeconds: 1_800
        )

        XCTAssertNotEqual(padrao, customizado)
    }

    func testIdentidadeDeConteudoConsideraTimeoutPersistido() {
        let padrao = Message(text: "revise", kind: .claude)
        let customizado = Message(
            text: "revise",
            kind: .claude,
            timeoutSeconds: 1_800
        )

        XCTAssertNotEqual(padrao.id, customizado.id)
    }

    func testNovoAgendamentoComecaComTimeoutDesabilitado() {
        let draft = AgendamentoDraft(editing: nil)

        XCTAssertFalse(draft.timeoutEnabled)
        XCTAssertNil(draft.timeoutMinutes)
    }

    func testTimeoutAceitaQuantidadeLivreDeMinutos() {
        var draft = AgendamentoDraft(editing: nil)
        draft.text = "make test"
        draft.changeKind(to: .shell)
        draft.timeoutEnabled = true
        draft.timeoutMinutes = 17

        XCTAssertEqual(
            draft.normalizedTask().resolvedCommand.timeoutSeconds,
            17 * 60
        )
    }

    func testTimeoutDesabilitadoNaoPersisteDuracaoDigitada() {
        var draft = AgendamentoDraft(editing: nil)
        draft.text = "make test"
        draft.changeKind(to: .shell)
        draft.timeoutEnabled = false
        draft.timeoutMinutes = 17

        XCTAssertNil(draft.normalizedTask().resolvedCommand.timeoutSeconds)
    }

    func testEdicaoRestauraTimeoutPersistidoSemPerderOverride() {
        let command = Message(
            text: "revise",
            kind: .codex,
            runInTerminal: false,
            timeoutSeconds: 1_800
        )
        let task = ScheduledTask(uid: UUID(), command: command)

        let restored = AgendamentoDraft(editing: task)

        XCTAssertTrue(restored.timeoutEnabled)
        XCTAssertEqual(restored.timeoutMinutes, 30)
    }

    func testEditorRecusaTimeoutAtivadoSemMinutosPositivos() {
        let editor = AgendamentoEditor(
            state: makeState(),
            isDirectory: { _ in true }
        )
        var draft = AgendamentoDraft(editing: nil)
        draft.text = "revise"
        draft.outputMode = .none
        draft.timeoutEnabled = true

        XCTAssertTrue(editor.evaluate(draft).issues.contains(.invalidTimeout))

        draft.timeoutMinutes = 0
        XCTAssertTrue(editor.evaluate(draft).issues.contains(.invalidTimeout))

        draft.timeoutMinutes = 1
        XCTAssertFalse(editor.evaluate(draft).issues.contains(.invalidTimeout))
    }

    func testControleDeTimeoutSoApareceQuandoOhayoMonitoraOBatch() {
        XCTAssertTrue(AgendamentoDraft.showsTimeout(for: .none))
        XCTAssertTrue(AgendamentoDraft.showsTimeout(for: .response))
        XCTAssertFalse(AgendamentoDraft.showsTimeout(for: .terminal))
    }

    func testTimeoutFazRoundtripCodable() throws {
        let original = Message(
            text: "make test",
            kind: .shell,
            timeoutSeconds: 1_800
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testMensagemLegadaSemTimeoutContinuaSemLimiteAutomatico() throws {
        let data = #"{"text":"make test","kind":"shell"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertNil(decoded.timeoutSeconds)
        XCTAssertNil(decoded.resolvedTimeoutSeconds)
    }
}
