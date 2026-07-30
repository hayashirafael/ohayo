import XCTest
@testable import Ohayo

final class AppRuntimeProfileTests: XCTestCase {
    func testOfficialBundleIdentifierResolvesProduction() {
        XCTAssertEqual(
            AppRuntimeProfile.resolve(
                bundleIdentifier: AppRuntimeProfile.productionBundleIdentifier
            ),
            .production
        )
    }

    func testDevelopmentBundleIdentifierResolvesDevelopment() {
        XCTAssertEqual(
            AppRuntimeProfile.resolve(
                bundleIdentifier: AppRuntimeProfile.developmentBundleIdentifier
            ),
            .development
        )
    }

    func testUnbundledAndUnknownBundlesFailSafelyToDevelopment() {
        XCTAssertEqual(
            AppRuntimeProfile.resolve(bundleIdentifier: nil),
            .development
        )
        XCTAssertEqual(
            AppRuntimeProfile.resolve(bundleIdentifier: "example.local.Ohayo"),
            .development
        )
    }

    func testProfilesHaveDistinctBundleAndPreferencesIdentities() {
        XCTAssertNotEqual(
            AppRuntimeProfile.production.bundleIdentifier,
            AppRuntimeProfile.development.bundleIdentifier
        )
        XCTAssertNotEqual(
            AppRuntimeProfile.production.preferencesDomainIdentifier,
            AppRuntimeProfile.development.preferencesDomainIdentifier
        )
    }

    func testProductionCapabilitiesRemainEnabled() {
        XCTAssertTrue(AppRuntimeProfile.production.supportsAppUpdates)
        XCTAssertTrue(AppRuntimeProfile.production.supportsLoginItem)
    }

    func testDevelopmentCapabilitiesAreDisabled() {
        XCTAssertFalse(AppRuntimeProfile.development.supportsAppUpdates)
        XCTAssertFalse(AppRuntimeProfile.development.supportsLoginItem)
    }
}

@MainActor
final class AppUpdaterProfileTests: XCTestCase {
    func testDevelopmentDoesNotCreateAnAvailableUpdater() {
        let updater = AppUpdater(profile: .development)

        XCTAssertFalse(updater.isSupported)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        XCTAssertFalse(updater.canCheckForUpdates)
    }
}

final class LoginItemProfileTests: XCTestCase {
    func testDevelopmentLoginItemIsUnavailableAndDisabled() {
        let manager = SystemLoginItemManager(profile: .development)

        XCTAssertFalse(manager.isSupported)
        XCTAssertFalse(manager.isEnabled)
        manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
    }
}
