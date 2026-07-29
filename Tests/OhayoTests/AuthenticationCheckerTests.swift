import XCTest
@testable import Ohayo

final class AuthenticationCheckerTests: XCTestCase {
    private func context(
        _ provider: Provider,
        configDirectory: URL
    ) -> ProviderAccountContext {
        ProviderAccountContext(
            provider: provider,
            configDirectory: configDirectory
        )
    }

    func testClaudeNativoContinuaNativoQuandoPastaEhSymlink() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("ohayo-native-symlink-\(UUID().uuidString)")
        let storage = home.appendingPathComponent("storage")
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".claude"),
            withDestinationURL: storage
        )
        defer { try? fm.removeItem(at: home) }

        let context = ProviderAccountContext(
            provider: .claude,
            configDirectory: home.appendingPathComponent(".claude"),
            homeDirectory: home
        )
        let environment = context.applyingAccountEnvironment(
            to: ["CLAUDE_CONFIG_DIR": "/perfil-herdado"]
        )

        XCTAssertTrue(context.isNative)
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(
            context.identityFile,
            home.appendingPathComponent(".claude.json")
        )
    }

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-auth-(UUID().uuidString).sh")
        try! ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testClaudeLoggedInFalseEmStdoutIdentificaLogout() async {
        let binary = makeScript("printf '{\"loggedIn\":false}\\n'; exit 1")
        let checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })

        let result = await checker.status(for: context(
            .claude,
            configDirectory: URL(fileURLWithPath: "/tmp/claude-test")
        ))

        XCTAssertEqual(result, .unauthenticated(log: "{\"loggedIn\":false}"))
    }

    func testClaudeLoggedInTrueAutoriza() async {
        let binary = makeScript("printf '{\"loggedIn\":true}\\n'; exit 0")
        let checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })

        let result = await checker.status(for: context(
            .claude,
            configDirectory: URL(fileURLWithPath: "/tmp/claude-test")
        ))

        XCTAssertEqual(result, .authenticated)
    }

    func testClaudeNativoNaoExportaClaudeConfigDir() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-env-\(UUID().uuidString).txt")
        let binary = makeScript(
            "printf '%s' \"${CLAUDE_CONFIG_DIR-<unset>}\" > '\(envFile.path)'; "
                + "printf '{\"loggedIn\":true}\\n'; exit 0"
        )
        let checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })

        _ = await checker.status(for: context(
            .claude,
            configDirectory: AppState.defaultConfigDir
        ))

        XCTAssertEqual(try String(contentsOf: envFile, encoding: .utf8), "<unset>")
    }

    func testClaudeCustomPreservaClaudeConfigDir() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-env-\(UUID().uuidString).txt")
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-custom-\(UUID().uuidString)")
        let binary = makeScript(
            "printf '%s' \"$CLAUDE_CONFIG_DIR\" > '\(envFile.path)'; "
                + "printf '{\"loggedIn\":true}\\n'; exit 0"
        )
        let checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })

        _ = await checker.status(for: context(
            .claude,
            configDirectory: custom
        ))

        XCTAssertEqual(try String(contentsOf: envFile, encoding: .utf8), custom.path)
    }

    func testCodexMensagemNotLoggedInIdentificaLogout() async {
        let binary = makeScript("echo 'Not logged in' >&2; exit 1")
        let checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })

        let result = await checker.status(for: context(
            .codex,
            configDirectory: URL(fileURLWithPath: "/tmp/codex-test")
        ))

        XCTAssertEqual(result, .unauthenticated(log: "Not logged in"))
    }

    func testSaidaDesconhecidaNaoBloqueia() async {
        let binary = makeScript("echo 'unsupported command' >&2; exit 2")
        let checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })

        let result = await checker.status(for: context(
            .claude,
            configDirectory: URL(fileURLWithPath: "/tmp/claude-test")
        ))

        XCTAssertEqual(result, .unknown)
    }

    func testCheckerFixaDiretorioDaContaNoAmbiente() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-env-\(UUID().uuidString).txt")
        let binary = makeScript("printf '%s' \"$CODEX_HOME\" > '\(envFile.path)'; exit 0")
        let conta = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-account-\(UUID().uuidString)")
        let checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })

        _ = await checker.status(for: context(
            .codex,
            configDirectory: conta
        ))

        XCTAssertEqual(try String(contentsOf: envFile, encoding: .utf8), conta.path)
    }
}
