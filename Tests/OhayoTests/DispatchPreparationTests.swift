import XCTest
@testable import Ohayo

final class DispatchPreparationTests: XCTestCase {
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
}
