import XCTest
@testable import Ohayo

final class AppPathsTests: XCTestCase {
    func testProductionSupportWorkspaceAndLockUseOhayoDirectory() {
        let home = URL(fileURLWithPath: "/tmp/ohayo-home")
        let support = home.appendingPathComponent("Library/Application Support/Ohayo")

        XCTAssertEqual(
            AppPaths.supportDirectory(profile: .production, home: home),
            support
        )
        XCTAssertEqual(
            AppPaths.workspaceDirectory(profile: .production, home: home),
            support.appendingPathComponent("workspace")
        )
        XCTAssertEqual(
            AppPaths.instanceLockPath(profile: .production, home: home),
            support.appendingPathComponent("instance.lock").path
        )
        XCTAssertEqual(
            AppPaths.responsesDirectory(profile: .production, home: home),
            support.appendingPathComponent("Responses")
        )
    }

    func testDevelopmentSupportWorkspaceAndLockUseOhayoDevDirectory() {
        let home = URL(fileURLWithPath: "/tmp/ohayo-home")
        let support = home.appendingPathComponent(
            "Library/Application Support/Ohayo Dev"
        )

        XCTAssertEqual(
            AppPaths.supportDirectory(profile: .development, home: home),
            support
        )
        XCTAssertEqual(
            AppPaths.workspaceDirectory(profile: .development, home: home),
            support.appendingPathComponent("workspace")
        )
        XCTAssertEqual(
            AppPaths.instanceLockPath(profile: .development, home: home),
            support.appendingPathComponent("instance.lock").path
        )
        XCTAssertEqual(
            AppPaths.responsesDirectory(profile: .development, home: home),
            support.appendingPathComponent("Responses")
        )
    }
}
