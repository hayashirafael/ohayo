import Foundation
import XCTest
@testable import Ohayo

private extension TerminalLauncher {
    func launchAuthorizationTestMessage(
        _ message: Message
    ) async -> Result<Void, RunnerError> {
        let prepared = DispatchPreparer(
            isDirectory: { _ in true }
        ).prepare(.direct(message, origin: .manual))
        guard case .success(let dispatch) = prepared else {
            return .failure(.failed("fixture de dispatch inválida"))
        }
        return await launch(dispatch)
    }
}

final class TerminalLauncherDirectoryAuthorizationTests: XCTestCase {
    func testProjetoExplicitoExistenteNaoETentadoCriarPeloOhayo() async throws {
        let account = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: account)
            try? FileManager.default.removeItem(at: project)
        }
        let createdDirectories = PathRecorder()
        var launcher = TerminalLauncher(
            claudeBinaryOverride: URL(fileURLWithPath: "/tmp/fake-claude")
        )
        launcher.directoryCreator = { createdDirectories.paths.append($0) }
        launcher.appleScriptRunner = { _ in .success(()) }
        let message = Message(
            text: "oi",
            kind: .claude,
            configDir: account.path,
            workingDir: project.path
        )

        guard case .success =
                await launcher.launchAuthorizationTestMessage(message) else {
            return XCTFail("launch deveria ter sucesso")
        }

        XCTAssertEqual(
            createdDirectories.paths,
            [],
            "um projeto escolhido já existe e não deve ser recriado pelo Ohayo"
        )
    }

    func testClaudePreAutorizaTrustBasicoDoProjetoEscolhidoUmaUnicaVez() async throws {
        let account = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: account)
            try? FileManager.default.removeItem(at: project)
        }
        let canonicalProject = project.resolvingSymlinksInPath().path
        let identityURL = account.appendingPathComponent(".claude.json")
        let existing: [String: Any] = [
            "oauthAccount": ["emailAddress": "preservar@example.com"],
            "projects": [
                canonicalProject: ["allowedTools": ["Read"]],
                "/outro/projeto": ["hasTrustDialogAccepted": false],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: existing,
            options: [.sortedKeys]
        ).write(to: identityURL)
        var launcher = TerminalLauncher(
            claudeBinaryOverride: URL(fileURLWithPath: "/tmp/fake-claude")
        )
        launcher.appleScriptRunner = { _ in .success(()) }
        let message = Message(
            text: "oi",
            kind: .claude,
            configDir: account.path,
            workingDir: project.path
        )

        guard case .success =
                await launcher.launchAuthorizationTestMessage(message) else {
            return XCTFail("primeiro launch deveria ter sucesso")
        }
        let afterFirstLaunch = try Data(contentsOf: identityURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: afterFirstLaunch)
                as? [String: Any]
        )
        let projects = try XCTUnwrap(root["projects"] as? [String: Any])
        let entry = try XCTUnwrap(
            projects[canonicalProject] as? [String: Any]
        )

        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertNil(entry["hasClaudeMdExternalIncludesApproved"])
        XCTAssertNil(entry["hasClaudeMdExternalIncludesWarningShown"])
        XCTAssertEqual(entry["allowedTools"] as? [String], ["Read"])
        XCTAssertNotNil(root["oauthAccount"])
        XCTAssertNotNil(projects["/outro/projeto"])

        guard case .success =
                await launcher.launchAuthorizationTestMessage(message) else {
            return XCTFail("segundo launch deveria ter sucesso")
        }
        XCTAssertEqual(
            try Data(contentsOf: identityURL),
            afterFirstLaunch,
            "trust já aceito deve tornar lançamentos seguintes idempotentes"
        )
    }

    func testCodexUsaOverrideDeTrustCanonicoSemRegravarConfigToml() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("codex-account")
        let realProject = root.appendingPathComponent(
            #"projeto "cotado" \ com espaço"#
        )
        let projectAlias = root.appendingPathComponent("atalho-do-projeto")
        try FileManager.default.createDirectory(
            at: account,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: realProject,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: projectAlias,
            withDestinationURL: realProject
        )
        let configURL = account.appendingPathComponent("config.toml")
        let originalConfig = Data(
            """
            # comentários e formatação pertencem ao usuário
            model = "gpt-test"

            [mcp_servers.existing]
            enabled = true
            """.utf8
        )
        try originalConfig.write(to: configURL)
        let message = Message(
            text: "revise",
            kind: .codex,
            configDir: account.path,
            workingDir: projectAlias.path
        )
        let binary = URL(fileURLWithPath: "/tmp/fake-codex")

        let spec = try XCTUnwrap(
            TerminalLauncher.spec(for: message, codexBinary: binary)
        )
        let canonicalPath = realProject.resolvingSymlinksInPath().path
        let override = #"projects."\#(tomlBasicString(canonicalPath))".trust_level="trusted""#
        XCTAssertTrue(
            spec.terminalScript.contains("'-c' '\(override)'"),
            "o launch interativo deve confiar apenas esta execução via override oficial do Codex"
        )
        XCTAssertFalse(
            spec.terminalScript.contains(
                #"projects."\#(tomlBasicString(projectAlias.path))".trust_level"#
            ),
            "a chave de trust não pode usar o caminho simbólico cru"
        )
        XCTAssertEqual(try Data(contentsOf: configURL), originalConfig)

        var launcher = TerminalLauncher(codexBinaryOverride: binary)
        launcher.appleScriptRunner = { _ in .success(()) }
        guard case .success =
                await launcher.launchAuthorizationTestMessage(message) else {
            return XCTFail("launch deveria ter sucesso")
        }
        XCTAssertEqual(
            try Data(contentsOf: configURL),
            originalConfig,
            "o Ohayo não deve reserializar nem editar config.toml"
        )
    }

    func testOptOutNaoPreAutorizaTrustDoClaudeNemDoCodex() async throws {
        let account = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: account)
            try? FileManager.default.removeItem(at: project)
        }
        let claude = Message(
            text: "revise",
            kind: .claude,
            configDir: account.path,
            workingDir: project.path,
            trustWorkingDirectory: false
        )
        let codex = Message(
            text: "revise",
            kind: .codex,
            configDir: account.path,
            workingDir: project.path,
            trustWorkingDirectory: false
        )
        var launcher = TerminalLauncher(
            claudeBinaryOverride: URL(
                fileURLWithPath: "/tmp/fake-claude"
            )
        )
        launcher.appleScriptRunner = { _ in .success(()) }

        guard case .success =
                await launcher.launchAuthorizationTestMessage(claude) else {
            return XCTFail("launch do Claude deveria continuar permitido")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: account.appendingPathComponent(".claude.json").path
            )
        )

        let codexSpec = try XCTUnwrap(
            TerminalLauncher.spec(
                for: codex,
                codexBinary: URL(fileURLWithPath: "/tmp/fake-codex")
            )
        )
        XCTAssertFalse(
            codexSpec.terminalScript.contains("trust_level")
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ohayo-directory-authorization-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func tomlBasicString(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }

    private final class PathRecorder {
        var paths: [String] = []
    }
}
