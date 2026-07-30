import XCTest
@testable import Ohayo

@MainActor
final class AppWindowActionsTests: XCTestCase {
    func testPresentWindowClosesPanelAndOpensBeforeDeferredActivation() {
        var events: [String] = []
        var deferredAction: (@MainActor () -> Void)?

        AppWindowActions.presentWindow(
            closePanel: {
                events.append("close")
            },
            prepareForPresentation: {
                events.append("prepare")
            },
            openWindow: {
                events.append("open")
            },
            deferToNextRunLoop: { action in
                events.append("defer")
                deferredAction = action
            },
            activate: {
                events.append("activate")
            }
        )

        XCTAssertEqual(events, ["close", "prepare", "open", "defer"])

        let action = deferredAction
        deferredAction = nil
        action?()

        XCTAssertEqual(
            events,
            ["close", "prepare", "open", "defer", "activate"]
        )
    }
}
