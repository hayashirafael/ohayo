import Foundation

enum AuthenticationStatus: Equatable {
    case authenticated
    case unauthenticated(log: String)
    case unknown
}

protocol AuthenticationChecking {
    func status(
        for account: ProviderAccountContext
    ) async -> AuthenticationStatus
}

/// Consulta o estado de login pela própria CLI, sem ler tokens ou arquivos
/// internos. Estados que a versão instalada não souber reportar são tratados
/// como desconhecidos para não bloquear uma conta válida.
struct CLIAuthenticationChecker: AuthenticationChecking {
    var timeout: TimeInterval = 10
    var binaryLocator: (Provider) -> URL? = { CommandRunner.locate($0) }
    var processRuntime: any CLIProcessRunning =
        SystemCLIProcessRuntime()

    func status(
        for account: ProviderAccountContext
    ) async -> AuthenticationStatus {
        let provider = account.provider
        guard let binary = binaryLocator(provider) else { return .unknown }
        let args: [String]
        switch provider {
        case .claude: args = ["auth", "status", "--json"]
        case .codex: args = ["login", "status"]
        }

        let result = await processRuntime.run(CLIProcessRequest(
            executable: binary,
            arguments: args,
            account: account,
            timeout: timeout
        ))
        guard case .exited(let status) = result.termination else {
            return .unknown
        }

        let log = CommandRunner.failureLog(
            stdout: result.stdout.trimmedText,
            stderr: result.stderr.trimmedText,
            terminationStatus: status)

        switch provider {
        case .claude:
            guard let data = result.stdout.text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool
            else { return .unknown }
            return loggedIn ? .authenticated : .unauthenticated(log: log)
        case .codex:
            if status == 0 { return .authenticated }
            return log.localizedCaseInsensitiveContains("not logged in")
                ? .unauthenticated(log: log) : .unknown
        }
    }

}
