import XCTest
@testable import Ohayo

final class ProviderTests: XCTestCase {
    private func makeDir(_ contents: [String] = [], dirs: [String] = []) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("conta-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in contents {
            try "{}".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for name in dirs {
            try fm.createDirectory(at: dir.appendingPathComponent(name),
                                   withIntermediateDirectories: true)
        }
        return dir
    }

    func testDetectPorAssinaturaDeConteudo() throws {
        // O nome da pasta é livre — só o conteúdo decide.
        XCTAssertEqual(Provider.detect(at: try makeDir([".claude.json"])), .claude)
        XCTAssertEqual(Provider.detect(at: try makeDir([], dirs: ["projects"])), .claude)
        XCTAssertEqual(Provider.detect(at: try makeDir(["auth.json"])), .codex)
        XCTAssertEqual(Provider.detect(at: try makeDir([], dirs: ["sessions"])), .codex)
    }

    func testDetectAmbiguaUsaPrecedenciaEInvalidaRetornaNil() throws {
        // Assinatura ambígua (Claude e Codex): .claude.json tem precedência.
        XCTAssertEqual(Provider.detect(at: try makeDir([".claude.json", "auth.json"])), .claude)
        // Pasta sem assinatura de nenhum provider → nil.
        XCTAssertNil(Provider.detect(at: try makeDir()))
        // Pasta inexistente → nil.
        XCTAssertNil(Provider.detect(at: URL(fileURLWithPath: "/nao/existe/\(UUID())")))
    }

    func testAtributosPorProvider() {
        XCTAssertEqual(Provider.claude.transcriptsSubpath, "projects")
        XCTAssertEqual(Provider.codex.transcriptsSubpath, "sessions")
        XCTAssertEqual(Provider.claude.envKey, "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(Provider.codex.envKey, "CODEX_HOME")
        XCTAssertEqual(Provider.codex.displayName, "Codex")
        XCTAssertEqual(Provider.codex.cliName, "codex")
        XCTAssertEqual(Provider.claude.usageWindowDuration, 5 * 3600)
        XCTAssertEqual(Provider.codex.usageWindowDuration, 5 * 3600)
    }
}
