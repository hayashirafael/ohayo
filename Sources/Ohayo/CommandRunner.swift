import Foundation

enum RunnerError: Error, Equatable {
    case cliNotFound(Provider)
    case timeout
    case failed(String)

    func userMessage(language: AppLanguage) -> String {
        let strings = L10n(language: language)
        switch self {
        case .cliNotFound(let provider):
            return strings.cliNotFound(provider)
        case .timeout: return strings.commandTimeout
        case .failed(let message): return message
        }
    }
}

protocol CommandRunning {
    func run(
        _ dispatch: PreparedDispatch
    ) async -> Result<String, RunnerError>
}

struct CommandRunner: CommandRunning {
    static let maximumCapturedOutputBytes = 256 * 1024

    /// Override injetável para testes/integrações. Sem ele, cada execução
    /// deriva o limite batch da própria mensagem.
    private let timeoutOverride: TimeInterval?
    var binaryOverride: URL? // testes
    var shellOverride: URL? // testes
    private let processRuntime: any CLIProcessRunning

    init(
        timeout: TimeInterval? = nil,
        binaryOverride: URL? = nil,
        shellOverride: URL? = nil,
        processRuntime: any CLIProcessRunning =
            SystemCLIProcessRuntime()
    ) {
        timeoutOverride = timeout
        self.binaryOverride = binaryOverride
        self.shellOverride = shellOverride
        self.processRuntime = processRuntime
    }

