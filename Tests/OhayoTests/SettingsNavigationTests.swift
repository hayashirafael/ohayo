import XCTest
@testable import Ohayo

final class SettingsNavigationTests: XCTestCase {
    func testCentralWindowSidebarIncludesGeneralSettings() {
        XCTAssertEqual(
            SettingsSection.sidebarCases,
            [.horarios, .contas, .historico, .geral]
        )
    }
}
