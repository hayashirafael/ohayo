import Foundation

/// Resolve a conta efetiva de um provedor e centraliza as diferenças entre a
/// conta nativa da CLI e perfis customizados.
///
/// No Claude, a conta nativa usa arquivos divididos entre `~/.claude/` e
/// `~/.claude.json`; exportar `CLAUDE_CONFIG_DIR=~/.claude` muda esse contrato
/// e faz a CLI procurar a identidade em `~/.claude/.claude.json`. Perfis
/// customizados, por outro lado, dependem explicitamente desse override.
struct ProviderAccountContext: Equatable {
    let provider: Provider
    let configDirectory: URL
    let homeDirectory: URL
    let isNative: Bool

    init(provider: Provider, configDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let home = homeDirectory.standardizedFileURL
        let nativeDirectory = Self.canonicalAccountDirectory(
            Self.defaultConfigDirectory(for: provider, homeDirectory: home)
        )
        let directory = Self.canonicalAccountDirectory(
            configDirectory ?? nativeDirectory
        )
        self.provider = provider
        self.configDirectory = directory
        self.homeDirectory = home
        self.isNative = directory == nativeDirectory
    }

    static func defaultConfigDirectory(
        for provider: Provider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.standardizedFileURL.appendingPathComponent(
            provider == .claude ? ".claude" : ".codex"
        ).standardizedFileURL
    }

    /// Identidade canônica de uma conta existente. Resolve symlinks para que
    /// aliases da mesma pasta não criem schedulers, filas ou consentimentos
    /// independentes. Caminhos ausentes permanecem estáveis para diagnóstico.
    static func canonicalAccountDirectory(_ directory: URL) -> URL {
        let standardized = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardized.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return standardized
        }
        let resolved = standardized.resolvingSymlinksInPath()
        return URL(
            fileURLWithPath: resolved.path,
            isDirectory: true
        ).standardizedFileURL
    }

    /// Aplica somente o override necessário à conta.
    ///
    /// A conta Claude nativa precisa da variável ausente; removê-la também
    /// evita herdar por engano um perfil customizado do processo que abriu o
    /// Ohayo. Codex sempre recebe `CODEX_HOME`, inclusive no default, para que
    /// a conta observada pelo app seja determinística.
    func applyingAccountEnvironment(to base: [String: String]) -> [String: String] {
        var environment = base
        if provider == .claude, isNative {
            environment.removeValue(forKey: provider.envKey)
        } else {
            environment[provider.envKey] = configDirectory.path
        }
        return environment
    }

    var identityFile: URL {
        switch provider {
        case .claude:
            return isNative
                ? homeDirectory.appendingPathComponent(".claude.json")
                : configDirectory.appendingPathComponent(".claude.json")
        case .codex:
            return configDirectory.appendingPathComponent("auth.json")
        }
    }
}
