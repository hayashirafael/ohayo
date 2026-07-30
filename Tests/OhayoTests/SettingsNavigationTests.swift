import XCTest
@testable import Ohayo

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testCentralWindowSidebarIncludesGeneralSettings() {
        XCTAssertEqual(
            SettingsSection.sidebarCases,
            [.horarios, .contas, .historico, .geral]
        )
    }

    func testSettingsCommandSelectsGeneralAndClearsAccountFilter() {
        let suite = "SettingsNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let state = AppState(defaults: defaults, home: home)
        state.settingsSection = .historico
        state.accountFilter = home.appendingPathComponent("account")

        OhayoCommands.prepareGeneralNavigation(state: state)

        XCTAssertEqual(state.settingsSection, .geral)
        XCTAssertNil(state.accountFilter)
    }
}
