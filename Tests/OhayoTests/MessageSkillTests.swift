import XCTest
@testable import Ohayo

final class MessageSkillTests: XCTestCase {
    func testCodexReasoningIncluiXHighComoValorPersistivel() throws {
        XCTAssertEqual(
            Message.CodexReasoning.allCases,
            [.minimal, .low, .medium, .high, .xhigh]
        )

        let data = try JSONEncoder().encode(Message(
            text: "analise", kind: .codex, codexReasoning: .xhigh))
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded.codexReasoning, .xhigh)
    }

    func testPromptSemSkillEhOTexto() {
        XCTAssertEqual(Message(text: "1+1", kind: .claude).resolvedPromptText, "1+1")
    }

    func testPromptClaudeComSkillPrefixaSlash() {
        var msg = Message(text: "1+1", kind: .claude)
        msg.skill = "gmud"
        XCTAssertEqual(msg.resolvedPromptText, "/gmud 1+1")
    }

    func testPromptCodexComSkillPrefixaCifrao() {
        var msg = Message(text: "oi", kind: .codex)
        msg.skill = "gmud"
        XCTAssertEqual(msg.resolvedPromptText, "$gmud oi")
    }

    func testShellIgnoraSkill() {
        var msg = Message(text: "echo oi", kind: .shell)
        msg.skill = "gmud"
        XCTAssertEqual(msg.resolvedPromptText, "echo oi")
    }

    func testSkillVaziaNaoPrefixa() {
        var msg = Message(text: "1+1", kind: .claude)
        msg.skill = ""
        XCTAssertEqual(msg.resolvedPromptText, "1+1")
        XCTAssertTrue(msg.resolvedSafeMode) // vazia não desliga o safe-mode
    }

    /// Guarda defensiva: com skill, `--safe-mode` faria o CLI pular a skill —
    /// estado contraditório persistido nunca ignora a skill em silêncio.
    func testSkillForcaSafeModeOff() {
        var msg = Message(text: "1+1", kind: .claude, safeMode: true)
        msg.skill = "gmud"
        XCTAssertFalse(msg.resolvedSafeMode)
    }

    func testEqualityConsideraSkill() {
        var a = Message(text: "x", kind: .claude)
        var b = a
        b.skill = "gmud"
        XCTAssertNotEqual(a, b)
        a.skill = "gmud"
        XCTAssertEqual(a, b)
    }

    /// Sem uid, o `id` deriva do conteúdo — skills diferentes, ids diferentes.
    func testIdentidadeDeConteudoConsideraSkill() {
        var a = Message(text: "x", kind: .claude)
        var b = Message(text: "x", kind: .claude)
        a.skill = "gmud"
        b.skill = "outra"
        XCTAssertNotEqual(a.id, b.id)
    }

    func testDecodeBlobAntigoSemSkillViraNil() throws {
        let json = #"{"uid":"11111111-1111-1111-1111-111111111111","command":{"text":"1+1","kind":"claude"}}"#
        let task = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        XCTAssertNil(task.resolvedCommand.skill)
    }

    func testRoundTripScheduledTaskComSkill() throws {
        var msg = Message(text: "1+1", kind: .claude)
        msg.skill = "superpowers:brainstorming"
        let task = ScheduledTask(uid: UUID(), command: msg)
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: data)
        XCTAssertEqual(decoded.resolvedCommand.skill, "superpowers:brainstorming")
    }
}
