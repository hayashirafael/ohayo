import Combine
import XCTest
@testable import Ohayo

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testPublishesTheVersionWhenSparkleFindsAnUpdate() {
        let checker = UpdateCheckerSpy()
        let updater = AppUpdater(checker: checker)

        checker.reportAvailable(version: "1.3.0")

        XCTAssertEqual(updater.availableVersion, "1.3.0")
    }

    func testClearsTheNoticeWhenSparkleFindsNoUpdate() {
        let checker = UpdateCheckerSpy()
        let updater = AppUpdater(checker: checker)
        checker.reportAvailable(version: "1.3.0")

        checker.reportUnavailable()

        XCTAssertNil(updater.availableVersion)
    }

    func testInstallAvailableUpdateHandsOffToSparkle() {
        let checker = UpdateCheckerSpy()
        let updater = AppUpdater(checker: checker)
        checker.reportAvailable(version: "1.3.0")

        updater.installAvailableUpdate()

        XCTAssertEqual(checker.checkForUpdatesCallCount, 1)
    }
}

@MainActor
private final class UpdateCheckerSpy: UpdateChecking {
    var canCheckForUpdates = true
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        Just(canCheckForUpdates).eraseToAnyPublisher()
    }
    var onUpdateAvailable: ((String) -> Void)?
    var onUpdateUnavailable: (() -> Void)?
    private(set) var checkForUpdatesCallCount = 0

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func reportAvailable(version: String) {
        onUpdateAvailable?(version)
    }

    func reportUnavailable() {
        onUpdateUnavailable?()
    }
}
