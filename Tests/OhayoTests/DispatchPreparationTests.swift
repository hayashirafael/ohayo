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
}