    /// Caminhos comuns de instalação; fallback via shell de login cobre
    /// nvm/asdf e instalações exóticas (importante para open source).
    static func candidatePaths(for provider: Provider) -> [String] {
        switch provider {
        case .claude:
            return ["~/.local/bin/claude", "~/.claude/local/claude",
                    "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]
        }
    }

    static func locate(
        _ provider: Provider,
        isCancelled: () -> Bool = { false }
    ) -> URL? {
        guard !isCancelled() else { return nil }
        let fm = FileManager.default
        for path in candidatePaths(for: provider) {
            guard !isCancelled() else { return nil }
            let expanded = NSString(string: path).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        guard !isCancelled() else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return locateViaShell(
            shell: URL(fileURLWithPath: shell),
            cliName: provider.cliName,
            isCancelled: isCancelled
        )
    }

    /// Fallback: pergunta ao shell de login onde está o binário (cobre nvm/asdf
    /// e instalações exóticas). A interface histórica é síncrona porque também
    /// atende composição e diagnóstico, mas todo lifecycle do subprocesso fica
    /// no runtime comum. A espera curta existe apenas para traduzir cancelamento
    /// cooperativo legado em `Task.cancel()`.
    static func locateViaShell(
        shell: URL,
        cliName: String,
        timeout: TimeInterval = 10,
        isCancelled: () -> Bool = { false }
    ) -> URL? {
        guard !isCancelled() else { return nil }
        let resultBox = BlockingCLIProcessResult()
        let completion = DispatchSemaphore(value: 0)
        let request = CLIProcessRequest(
            executable: shell,
            arguments: ["-l", "-c", "command -v \(cliName)"],
            timeout: timeout,
            stdout: .capture(
                maxBytes: maximumCapturedOutputBytes,
                overflow: .truncateHeadAndTail
            ),
            stderr: .discard
        )
        let worker = Task.detached(priority: .utility) {
            let result = await SystemCLIProcessRuntime().run(request)
            resultBox.store(result)
            completion.signal()
        }

        let bridgeDeadline = Date().addingTimeInterval(max(0, timeout) + 2)
        while completion.wait(timeout: .now() + .milliseconds(25))
                == .timedOut {
            if isCancelled() || Date() >= bridgeDeadline {
                worker.cancel()
                _ = completion.wait(timeout: .now() + 2)
                return nil
            }
        }
        guard !isCancelled(),
              let result = resultBox.value,
              result.termination == .exited(0) else {
            return nil
        }
        // A última linha não vazia: um profile de login ruidoso pode ecoar no
        // stdout antes da saída do `command -v`, e o caminho real vem por último.
        let path = result.stdout.trimmedText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func run(
        _ dispatch: PreparedDispatch
    ) async -> Result<String, RunnerError> {
        let message = dispatch.message
        let executable: URL
        let arguments: [String]
        var providerInput: Data?
        switch dispatch.target {
        case .provider(let plan):
            let provider = plan.account.provider
            guard let binary = binaryOverride ?? Self.locate(provider) else {
                return .failure(.cliNotFound(provider))
            }
            executable = binary
            arguments = plan.batchArguments
            providerInput = plan.standardInput
        case .shell:
            // Comando cru: shell de login para PATH/aliases/pipes/variáveis
            // funcionarem — dá utilidade ao app fora do Claude.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            executable =
                shellOverride ?? URL(fileURLWithPath: shell)
            arguments = ["-l", "-c", message.text]
        }
        let home = NSHomeDirectory()
        // Diretório de trabalho: override da mensagem (se não vazio) senão o home.
        let defaultWorkingDirectory =
            FileManager.default.homeDirectoryForCurrentUser
        let workingDirectory: URL
        switch dispatch.target {
        case .shell(let preparedWorkingDirectory):
            workingDirectory =
                preparedWorkingDirectory ?? defaultWorkingDirectory
        case .provider:
            if let wd = message.workingDir,
               !wd.trimmingCharacters(in: .whitespaces).isEmpty {
                workingDirectory = URL(
                    fileURLWithPath:
                        NSString(string: wd).expandingTildeInPath
                )
            } else {
                workingDirectory = defaultWorkingDirectory
            }
        }

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
        env["PATH"] = [env["PATH"], extraPath].compactMap { $0 }.joined(separator: ":")

        // Terminal interativo é lançado por `TerminalLauncher` e não passa por
        // este executor. Toda chamada direta a `CommandRunner` é batch, mesmo
        // se receber uma mensagem marcada como Terminal; nesse estado
        // inconsistente, usa o timeout persistido ou o default do provider.
        let messageTimeout = message.resolvedTimeoutSeconds
            ?? message.timeoutSeconds
            ?? Message.defaultTimeoutSeconds(for: message.kind)
        let effectiveTimeout = timeoutOverride ?? TimeInterval(messageTimeout)
        let processResult = await processRuntime.run(
            CLIProcessRequest(
                executable: executable,
                arguments: arguments,
                environment: env,
                account: dispatch.account,
                workingDirectory: workingDirectory,
                standardInput: providerInput,
                timeout: effectiveTimeout,
                stdout: .capture(
                    maxBytes: Self.maximumCapturedOutputBytes,
                    overflow: .truncateHeadAndTail
                ),
                stderr: .capture(
                    maxBytes: Self.maximumCapturedOutputBytes,
                    overflow: .truncateHeadAndTail
                )
            )
        )
        switch processResult.termination {
        case .timedOut:
            return .failure(.timeout)
        case .cancelled:
            return .failure(.failed("cancelled"))
        case .outputLimitExceeded:
            return .failure(.failed("output limit exceeded"))
        case .failedToLaunch(let message):
            return .failure(.failed(message))
        case .exited(let status) where status != 0:
            return .failure(.failed(Self.failureLog(
                stdout: processResult.stdout.trimmedText,
                stderr: processResult.stderr.trimmedText,
                terminationStatus: status
            )))
        case .exited:
            return .success(processResult.stdout.trimmedText)
        }
    }

    /// Preserva a saída real da CLI quando ela falha. Claude Code, por
    /// exemplo, escreve "Not logged in" em stdout e deixa stderr vazio.
    static func failureLog(stdout: String, stderr: String,
                           terminationStatus: Int32) -> String {
        switch (stdout.isEmpty, stderr.isEmpty) {
        case (false, true): return stdout
        case (true, false): return stderr
        case (false, false):
            return "stdout:\n\(stdout)\n\nstderr:\n\(stderr)"
        case (true, true):
            return "exit \(terminationStatus)"
        }
    }
}

/// Ponte mínima para os callers síncronos históricos de localização.
/// O lock protege a publicação do resultado produzido pela Task destacada.
private final class BlockingCLIProcessResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: CLIProcessResult?

    var value: CLIProcessResult? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: CLIProcessResult) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
