import Foundation
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testInfoPlistConfiguresSecureSparkleFeed() throws {
        let info = try repositoryInfoPlist()

        XCTAssertEqual(
            info["SUFeedURL"] as? String,
            "https://github.com/hayashirafael/ohayo/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)

        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)

        let buildVersion = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotEqual(buildVersion, "1")
        XCTAssertNotNil(Int(buildVersion))
    }

    private func repositoryInfoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )
    }
}
