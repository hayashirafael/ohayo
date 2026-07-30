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

    func testDocumentsAccessPromptExplainsScheduledFolderUseInBothLanguages()
        throws {
        let info = try repositoryInfoPlist()
        let fallback = try XCTUnwrap(
            info["NSDocumentsFolderUsageDescription"] as? String
        )
        XCTAssertTrue(fallback.contains("folders you select"))

        let scripts = repositoryScriptsDirectory()
        let english = try String(
            contentsOf: scripts
                .appendingPathComponent("en.lproj/InfoPlist.strings"),
            encoding: .utf8
        )
        let portuguese = try String(
            contentsOf: scripts
                .appendingPathComponent("pt-BR.lproj/InfoPlist.strings"),
            encoding: .utf8
        )
        XCTAssertTrue(english.contains(
            #""NSDocumentsFolderUsageDescription""#
        ))
        XCTAssertTrue(portuguese.contains(
            #""NSDocumentsFolderUsageDescription""#
        ))
        XCTAssertTrue(portuguese.contains("pastas que você escolher"))
    }

    private func repositoryInfoPlist() throws -> [String: Any] {
        let url = repositoryScriptsDirectory()
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )
    }

    private func repositoryScriptsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts", isDirectory: true)
    }
}
