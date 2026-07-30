import XCTest
@testable import Ohayo

@MainActor
final class AppWindowActionsTests: XCTestCase {
    func testUITestingArgumentOpensSettingsOnlyInDevelopment() {
        XCTAssertTrue(AppWindowActions.shouldOpenSettingsForUITesting(
            profile: .development,
            arguments: ["Ohayo", "--ui-testing"]
        ))
        XCTAssertFalse(AppWindowActions.shouldOpenSettingsForUITesting(
            profile: .production,
            arguments: ["Ohayo", "--ui-testing"]
        ))
        XCTAssertFalse(AppWindowActions.shouldOpenSettingsForUITesting(
            profile: .development,
            arguments: ["Ohayo"]
        ))
    }

    func testOpenSettingsDefersResponderActionUntilNextRunLoop() {
        var events: [String] = []
        var deferredAction: (@MainActor () -> Void)?

        AppWindowActions.openSettings(
            deferToNextRunLoop: { action in
                events.append("defer")
                deferredAction = action
            },
            activate: {
                events.append("activate")
            },
            sendAction: { selectorName in
                events.append("send:\(selectorName)")
                return selectorName == "showSettingsWindow:"
            }
        )

        XCTAssertEqual(events, ["defer"])

        let action = deferredAction
        deferredAction = nil
        action?()

        XCTAssertEqual(
            events,
            ["defer", "activate", "send:showSettingsWindow:"]
        )
    }
}
