import AppKit
import Foundation

protocol TerminalLaunching {
    func launch(_ message: Message) async -> Result<Void, RunnerError>
}

struct TerminalLaunchSpec: Equatable {
    let terminalScript: String
    /// Pasta da conta usada no env (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`).
    let accountDir: String
    /// Diretório de trabalho resolvido (o do workspace do app quando a
    /// mensagem não define um).
    let workingDir: String
    /// Somente o workspace criado/controlado pelo Ohayo pode receber trust
    /// automático. Projetos explícitos preservam o prompt do Claude.
    let usesOhayoManagedWorkspace: Bool
}

struct TerminalLauncher: TerminalLaunching {
    private static let temporaryScriptPrefix = "ohayo-terminal-"
    private static let staleScriptAge: TimeInterval = 60 * 60

    var claudeBinaryOverride: URL?
    var codexBinaryOverride: URL?
    var defaultWorkspaceOverride: URL?
    var appleScriptRunner: (String) -> Result<Void, RunnerError> = Self.runAppleScript

    func launch(_ message: Message) async -> Result<Void, RunnerError> {
        Self.cleanupStaleScripts()
        guard let spec = Self.spec(
            for: message,
            claudeBinary: claudeBinaryOverride,
            codexBinary: codexBinaryOverride,
            defaultWorkspace: defaultWorkspaceOverride
        ) else {
            return .failure(.cliNotFound(message.kind == .codex ? .codex : .claude))
        }
        // Garante o diretório de trabalho. Só o workspace padrão, criado e
        // controlado pelo Ohayo, recebe trust automático; projetos escolhidos
        // preservam o prompt visível do Claude no Terminal.
        // Falha no seed não impede o launch: no pior caso o prompt aparece.
        try? FileManager.default.createDirectory(
            atPath: spec.workingDir, withIntermediateDirectories: true)
        if message.kind == .claude, spec.usesOhayoManagedWorkspace {
            Self.seedTrust(accountDir: spec.accountDir, workingDir: spec.workingDir)
        }
        // O script vai num arquivo temporário em vez de embutido no
        // `do script`: comandos longos (prompt grande, PATH inflado) chegavam
        // truncados no Terminal e nunca executavam. O arquivo nasce privado
        // (0600) e um trap o remove tanto no término normal quanto em sinais.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(Self.temporaryScriptPrefix)\(UUID().uuidString).sh"
            )
        let quotedFile = Self.shellQuote(file.path)
        let content = [
            "cleanup() { rm -f -- \(quotedFile); }",
            "trap cleanup EXIT",
            "trap 'exit 129' HUP",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM",
            spec.terminalScript,
            "",
        ].joined(separator: "\n")
        let created = FileManager.default.createFile(
            atPath: file.path,
            contents: Data(content.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            return .failure(.failed("falha ao gravar o script do terminal"))
        }
        let script = Self.appleScript(forTerminalScript: "/bin/sh \(Self.shellQuote(file.path))")
        let result = appleScriptRunner(script)
        if case .failure = result {
            // O `rm` de auto-limpeza é a última linha do próprio script — se o
            // Terminal não abriu, ele nunca roda. Remove aqui para o arquivo
            // temporário não vazar.
            try? FileManager.default.removeItem(at: file)
        }
        return result
    }

