import Darwin
import Foundation

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
    private static let timeout: TimeInterval = 3
    private static let maximumBytes = 1_000_000

    static func load(configDirectory: URL) async -> Data? {
        let cancellation = CancellationState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: loadSynchronously(
                            configDirectory: configDirectory,
                            cancellation: cancellation
                        )
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func loadSynchronously(
        configDirectory: URL,
        cancellation: CancellationState
    ) -> Data? {
        guard !cancellation.isCancelled else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        // Não peça ao CLI para inicializar uma conta que está offline ou
        // ainda não existe só para preencher o picker.
        guard fm.fileExists(
            atPath: configDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
        let binary = CommandRunner.locate(
            .codex,
            isCancelled: { cancellation.isCancelled }
        ) else {
            return nil
        }
        guard !cancellation.isCancelled else { return nil }
        let outputURL = fm.temporaryDirectory.appendingPathComponent(
            "ohayo-codex-plugins-\(UUID().uuidString).json"
        )
        guard fm.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let output = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer {
            try? output.close()
            try? fm.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["plugin", "list", "--json"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let context = ProviderAccountContext(
            provider: .codex,
            configDirectory: configDirectory
        )
        process.environment = context.applyingAccountEnvironment(
            to: ProcessInfo.processInfo.environment
        )
        guard cancellation.register(process) else { return nil }
        defer { cancellation.clear(process) }
        guard (try? process.run()) != nil else { return nil }
        if cancellation.isCancelled {
            process.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var exceededMaximumBytes = false
        while process.isRunning
            && Date() < deadline
            && !cancellation.isCancelled {
            if let attributes = try? fm.attributesOfItem(
                atPath: outputURL.path
            ), let size = attributes[.size] as? NSNumber,
               size.intValue > maximumBytes {
                exceededMaximumBytes = true
                break
            }
            usleep(50_000)
        }
        if process.isRunning && (
            Date() >= deadline
                || exceededMaximumBytes
                || cancellation.isCancelled
        ) {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                usleep(50_000)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        try? output.synchronize()
        try? output.close()
        guard !cancellation.isCancelled,
              !exceededMaximumBytes,
              process.terminationStatus == 0,
              let attributes = try? fm.attributesOfItem(
                  atPath: outputURL.path
              ),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: outputURL),
              CodexPluginCatalog.isValidInventory(data) else {
            return nil
        }
        return data
    }

    /// Faz o cancelamento da Task chegar ao `Process` bloqueante executado na
    /// fila utilitária. O lock cobre somente a referência/flag; sinais nunca
    /// são enviados enquanto ele está retido.
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func register(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        func clear(_ process: Process) {
            lock.lock()
            defer { lock.unlock() }
            if self.process === process {
                self.process = nil
            }
        }

        func cancel() {
            let running: Process?
            lock.lock()
            cancelled = true
            running = process
            lock.unlock()
            if running?.isRunning == true {
                running?.terminate()
            }
        }
    }
}
