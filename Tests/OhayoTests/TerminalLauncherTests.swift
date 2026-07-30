import XCTest
@testable import Ohayo

private extension TerminalLauncher {
    /// Os testes de integração montam o mesmo contrato imutável usado pelo
    /// FireController sem manter um atalho baseado em `Message` em produção.
    func launchTestMessage(
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

final class TerminalLauncherTests: XCTestCase {
    func testClaudeInterativoNaoUsaPrintEMontaAmbiente() throws {
        let binary = URL(fileURLWithPath: "/tmp/fake claude")
        let msg = Message(text: "bom dia 'hoje'", kind: .claude,
                          model: .opus, effort: .high, safeMode: false,
                          configDir: "/tmp/conta claude",
                          workingDir: "/tmp/projeto teste")

        let spec = try XCTUnwrap(TerminalLauncher.spec(for: msg, claudeBinary: binary))

        XCTAssertTrue(spec.terminalScript.contains("export CLAUDE_CONFIG_DIR='/tmp/conta claude'"))
        XCTAssertTrue(spec.terminalScript.contains("cd '/tmp/projeto teste'"))
        XCTAssertTrue(spec.terminalScript.contains("'/tmp/fake claude'"))
        XCTAssertTrue(spec.terminalScript.contains("'--model' 'claude-opus-4-8'"))
        XCTAssertTrue(spec.terminalScript.contains("'--effort' 'high'"))
        XCTAssertTrue(spec.terminalScript.contains("'bom dia '\\''hoje'\\'''"))
        XCTAssertFalse(spec.terminalScript.contains(" '-p' "))
        // O login shell do Terminal já tem o PATH do usuário e o binário é
        // invocado por caminho absoluto — exportar o PATH herdado do app
        // (gigante/duplicado) truncava o comando no Terminal.
        XCTAssertFalse(spec.terminalScript.contains("export PATH"))
    }

    func testClaudeNativoNaoExportaClaudeConfigDirNoTerminal() throws {
        let nativeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let msg = Message(text: "oi", kind: .claude,
                          configDir: nativeDir.path,
                          workingDir: "/tmp/projeto")

        let spec = try XCTUnwrap(TerminalLauncher.spec(
            for: msg, claudeBinary: URL(fileURLWithPath: "/tmp/claude")
        ))

        XCTAssertFalse(spec.terminalScript.contains("export CLAUDE_CONFIG_DIR"))
        XCTAssertEqual(spec.accountDir, nativeDir.path)
    }

    func testDiretorioInacessivelInterrompeAntesDeExecutarOProvider() throws {
        let binary = URL(fileURLWithPath: "/tmp/fake claude")
        let message = Message(
            text: "oi",
            kind: .claude,
            workingDir: "/tmp/projeto removido"
        )

        let spec = try XCTUnwrap(
            TerminalLauncher.spec(for: message, claudeBinary: binary)
        )

        XCTAssertTrue(
            spec.terminalScript.contains(
                "cd '/tmp/projeto removido' && '/tmp/fake claude'"
            ),
            "falha no cd não pode deixar o CLI executar no home do Terminal"
        )
    }

    func testLaunchEscreveScriptEmArquivoTemporarioERodaViaSh() async throws {
        let captured = Captura()
        var launcher = TerminalLauncher(claudeBinaryOverride: URL(fileURLWithPath: "/tmp/fake claude"))
        launcher.appleScriptRunner = { script in
            captured.script = script
            return .success(())
        }
        let msg = Message(text: "bom dia", kind: .claude,
                          configDir: "/tmp/conta claude", workingDir: "/tmp/proj")

        guard case .success = await launcher.launchTestMessage(msg) else {
            return XCTFail("launch deveria ter sucesso")
        }

        let script = try XCTUnwrap(captured.script)
        // O do script roda o arquivo, não o comando inteiro embutido (imune a
        // truncamento com prompts longos).
        XCTAssertTrue(script.contains(#"do script "/bin/sh '"#))
        let regex = try NSRegularExpression(pattern: #"/bin/sh '([^']+)'"#)
        let range = NSRange(script.startIndex..., in: script)
        let match = try XCTUnwrap(regex.firstMatch(in: script, range: range))
        let path = String(script[Range(match.range(at: 1), in: script)!])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("export CLAUDE_CONFIG_DIR='/tmp/conta claude'"))
        XCTAssertTrue(content.contains("cd '/tmp/proj'"))
        XCTAssertTrue(content.contains("'/tmp/fake claude'"))
        XCTAssertTrue(content.contains("trap cleanup EXIT"))
        XCTAssertTrue(content.contains("trap 'exit 129' HUP"))
        XCTAssertTrue(content.contains("trap 'exit 130' INT"))
        XCTAssertTrue(content.contains("trap 'exit 143' TERM"))
        XCTAssertTrue(content.contains("cleanup() { rm -f -- '\(path)'; }"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testLimpaSomenteScriptsTemporariosAntigosDoOhayo() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("ohayo-terminal-old.sh")
        let fresh = directory.appendingPathComponent("ohayo-terminal-fresh.sh")
        let unrelated = directory.appendingPathComponent("other-old.sh")
        for file in [old, fresh, unrelated] {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: file.path, contents: Data("secret".utf8)
            ))
        }
        let now = Date(timeIntervalSince1970: 10_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3_601)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: fresh.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3_601)],
            ofItemAtPath: unrelated.path
        )

        TerminalLauncher.cleanupStaleScripts(in: directory, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testLimpezaDeStartupRemoveResiduoRecenteSemEsperarOutroLaunch() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let residue = directory.appendingPathComponent("ohayo-terminal-crash.sh")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: residue.path, contents: Data("prompt".utf8)
        ))
        let now = Date(timeIntervalSince1970: 20_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1)],
            ofItemAtPath: residue.path
        )

        TerminalLauncher.cleanupStaleScripts(
            in: directory,
            now: now,
            olderThan: 0
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: residue.path))
    }

    func testSpecUsaWorkspaceDoAppComoDiretorioPadrao() throws {
        // O default NÃO pode ser o home: o Claude Code nunca persiste o trust
        // do home (só por sessão), então abrir lá pede confirmação toda vez.
        let msg = Message(text: "oi", kind: .claude) // sem workingDir
        let workspace = URL(fileURLWithPath: "/tmp/Ohayo/workspace")
        let spec = try XCTUnwrap(TerminalLauncher.spec(
            for: msg, claudeBinary: URL(fileURLWithPath: "/tmp/claude"),
            defaultWorkspace: workspace))
        XCTAssertTrue(spec.terminalScript.contains("cd '\(workspace.path)'"))
        XCTAssertTrue(spec.usesOhayoManagedWorkspace)
    }

    func testLaunchDeProjetoEscolhidoPreAutorizaSomenteTrustBasico() async throws {
        let conta = try makeTempDir()
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: conta); try? FileManager.default.removeItem(at: proj) }
        // Escolher e persistir a pasta no formulário é o consentimento básico.
        // Imports externos continuam dependendo da decisão explícita no Claude.
        let existente: [String: Any] = [
            "oauthAccount": ["emailAddress": "x@y.z"],
            "projects": ["/outra": ["hasTrustDialogAccepted": false, "allowedTools": ["Bash"]]]
        ]
        let jsonURL = conta.appendingPathComponent(".claude.json")
        let bytesOriginais = try JSONSerialization.data(withJSONObject: existente)
        try bytesOriginais.write(to: jsonURL)

        var launcher = TerminalLauncher(claudeBinaryOverride: URL(fileURLWithPath: "/tmp/claude"))
        launcher.appleScriptRunner = { _ in .success(()) }
        let msg = Message(text: "oi", kind: .claude,
                          configDir: conta.path, workingDir: proj.path)
        guard case .success = await launcher.launchTestMessage(msg) else { return XCTFail() }

        let bytesAtualizados = try Data(contentsOf: jsonURL)
        let atualizado = try JSONSerialization.jsonObject(with: bytesAtualizados) as! [String: Any]
        let projects = atualizado["projects"] as! [String: Any]
        let entrada = projects[proj.resolvingSymlinksInPath().path] as! [String: Any]
        XCTAssertEqual(entrada["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertNil(entrada["hasClaudeMdExternalIncludesApproved"])
        XCTAssertNil(entrada["hasClaudeMdExternalIncludesWarningShown"])
        XCTAssertEqual(
            (atualizado["oauthAccount"] as? [String: String])?["emailAddress"],
            "x@y.z"
        )
        let outra = projects["/outra"] as! [String: Any]
        XCTAssertEqual(outra["hasTrustDialogAccepted"] as? Bool, false)
        XCTAssertEqual(outra["allowedTools"] as? [String], ["Bash"])
    }

    func testLaunchNoWorkspaceControladoCriaClaudeJsonQuandoAusente() async throws {
        let conta = try makeTempDir()
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: conta); try? FileManager.default.removeItem(at: proj) }
        var launcher = TerminalLauncher(claudeBinaryOverride: URL(fileURLWithPath: "/tmp/claude"))
        launcher.defaultWorkspaceOverride = proj
        launcher.appleScriptRunner = { _ in .success(()) }
        let msg = Message(text: "oi", kind: .claude, configDir: conta.path)
        guard case .success = await launcher.launchTestMessage(msg) else { return XCTFail() }

        let json = try JSONSerialization.jsonObject(with: Data(
            contentsOf: conta.appendingPathComponent(".claude.json"))) as! [String: Any]
        let entrada = (json["projects"] as! [String: Any])[proj.resolvingSymlinksInPath().path] as! [String: Any]
        XCTAssertEqual(entrada["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertNil(entrada["hasClaudeMdExternalIncludesApproved"])
        XCTAssertNil(entrada["hasClaudeMdExternalIncludesWarningShown"])
    }

    func testSeedTrustClaudeNativoUsaClaudeJsonNoHome() throws {
        let home = try makeTempDir()
        let nativeDir = home.appendingPathComponent(".claude")
        let proj = try makeTempDir()
        try FileManager.default.createDirectory(at: nativeDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: proj)
        }

        TerminalLauncher.seedTrust(
            accountDir: nativeDir.path,
            workingDir: proj.path,
            homeDirectory: home
        )

        let rootFile = home.appendingPathComponent(".claude.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: rootFile)
        ) as! [String: Any]
        let projects = json["projects"] as! [String: Any]
        XCTAssertNotNil(projects[proj.resolvingSymlinksInPath().path])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: nativeDir.appendingPathComponent(".claude.json").path
        ))
    }

    func testLaunchNaoPreAprovaImportsExternosMesmoComTrustAceito() async throws {
        // Mesmo no workspace controlado, imports de CLAUDE.md fora do projeto
        // exigem consentimento visível no Terminal.
        let conta = try makeTempDir()
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: conta); try? FileManager.default.removeItem(at: proj) }
        // Fixture sob a chave canônica (é assim que o CLI a grava).
        let key = proj.resolvingSymlinksInPath().path
        let existente: [String: Any] = [
            "projects": [key: ["hasTrustDialogAccepted": false]]
        ]
        let jsonURL = conta.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: existente).write(to: jsonURL)

        var launcher = TerminalLauncher(claudeBinaryOverride: URL(fileURLWithPath: "/tmp/claude"))
        launcher.defaultWorkspaceOverride = proj
        launcher.appleScriptRunner = { _ in .success(()) }
        let msg = Message(text: "oi", kind: .claude, configDir: conta.path)
        guard case .success = await launcher.launchTestMessage(msg) else { return XCTFail() }

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as! [String: Any]
        let entrada = (json["projects"] as! [String: Any])[key] as! [String: Any]
        XCTAssertEqual(entrada["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertNil(entrada["hasClaudeMdExternalIncludesApproved"])
        XCTAssertNil(entrada["hasClaudeMdExternalIncludesWarningShown"])
    }

    func testSeedTrustPreservaConsentimentoDeImportsExistente() throws {
        let conta = try makeTempDir()
        let proj = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: conta)
            try? FileManager.default.removeItem(at: proj)
        }
        let key = proj.resolvingSymlinksInPath().path
        let existente: [String: Any] = [
            "projects": [key: [
                "hasTrustDialogAccepted": false,
                "hasClaudeMdExternalIncludesApproved": true,
                "hasClaudeMdExternalIncludesWarningShown": true,
            ]]
        ]
        let jsonURL = conta.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: existente).write(to: jsonURL)

        TerminalLauncher.seedTrust(accountDir: conta.path, workingDir: proj.path)

        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: jsonURL)
        ) as! [String: Any]
        let entry = (json["projects"] as! [String: Any])[key] as! [String: Any]
        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(entry["hasClaudeMdExternalIncludesApproved"] as? Bool, true)
        XCTAssertEqual(entry["hasClaudeMdExternalIncludesWarningShown"] as? Bool, true)
    }

    func testLaunchNaoSobrescreveClaudeJsonIlegivel() async throws {
        // Regressão de perda de dados: um .claude.json que EXISTE mas cujo
        // parse falha (bytes truncados por escrita concorrente do CLI, JSON
        // corrompido) não pode ser obliterado. O seedTrust antigo deixava
        // root=[:] e regravava {"projects":{…}} por cima — apagando
        // oauthAccount, trust de outros projetos e settings. Sem lugar seguro
        // para semear, o correto é não escrever e deixar o prompt aparecer.
        let conta = try makeTempDir()
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: conta); try? FileManager.default.removeItem(at: proj) }
        let jsonURL = conta.appendingPathComponent(".claude.json")
        let bytesCorrompidos = Data(#"{"oauthAccount":{"emailAddress":"x@y.z"},"projec"#.utf8)
        try bytesCorrompidos.write(to: jsonURL)

        var launcher = TerminalLauncher(claudeBinaryOverride: URL(fileURLWithPath: "/tmp/claude"))
        launcher.defaultWorkspaceOverride = proj
        launcher.appleScriptRunner = { _ in .success(()) }
        let msg = Message(text: "oi", kind: .claude, configDir: conta.path)
        guard case .success = await launcher.launchTestMessage(msg) else { return XCTFail() }

        // O arquivo permanece byte a byte intacto — nada foi destruído.
        XCTAssertEqual(try Data(contentsOf: jsonURL), bytesCorrompidos)
    }

    func testSeedTrustUsaCaminhoCanonicalizadoComoChave() throws {
        // Um working dir com barra final e segmento `/./` deve virar a MESMA
        // chave canônica que o CLI usaria (getcwd após o cd) — senão o trust
        // semeado não casa e a sessão trava no prompt.
        let conta = try makeTempDir()
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: conta); try? FileManager.default.removeItem(at: proj) }
        let naoCanonico = proj.path + "/./"

        TerminalLauncher.seedTrust(
            accountDir: conta.path,
            workingDir: naoCanonico
        )

        let json = try JSONSerialization.jsonObject(with: Data(
            contentsOf: conta.appendingPathComponent(".claude.json"))) as! [String: Any]
        let projects = json["projects"] as! [String: Any]
        let canonico = proj.resolvingSymlinksInPath().path
        XCTAssertNotNil(projects[canonico], "trust não foi semeado sob a chave canônica")
        XCTAssertNil(projects[naoCanonico], "a chave crua (não canônica) não deveria existir")
        XCTAssertEqual(projects.count, 1)
    }

    func testScriptTemporarioRemovidoQuandoAppleScriptFalha() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        func scriptsDoTerminal() -> Set<String> {
            let all = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            return Set(all.filter { $0.hasPrefix("ohayo-terminal-") && $0.hasSuffix(".sh") })
        }
        let antes = scriptsDoTerminal()
        let conta = try makeTempDir()
        let proj = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: conta); try? FileManager.default.removeItem(at: proj) }

        var launcher = TerminalLauncher(claudeBinaryOverride: URL(fileURLWithPath: "/tmp/claude"))
        launcher.appleScriptRunner = { _ in .failure(.failed("Terminal não abriu")) }
        let msg = Message(text: "oi", kind: .claude, configDir: conta.path, workingDir: proj.path)
        guard case .failure = await launcher.launchTestMessage(msg) else { return XCTFail() }

        XCTAssertEqual(scriptsDoTerminal().subtracting(antes), [],
                       "o script temporário vazou após a falha do AppleScript")
    }

    func testLaunchCodexNaoMexeEmClaudeJson() async throws {
        let conta = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: conta) }
        var launcher = TerminalLauncher(codexBinaryOverride: URL(fileURLWithPath: "/tmp/codex"))
        launcher.appleScriptRunner = { _ in .success(()) }
        let msg = Message(text: "oi", kind: .codex, configDir: conta.path, workingDir: conta.path)
        guard case .success = await launcher.launchTestMessage(msg) else { return XCTFail() }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: conta.appendingPathComponent(".claude.json").path))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Caixa de captura para o runner fake (struct não deixa mutar var local
    /// de fora do closure de forma limpa).
    private final class Captura { var script: String? }

    func testCodexInterativoNaoUsaExecEMontaReasoning() throws {
        let binary = URL(fileURLWithPath: "/tmp/fake-codex")
        var msg = Message(text: "revise isso", kind: .codex,
                          configDir: "/tmp/conta-codex",
                          workingDir: "/tmp/proj")
        msg.codexModel = "gpt-5.5"
        msg.codexReasoning = .high

        let spec = try XCTUnwrap(TerminalLauncher.spec(for: msg, codexBinary: binary))

        XCTAssertTrue(spec.terminalScript.contains("export CODEX_HOME='/tmp/conta-codex'"))
        XCTAssertTrue(spec.terminalScript.contains("cd '/tmp/proj'"))
        XCTAssertTrue(spec.terminalScript.contains("'/tmp/fake-codex'"))
        XCTAssertTrue(spec.terminalScript.contains("'--model' 'gpt-5.5'"))
        XCTAssertTrue(
            spec.terminalScript.contains("'--sandbox' 'workspace-write'")
        )
        XCTAssertTrue(spec.terminalScript.contains("'-c' 'model_reasoning_effort=\"high\"'"))
        XCTAssertTrue(spec.terminalScript.contains("'revise isso'"))
        XCTAssertFalse(spec.terminalScript.contains("'exec'"))
    }

    func testAppleScriptEscapaComandoParaDoScript() {
        let script = TerminalLauncher.appleScript(forTerminalScript: #"echo "oi"; printf '\\'"#)
        XCTAssertTrue(script.contains(#"do script "echo \"oi\"; printf '\\\\'"#))
    }

    func testSpecClaudeComSkillPrefixaPromptEOmiteSafeMode() throws {
        var msg = Message(text: "bom dia", kind: .claude)
        msg.skill = "superpowers:brainstorming"
        let spec = try XCTUnwrap(TerminalLauncher.spec(
            for: msg, claudeBinary: URL(fileURLWithPath: "/tmp/claude")))
        XCTAssertTrue(spec.terminalScript.contains("'/superpowers:brainstorming bom dia'"))
        XCTAssertFalse(spec.terminalScript.contains("--safe-mode"))
    }

    func testSpecCodexComSkillPrefixaCifrao() throws {
        var msg = Message(text: "oi", kind: .codex)
        msg.skill = "gmud"
        let spec = try XCTUnwrap(TerminalLauncher.spec(
            for: msg, codexBinary: URL(fileURLWithPath: "/tmp/codex")))
        XCTAssertTrue(spec.terminalScript.contains("'$gmud oi'"))
    }
}
