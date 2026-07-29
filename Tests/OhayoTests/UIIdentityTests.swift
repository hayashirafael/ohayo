import XCTest

@testable import Ohayo

final class UIIdentityTests: XCTestCase {
    func testManualRunFeedbackUsesOnlyTheNewEventWithFullTargetIdentity() {
        let start = Date(timeIntervalSince1970: 100)
        let target = HorariosView.ManualRunTarget(
            messageText: "status",
            accountPath: "/accounts/a",
            provider: .claude,
            modelName: "Haiku 4.5"
        )
        let previous = event(
            date: start.addingTimeInterval(-1),
            result: .success,
            accountPath: "/accounts/a"
        )
        let otherAccount = event(
            date: start.addingTimeInterval(1),
            result: .failure(message: "wrong account"),
            accountPath: "/accounts/b"
        )
        let expected = event(
            date: start.addingTimeInterval(2),
            result: .success,
            accountPath: "/accounts/a"
        )

        let result = HorariosView.manualRunEvent(
            target: target,
            startedAt: start,
            previousHistory: [previous],
            currentHistory: [expected, otherAccount, previous]
        )

        XCTAssertEqual(result, expected)
    }

    func testManualRunFeedbackFailsClosedForIndistinguishableConcurrentEvents() {
        let start = Date(timeIntervalSince1970: 100)
        let target = HorariosView.ManualRunTarget(
            messageText: "status",
            accountPath: "/accounts/a",
            provider: .claude,
            modelName: "Haiku 4.5"
        )
        let first = event(
            date: start.addingTimeInterval(1),
            result: .success,
            accountPath: "/accounts/a"
        )
        let second = event(
            date: start.addingTimeInterval(2),
            result: .failure(message: "boom"),
            accountPath: "/accounts/a"
        )

        XCTAssertNil(HorariosView.manualRunEvent(
            target: target,
            startedAt: start,
            previousHistory: [],
            currentHistory: [second, first]
        ))
    }

    func testOldFeedbackTokenCannotClearANewerRun() {
        let old = UUID()
        let current = UUID()
        let feedback = HorariosView.RunFeedback(token: current, result: .success)

        XCTAssertFalse(HorariosView.feedback(feedback, belongsTo: old))
        XCTAssertTrue(HorariosView.feedback(feedback, belongsTo: current))
    }

    func testHistoryRowIdentitySurvivesFilteringAndNewDifferentEvents() {
        let first = FireEvent(
            date: Date(timeIntervalSince1970: 10),
            result: .success,
            messageText: "first"
        )
        let second = FireEvent(
            date: Date(timeIntervalSince1970: 20),
            result: .failure(message: "boom"),
            messageText: "second"
        )
        let inserted = FireEvent(
            date: Date(timeIntervalSince1970: 30),
            result: .launched,
            messageText: "inserted"
        )
        let original = HistoryTab.rows(for: [second, first])
        let afterInsertion = HistoryTab.rows(for: [inserted, second, first])

        XCTAssertEqual(original[0].id, afterInsertion[1].id)
        XCTAssertEqual(original[1].id, afterInsertion[2].id)
        XCTAssertEqual(
            original.first(where: { $0.event.messageText == "second" })?.id,
            afterInsertion.first(where: { $0.event.messageText == "second" })?.id
        )
    }

    func testHistoryRowIdentityDistinguishesExactDuplicates() {
        let event = FireEvent(
            date: Date(timeIntervalSince1970: 10),
            result: .success,
            messageText: "same"
        )
        let rows = HistoryTab.rows(for: [event, event])

        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    private func event(
        date: Date,
        result: FireResult,
        accountPath: String
    ) -> FireEvent {
        FireEvent(
            date: date,
            result: result,
            messageText: "status",
            account: URL(fileURLWithPath: accountPath).lastPathComponent,
            origin: .manual,
            accountPath: accountPath,
            provider: .claude,
            modelName: "Haiku 4.5"
        )
    }
}
