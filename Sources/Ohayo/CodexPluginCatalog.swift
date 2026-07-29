import Darwin
import Foundation

/// Snapshot por conta da última consulta ao inventário do Codex CLI.
/// Falha/timeout limpa plugins stale, mas difere de um JSON válido (inclusive
/// vazio), que é a autoridade para declarar uma skill ausente.
struct CodexPluginInventoryCache {
    enum QueryState: Equatable {
        case notQueried
        case unavailable
        case loaded(Data)

        var inventory: Data? {
            guard case .loaded(let inventory) = self else {
                return nil
            }
            return inventory
        }

        var preservesPersistedSelection: Bool {
            switch self {
            case .notQueried, .unavailable:
                return true
            case .loaded:
                return false
            }
        }
    }

    private var states: [String: QueryState] = [:]

    func queryState(for accountKey: String) -> QueryState {
        states[accountKey] ?? .notQueried
    }

    mutating func replaceQueryResult(
        _ inventory: Data?,
        for accountKey: String
    ) {
        states[accountKey] = inventory.map(QueryState.loaded)
            ?? .unavailable
    }
}

/// Resolve somente plugins que o próprio Codex declara instalados e
/// habilitados. O cache não é autoridade: ele também contém versões antigas,
/// plugins desativados e entradas remotas ainda não instaladas.
enum CodexPluginCatalog {
    private struct Inventory: Decodable {
        let installed: [InventoryPlugin]
    }

    private struct InventoryPlugin: Decodable {
        let name: String
        let installed: Bool
        let enabled: Bool
        let source: PluginSource
    }

    private struct PluginSource: Decodable {
        let source: String
        let path: String?
    }

    private struct Manifest: Decodable {
        let name: String
        let skills: String?
    }

    static func isValidInventory(_ inventoryData: Data) -> Bool {
        (try? JSONDecoder().decode(
            Inventory.self,
            from: inventoryData
        )) != nil
    }

    static func enabledSkillNames(from inventoryData: Data) -> [String] {
        guard let inventory = try? JSONDecoder().decode(
            Inventory.self,
            from: inventoryData
        ) else {
            return []
        }
        var names: Set<String> = []
        for plugin in inventory.installed
            where plugin.installed
                && plugin.enabled
                && plugin.source.source == "local" {
            names.formUnion(skillNames(for: plugin))
        }
        return names.sorted()
    }

    private static func skillNames(
        for plugin: InventoryPlugin
    ) -> [String] {
        guard isSafeName(plugin.name),
              let sourcePath = plugin.source.path,
              NSString(string: sourcePath).isAbsolutePath else {
            return []
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: sourcePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return []
        }
        let manifestURL = root
            .appendingPathComponent(".codex-plugin/plugin.json")
            .resolvingSymlinksInPath()
        guard isContained(manifestURL, in: root) else { return [] }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                  Manifest.self,
                  from: data
              ),
              manifest.name == plugin.name,
              let relativeSkills = manifest.skills,
              !relativeSkills.isEmpty,
              !NSString(string: relativeSkills).isAbsolutePath else {
            return []
        }
        let skillsRoot = root
            .appendingPathComponent(relativeSkills)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isContained(skillsRoot, in: root),
              fm.fileExists(
                  atPath: skillsRoot.path,
                  isDirectory: &isDirectory
              ),
              isDirectory.boolValue,
              let entries = try? fm.contentsOfDirectory(
                  at: skillsRoot,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return entries.compactMap { entry in
            guard isSafeName(entry.lastPathComponent) else {
                return nil
            }
            let canonical = entry.resolvingSymlinksInPath()
            guard isContained(canonical, in: skillsRoot),
                  (try? canonical.resourceValues(
                      forKeys: [.isDirectoryKey]
                  ).isDirectory) == true else {
                return nil
            }
            let skillFile = canonical
                .appendingPathComponent("SKILL.md")
                .resolvingSymlinksInPath()
            guard isContained(skillFile, in: canonical),
                  fm.fileExists(atPath: skillFile.path) else {
                return nil
            }
            return "\(manifest.name):\(entry.lastPathComponent)"
        }
    }

    private static func isContained(_ child: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == rootPath
            || childPath.hasPrefix(rootPath + "/")
    }

    private static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("/")
            && !value.contains(":")
            && !value.contains(where: \.isWhitespace)
    }
}

/// Consulta read-only do inventário resolvido pelo mesmo Codex CLI usado no
/// dispatch. Falha/timeout omite apenas plugins; skills pessoais e do projeto
/// continuam disponíveis.
enum CodexPluginInventoryLoader {
    typealias BinaryLocator = (_ isCancelled: () -> Bool) -> URL?

    private static let timeout: TimeInterval = 3
    private static let maximumBytes = 1_000_000

    static func load(
        configDirectory: URL,
        binaryLocator: BinaryLocator = {
            CommandRunner.locate(.codex, isCancelled: $0)
        }
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        // Não peça ao CLI para inicializar uma conta que está offline ou
        // ainda não existe só para preencher o picker.
        guard fm.fileExists(
            atPath: configDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        guard !Task.isCancelled,
              let binary = binaryLocator({ Task.isCancelled }),
              !Task.isCancelled else {
            return nil
        }
        let context = ProviderAccountContext(
            provider: .codex,
            configDirectory: configDirectory
        )
        let result = await SystemCLIProcessRuntime().run(
            CLIProcessRequest(
                executable: binary,
                arguments: ["plugin", "list", "--json"],
                account: context,
                timeout: timeout,
                stdout: .capture(
                    maxBytes: maximumBytes,
                    overflow: .fail
                ),
                stderr: .discard
            )
        )
        guard case .exited(0) = result.termination,
              !result.stdout.wasTruncated,
              CodexPluginCatalog.isValidInventory(
                  result.stdout.data
              ) else {
            return nil
        }
        return result.stdout.data
    }
}
