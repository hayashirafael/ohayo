import XCTest
@testable import Ohayo

final class CodexPluginInventoryLoaderTests: XCTestCase {
    func testCancelamentoCooperativoInterrompeLocalizacaoDoCodex() async throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-plugin-loader-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: configDirectory)
        }

        let locatorStarted = expectation(
            description: "localizador iniciou"
        )
        let cancellationObserved = expectation(
            description: "localizador recebeu cancelamento"
        )
        let loadTask = Task {
            await CodexPluginInventoryLoader.load(
                configDirectory: configDirectory,
                binaryLocator: { isCancelled in
                    locatorStarted.fulfill()
                    let deadline = Date().addingTimeInterval(2)
                    while !isCancelled(), Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    if isCancelled() {
                        cancellationObserved.fulfill()
                    }
                    return nil
                }
            )
        }

        await fulfillment(of: [locatorStarted], timeout: 1)
        loadTask.cancel()
        await fulfillment(of: [cancellationObserved], timeout: 1)

        let inventory = await loadTask.value
        XCTAssertNil(inventory)
    }
}
