import Foundation

/// Referência a uma skill instalada na conta — o nome é o identificador de
/// invocação no CLI (ex.: "gmud", "superpowers:brainstorming").
struct SkillRef: Equatable, Hashable, Identifiable {
    let name: String
    var id: String { name }
}

/// Varredura pura das skills instaladas em uma conta. Sem cache nem estado:
/// o form consulta ao abrir / trocar conta / trocar tipo — é enumeração local
/// de diretórios pequenos.
enum SkillCatalog {
    /// Skills da conta, ordenadas alfabeticamente e deduplicadas.
    /// Claude: `<dir>/skills/` (pessoais) + `<dir>/plugins/cache/` (plugins,
    /// nome `plugin:skill`). Codex também inclui `$HOME/.agents/skills`,
    /// diretório global recomendado pelo CLI atual.
    static func skills(
        for provider: Provider,
        at configDir: URL,
        workingDir: URL? = nil,
        homeDir: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexPluginInventory: Data? = nil
    ) -> [SkillRef] {
        var names = Set(personalSkills(in: configDir.appendingPathComponent("skills")))
        if provider == .claude {
            names.formUnion(pluginSkills(in: configDir.appendingPathComponent("plugins/cache")))
            if let workingDir {
                for directory in projectDirectories(from: workingDir) {
                    names.formUnion(personalSkills(
                        in: directory.appendingPathComponent(".claude/skills")))
                }
            }
        } else {
            names.formUnion(personalSkills(
                in: homeDir.appendingPathComponent(".agents/skills")))
            if let codexPluginInventory {
                names.formUnion(
                    CodexPluginCatalog.enabledSkillNames(
                        from: codexPluginInventory
                    )
                )
            }
            if let workingDir {
                for directory in projectDirectories(from: workingDir) {
                    names.formUnion(personalSkills(
                        in: directory.appendingPathComponent(".agents/skills")))
                }
            }
        }
        return names.sorted().map(SkillRef.init)
    }

    /// Diretório de trabalho e seus ancestrais até a raiz Git inclusiva. Fora
    /// de um repositório, só o diretório informado participa da descoberta.
    private static func projectDirectories(from workingDir: URL) -> [URL] {
        let workingDir = workingDir.standardizedFileURL
        guard let root = repositoryRoot(containing: workingDir) else {
            return [workingDir]
        }
        var result: [URL] = []
        var current = workingDir
        while true {
            result.append(current)
            if current.path == root.path { return result }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return result }
            current = parent
        }
    }

    private static func repositoryRoot(containing workingDir: URL) -> URL? {
        var current = workingDir.standardizedFileURL
        while true {
            if FileManager.default.fileExists(
                atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            // `deletingLastPathComponent()` deve estabilizar em `/`, mas a
            // parada estrutural evita qualquer URL malformada/cíclica crescer
            // indefinidamente enquanto procuramos um marcador que não existe.
            guard current.pathComponents.count > 1 else { return nil }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.pathComponents.count < current.pathComponents.count else {
                return nil
            }
            current = parent
        }
    }

    /// Pastas `<dir>/<nome>/SKILL.md`; ocultas (ex.: `.system`) ficam de fora.
    private static func personalSkills(in dir: URL) -> [String] {
        subdirectories(of: dir).filter(hasSkillFile).map(\.lastPathComponent)
    }

    /// `<cache>/<marketplace>/<plugin>/<versão>/skills/<nome>/SKILL.md` →
    /// `plugin:nome`. Versões múltiplas do mesmo plugin deduplicam no Set do
    /// chamador.
    private static func pluginSkills(in cacheDir: URL) -> [String] {
        subdirectories(of: cacheDir).flatMap { marketplace in
            subdirectories(of: marketplace).flatMap { plugin in
                subdirectories(of: plugin).flatMap { version in
                    subdirectories(of: version.appendingPathComponent("skills"))
                        .filter(hasSkillFile)
                        .map { "\(plugin.lastPathComponent):\($0.lastPathComponent)" }
                }
            }
        }
    }

    private static func subdirectories(of dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter {
            let target = $0.resolvingSymlinksInPath()
            return (try? target.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true
        }
    }

    private static func hasSkillFile(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path)
    }
}
