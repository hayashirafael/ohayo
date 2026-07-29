import XCTest
@testable import Ohayo

@MainActor
final class MessageTimeoutTests: XCTestCase {
    func testTimeoutResolvidoUsaDefaultsSegurosApenasEmBatch() {
        var claudeBatch = Message(text: "revise", kind: .claude)
        claudeBatch.runInTerminal = false
        var codexBatch = Message(text: "revise", kind: .codex)
        codexBatch.runInTerminal = false
        let shell = Message(text: "make test", kind: .shell)
        let claudeTerminal = Message(text: "revise", kind: .claude)

        XCTAssertEqual(claudeBatch.resolvedTimeoutSeconds, 900)
        XCTAssertEqual(codexBatch.resolvedTimeoutSeconds, 900)
        XCTAssertEqual(shell.resolvedTimeoutSeconds, 300)
        XCTAssertNil(claudeTerminal.resolvedTimeoutSeconds)

        var terminalComOverride = claudeTerminal
        terminalComOverride.timeoutSeconds = 1_800
        XCTAssertNil(terminalComOverride.resolvedTimeoutSeconds)
    }

    func testTimeoutConfiguradoSobrescreveDefaultDoBatch() {
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

    func testFormularioOfereceApenasPresetsSegurosEmSegundos() {
        XCTAssertEqual(Message.timeoutPresets, [60, 300, 900, 1_800])
    }

    func testPersistenciaNormalizaSomenteODefaultDoTipoParaNil() {
        XCTAssertNil(Message.normalizedTimeoutSeconds(900, for: .claude))
        XCTAssertNil(Message.normalizedTimeoutSeconds(900, for: .codex))
        XCTAssertNil(Message.normalizedTimeoutSeconds(300, for: .shell))
        XCTAssertEqual(
            Message.normalizedTimeoutSeconds(300, for: .claude),
            300
        )
        XCTAssertEqual(
            Message.normalizedTimeoutSeconds(1_800, for: .shell),
            1_800
        )
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

        XCTAssertEqual(restored.timeoutSeconds, 1_800)
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

    func testMensagemLegadaSemTimeoutContinuaDecodificandoComDefault() throws {
        let data = #"{"text":"make test","kind":"shell"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertNil(decoded.timeoutSeconds)
        XCTAssertEqual(decoded.resolvedTimeoutSeconds, 300)
    }
}