    /// Remove resíduos de crashes sem tocar arquivos recentes que outro
    /// disparo concorrente ainda pode estar entregando ao Terminal.
    static func cleanupStaleScripts(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        olderThan minimumAge: TimeInterval = staleScriptAge
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        for file in entries {
            guard file.lastPathComponent.hasPrefix(temporaryScriptPrefix),
                  file.pathExtension == "sh",
                  let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func spec(for message: Message,
                     claudeBinary: URL? = nil,
                     codexBinary: URL? = nil,
                     defaultWorkspace: URL? = nil) -> TerminalLaunchSpec? {
        let provider: Provider
        let binary: URL?
        var args: [String] = []
        switch message.kind {
        case .claude:
            provider = .claude
            binary = claudeBinary ?? CommandRunner.locate(.claude)
            args = ["--model", message.resolvedModel.cliValue,
                    "--effort", message.resolvedEffort.rawValue]
            if message.resolvedSafeMode { args.append("--safe-mode") }
            args.append(message.resolvedPromptText)
        case .codex:
            provider = .codex
            binary = codexBinary ?? CommandRunner.locate(.codex)
            if let model = message.codexModel, !model.isEmpty {
                args += ["--model", model]
            }
            args += ["--sandbox", "read-only"]
            if let reasoning = message.codexReasoning {
                args += ["-c", "model_reasoning_effort=\"\(reasoning.rawValue)\""]
            }
            args.append(message.resolvedPromptText)
        case .shell:
            return nil
        }
        guard let binary else { return nil }

        let workingDir: String
        let usesOhayoManagedWorkspace: Bool
        if let wd = message.workingDir,
           !wd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workingDir = NSString(string: wd).expandingTildeInPath
            usesOhayoManagedWorkspace = false
        } else {
            // Nunca o home: o Claude Code não persiste o trust do home (vale
            // só pela sessão), então abrir lá pediria confirmação toda vez.
            workingDir = (defaultWorkspace ?? defaultWorkspaceDir).path
            usesOhayoManagedWorkspace = true
        }

        let messageConfigDir = (message.configDir?.isEmpty == false)
            ? URL(fileURLWithPath: message.configDir!) : nil
        let account = ProviderAccountContext(
            provider: provider, configDirectory: messageConfigDir
        )
        let envValue = account.configDirectory.path
        // Sem `export PATH`: o Terminal abre um login shell com o PATH do
        // próprio usuário, e o binário é invocado por caminho absoluto —
        // exportar o PATH herdado do app (gigante quando lançado de um shell
        // poluído) truncava o comando.
        let command = ([binary.path] + args).map(shellQuote).joined(separator: " ")
        let accountEnvironment: String
        if provider == .claude, account.isNative {
            // A conta nativa usa ~/.claude.json. Exportar
            // CLAUDE_CONFIG_DIR=~/.claude faria a CLI procurar o login no
            // caminho aninhado errado; o unset também limpa um perfil herdado.
            accountEnvironment = "unset \(provider.envKey)"
        } else {
            accountEnvironment = "export \(provider.envKey)=\(shellQuote(envValue))"
        }
        let terminalScript = [
            accountEnvironment,
            "cd \(shellQuote(workingDir))",
            command
        ].joined(separator: "; ")
        return TerminalLaunchSpec(
            terminalScript: terminalScript,
            accountDir: envValue,
            workingDir: workingDir,
            usesOhayoManagedWorkspace: usesOhayoManagedWorkspace
        )
    }

    /// Pasta neutra do app onde as sessões interativas abrem por padrão.
    static var defaultWorkspaceDir: URL {
        AppPaths.workspaceDirectory()
    }

    /// Pré-confia o workspace controlado pelo Ohayo em
    /// `projects["<pasta>"]` no `.claude.json` da conta. O chamador deve
    /// manter projetos explícitos fora deste helper.
    /// O consentimento mais amplo para imports externos do CLAUDE.md não é
    /// antecipado: quando aplicável, o Claude mantém seu diálogo visível no
    /// Terminal para que a pessoa decida com os arquivos listados.
    ///
    /// Preserva todo o resto do arquivo e não reescreve quando o trust básico
    /// já está aceito.
    static func seedTrust(
        accountDir: String,
        workingDir: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let account = ProviderAccountContext(
            provider: .claude,
            configDirectory: URL(fileURLWithPath: accountDir),
            homeDirectory: homeDirectory
        )
        let url = account.identityFile
        // Canonicaliza a chave: o `claude` grava o trust sob o caminho que o
        // `getcwd` devolve depois do `cd` — símbolos resolvidos (/tmp →
        // /private/tmp), sem barra final nem segmentos `.`/`..`. Semear sob o
        // caminho cru (ex.: /tmp/x) não casaria e a sessão travaria no prompt.
        let workingDir = URL(fileURLWithPath: workingDir).resolvingSymlinksInPath().path
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            // Arquivo existe: só mexemos se soubermos parseá-lo. Um parse que
            // falha (bytes truncados por escrita concorrente do CLI, JSON
            // corrompido) NÃO pode virar root=[:] e ser regravado por cima —
            // isso apagaria oauthAccount, trust de outros projetos e settings.
            // Sem lugar seguro para semear, abortamos: no pior caso o prompt
            // interativo aparece uma vez.
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            root = parsed
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[workingDir] as? [String: Any] ?? [:]
        let trust = entry["hasTrustDialogAccepted"] as? Bool == true
        if trust { return }
        entry["hasTrustDialogAccepted"] = true
        projects[workingDir] = entry
        root["projects"] = projects
        if let data = try? JSONSerialization.data(withJSONObject: root) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func appleScript(forTerminalScript terminalScript: String) -> String {
        """
        tell application "Terminal"
            activate
            do script "\(appleScriptStringLiteral(terminalScript))"
        end tell
        """
    }

    private static func runAppleScript(_ script: String) -> Result<Void, RunnerError> {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.failed("failed to create AppleScript"))
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            return .failure(.failed(error.description))
        }
        return .success(())
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
