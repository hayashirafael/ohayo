import Foundation

enum AuthenticationStatus: Equatable {
    case authenticated
    case unauthenticated(log: String)
    case unknown
}

protocol AuthenticationChecking {
    func status(for provider: Provider, configDir: URL) async -> AuthenticationStatus
}

/// Consulta o estado de login pela própria CLI, sem ler tokens ou arquivos
/// internos. Estados que a versão instalada não souber reportar são tratados
/// como desconhecidos para não bloquear uma conta válida.
struct CLIAuthenticationChecker: AuthenticationChecking {
    var timeout: TimeInterval = 10
    var binaryLocator: (Provider) -> URL? = { CommandRunner.locate($0) }

    func status(for provider: Provider, configDir: URL) async -> AuthenticationStatus {
        guard let binary = binaryLocator(provider) else { return .unknown }
        let args: [String]
        switch provider {
        case .claude: args = ["auth", "status", "--json"]
        case .codex: args = ["login", "status"]
        }

        guard let result = await run(binary: binary, args: args,
                                     provider: provider, configDir: configDir)
        else { return .unknown }

        let log = CommandRunner.failureLog(
            stdout: result.stdout, stderr: result.stderr,
            terminationStatus: result.status)

        switch provider {
        case .claude:
            guard let data = result.stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool
            else { return .unknown }
            return loggedIn ? .authenticated : .unauthenticated(log: log)
        case .codex:
            if result.status == 0 { return .authenticated }
            return log.localizedCaseInsensitiveContains("not logged in")
                ? .unauthenticated(log: log) : .unknown
        }
    }

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(binary: URL, args: [String], provider: Provider,
                     configDir: URL) async -> Result? {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let account = ProviderAccountContext(provider: provider, configDirectory: configDir)
        process.environment = account.applyingAccountEnvironment(
            to: ProcessInfo.processInfo.environment
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = PipeBuffer()
        let stderr = PipeBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        do { try process.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < graceDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let tail = try? stdoutPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
            stdout.append(tail)
        }
        if let tail = try? stderrPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
            stderr.append(tail)
        }
        return Result(status: process.terminationStatus,
                      stdout: stdout.trimmedString(), stderr: stderr.trimmedString())
    }
}
