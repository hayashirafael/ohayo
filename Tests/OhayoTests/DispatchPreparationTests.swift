import XCTest
@testable import Ohayo

final class DispatchPreparationTests: XCTestCase {
    func testModosCodexPreservamPayloadsLegadosDasDuasPRs() {
        let fixtures: [(Message, CodexAccessMode)] = [
            (
                Message(text: "padrão", kind: .codex),
                .fullAccess
            ),
            (
                Message(
                    text: "opt-out legado da PR 10",
                    kind: .codex,
                    codexAllowFullAccess: false
                ),
                .readOnly
            ),
            (
                Message(
                    text: "opt-out legado da PR 11",
                    kind: .codex,
                    trustWorkingDirectory: false
                ),
                .readOnly
            ),
            (
                Message(
                    text: "pasta confiada",
                    kind: .codex,
                    trustWorkingDirectory: true,
                    codexAllowFullAccess: false
                ),
                .workspaceWrite
            ),
        ]

        XCTAssertEqual(
            fixtures.map { $0.0.resolvedCodexAccessMode },
            fixtures.map { $0.1 }
        )
    }

    func testManualPermiteExecutarShellContinuoLegado() throws {
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(text: "echo legado", kind: .shell),
            repetition: .continuous
        )

        let dispatch = try DispatchPreparer()
            .prepare(.manual(task))
            .get()

        XCTAssertEqual(
            dispatch.target,
            .shell(workingDirectory: nil)
        )
    }

    func testAgendaContinuaBloqueandoShellContinuoLegado() {
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(text: "echo legado", kind: .shell),
            repetition: .continuous
        )

        XCTAssertEqual(
            DispatchPreparer().prepare(.agenda(task)),
            .failure(.continuousShell)
        )
    }

    func testCodexPermiteTudoPorPadraoEmBatchETerminal() {
        let plan = ProviderDispatchPlan(
            message: Message(text: "implemente", kind: .codex),
            account: ProviderAccountContext(
                provider: .codex,
                configDirectory: nil
            )
        )

        XCTAssertTrue(
            plan.batchArguments.contains(
                "--dangerously-bypass-approvals-and-sandbox"
            )
        )
        XCTAssertTrue(
            plan.terminalArguments.contains(
                "--dangerously-bypass-approvals-and-sandbox"
            )
        )
        XCTAssertFalse(plan.batchArguments.contains("read-only"))
        XCTAssertFalse(plan.terminalArguments.contains("read-only"))
    }

    func testCadaModoCodexEmiteExatamenteUmaPoliticaEmBatchETerminal() {
        let fixtures: [
            (
                message: Message,
                batch: [String],
                terminal: [String]
            )
        ] = [
            (
                Message(text: "acesso total", kind: .codex),
                [
                    "exec",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "--skip-git-repo-check",
                    "--color",
                    "never",
                ],
                [
                    "--dangerously-bypass-approvals-and-sandbox",
                    "acesso total",
                ]
            ),
            (
                Message(
                    text: "edite a pasta",
                    kind: .codex,
                    trustWorkingDirectory: true,
                    codexAllowFullAccess: false
                ),
                [
                    "exec",
                    "--sandbox",
                    "workspace-write",
                    "--skip-git-repo-check",
                    "--color",
                    "never",
                ],
                ["--sandbox", "workspace-write", "edite a pasta"]
            ),
            (
                Message(
                    text: "somente leia",
                    kind: .codex,
                    trustWorkingDirectory: false,
                    codexAllowFullAccess: false
                ),
                [
                    "exec",
                    "--sandbox",
                    "read-only",
                    "--skip-git-repo-check",
                    "--color",
                    "never",
                ],
                ["--sandbox", "read-only", "somente leia"]
            ),
        ]

        for fixture in fixtures {
            let plan = ProviderDispatchPlan(
                message: fixture.message,
                account: ProviderAccountContext(
                    provider: .codex,
                    configDirectory: nil
                )
            )

            XCTAssertEqual(plan.batchArguments, fixture.batch)
            XCTAssertEqual(plan.terminalArguments, fixture.terminal)
        }
    }

    func testCodexOptOutDePermitirTudoVoltaAoSandboxReadOnly() {
        let plan = ProviderDispatchPlan(
            message: Message(
                text: "analise",
                kind: .codex,
                codexAllowFullAccess: false
            ),
            account: ProviderAccountContext(
                provider: .codex,
                configDirectory: nil
            )
        )

        XCTAssertFalse(
            plan.batchArguments.contains(
                "--dangerously-bypass-approvals-and-sandbox"
            )
        )
        XCTAssertTrue(plan.batchArguments.contains("--sandbox"))
        XCTAssertTrue(plan.batchArguments.contains("read-only"))
        XCTAssertTrue(plan.terminalArguments.contains("--sandbox"))
        XCTAssertTrue(plan.terminalArguments.contains("read-only"))
    }

    func testCodexConfiadoSemAcessoTotalUsaWorkspaceWrite() {
        let message = Message(
            text: "implemente",
            kind: .codex,
            trustWorkingDirectory: true,
            codexAllowFullAccess: false
        )
        let plan = ProviderDispatchPlan(
            message: message,
            account: ProviderAccountContext(
                provider: .codex,
                configDirectory: nil
            )
        )

        XCTAssertEqual(message.resolvedCodexAccessMode, .workspaceWrite)
        XCTAssertTrue(plan.batchArguments.contains("workspace-write"))
        XCTAssertTrue(plan.terminalArguments.contains("workspace-write"))
        XCTAssertFalse(
            plan.batchArguments.contains(
                "--dangerously-bypass-approvals-and-sandbox"
            )
        )
    }

    func testOptOutDeTrustVenceAcessoTotalEUsaReadOnly() {
        let message = Message(
            text: "somente leia",
            kind: .codex,
            trustWorkingDirectory: false,
            codexAllowFullAccess: true
        )
        let plan = ProviderDispatchPlan(
            message: message,
            account: ProviderAccountContext(
                provider: .codex,
                configDirectory: nil
            )
        )

        XCTAssertEqual(message.resolvedCodexAccessMode, .readOnly)
        XCTAssertTrue(plan.batchArguments.contains("read-only"))
        XCTAssertTrue(plan.terminalArguments.contains("read-only"))
        XCTAssertFalse(
            plan.batchArguments.contains(
                "--dangerously-bypass-approvals-and-sandbox"
            )
        )
    }
}
