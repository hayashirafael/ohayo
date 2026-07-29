import XCTest
@testable import Ohayo

final class FireResultPresentationTests: XCTestCase {
    func testTerminalLaunchedHasDistinctPersistedResultAndLocalizedCopy() throws {
        let data = try JSONEncoder().encode(FireResult.launched)
        XCTAssertEqual(try JSONDecoder().decode(FireResult.self, from: data), .launched)

        XCTAssertEqual(L10n(language: .english).historyLaunched, "Launched")
        XCTAssertEqual(L10n(language: .portuguese).historyLaunched, "Iniciado")
        XCTAssertEqual(
            L10n(language: .english).historyTerminalLaunched,
            "Interactive session opened in Terminal"
        )
        XCTAssertEqual(
            L10n(language: .portuguese).historyTerminalLaunched,
            "Sessão interativa aberta no Terminal"
        )
    }
}
