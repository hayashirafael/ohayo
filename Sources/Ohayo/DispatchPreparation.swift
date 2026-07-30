import Foundation

/// Intenção de disparo na linguagem do caller. O FireController recebe a
/// tarefa inteira para que origem, identidade e Account sejam resolvidas em
/// conjunto, sem guards paralelos no AppEnvironment.
enum DispatchIntent {
    case agenda(ScheduledTask)
    case renewal(ScheduledTask)
    case manual(ScheduledTask)
    case direct(Message, origin: FireOrigin, taskName: String? = nil)

    var payload: (
        message: Message,
        origin: FireOrigin,
        taskID: UUID?,
        taskName: String?,
        continuous: Bool
    ) {
        switch self {
        case .agenda(let task):
            return (
                task.resolvedCommand,
                .agenda,
                task.uid,
                task.name,
                task.repetition == .continuous
            )
        case .renewal(let task):
            return (
                task.resolvedCommand,
                .renewal,
                task.uid,
                task.name,
                task.repetition == .continuous
            )
        case .manual(let task):
            return (
                task.resolvedCommand,
                .manual,
                task.uid,
                task.name,
                task.repetition == .continuous
            )
        case .direct(let message, let origin, let taskName):
            return (message, origin, nil, taskName, false)
        }
    }
}

enum DispatchTarget: Equatable {
    case provider(ProviderDispatchPlan)
    case shell(workingDirectory: URL?)
}

struct ProviderDispatchPlan: Equatable {
    let account: ProviderAccountContext
    let batchArguments: [String]
    let terminalArguments: [String]
    let standardInput: Data

    init(message: Message, account: ProviderAccountContext) {
        self.account = account
        switch account.provider {
        case .claude:
            var common = [
                "--model", message.resolvedModel.cliValue,
                "--effort", message.resolvedEffort.rawValue,
            ]
            if message.resolvedSafeMode {
                common.append("--safe-mode")
            }
            batchArguments = ["-p"] + common
            terminalArguments = common + [message.resolvedPromptText]
        case .codex:
            var modelArguments: [String] = []
            if let model = message.codexModel, !model.isEmpty {
                modelArguments = ["--model", model]
            }
            var reasoningArguments: [String] = []
            if let reasoning = message.codexReasoning {
                reasoningArguments = [
                    "-c",
                    "model_reasoning_effort=\"\(reasoning.rawValue)\"",
                ]
            }
            let sandbox = message.resolvedTrustWorkingDirectory
                ? "workspace-write"
                : "read-only"
            batchArguments = ["exec"]
                + modelArguments
                + [
                    "--sandbox", sandbox,
                    "--skip-git-repo-check",
                    "--color", "never",
                ]
                + reasoningArguments
            terminalArguments = modelArguments
                + ["--sandbox", sandbox]
                + reasoningArguments
                + [message.resolvedPromptText]
        }
        standardInput = Data(message.resolvedPromptText.utf8)
    }
}

/// Descrição imutável compartilhada por quota, autenticação, Batch e Terminal.
/// A Account é canonicalizada uma única vez e nunca é reinferida por adapters.
struct PreparedDispatch: Equatable {
    let message: Message
    let origin: FireOrigin
    let taskID: UUID?
    let taskName: String?
    let target: DispatchTarget

    var account: ProviderAccountContext? {
        guard case .provider(let plan) = target else { return nil }
        return plan.account
    }

    var provider: Provider? { account?.provider }

    var accountDirectory: URL? { account?.configDirectory }
}

enum DispatchPreparationError: Error, Equatable {
    case explicitAccountMissing(provider: Provider, path: URL)
    case continuousShell
}

struct DispatchPreparer {
    private let homeDirectory: URL
    private let isDirectory: (URL) -> Bool

    init(
        homeDirectory: URL =
            FileManager.default.homeDirectoryForCurrentUser,
        isDirectory: @escaping (URL) -> Bool = { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &directory
            ) && directory.boolValue
        }
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.isDirectory = isDirectory
    }

    func prepare(
        _ intent: DispatchIntent
    ) -> Result<PreparedDispatch, DispatchPreparationError> {
        let payload = intent.payload
        let message = payload.message

        guard message.kind != .shell else {
            // Estados legados/corrompidos ainda podem conter shell contínuo.
            // Agenda e renewal falham fechado, mas "Executar agora" é uma
            // ação explícita e preserva a semântica manual já prometida pela UI.
            guard !payload.continuous || payload.origin == .manual else {
                return .failure(.continuousShell)
            }
            return .success(PreparedDispatch(
                message: message,
                origin: payload.origin,
                taskID: payload.taskID,
                taskName: payload.taskName,
                target: .shell(
                    workingDirectory: Self.workingDirectory(
                        from: message.workingDir
                    )
                )
            ))
        }

        let provider: Provider =
            message.kind == .codex ? .codex : .claude
        let selectedDirectory: URL?
        if let path = message.configDir,
           !path.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            let directory = URL(
                fileURLWithPath: expanded,
                isDirectory: true
            ).standardizedFileURL
            guard isDirectory(directory) else {
                return .failure(.explicitAccountMissing(
                    provider: provider,
                    path: directory
                ))
            }
            selectedDirectory = directory
        } else {
            selectedDirectory = nil
        }

        let account = ProviderAccountContext(
            provider: provider,
            configDirectory: selectedDirectory,
            homeDirectory: homeDirectory
        )
        return .success(PreparedDispatch(
            message: message,
            origin: payload.origin,
            taskID: payload.taskID,
            taskName: payload.taskName,
            target: .provider(ProviderDispatchPlan(
                message: message,
                account: account
            ))
        ))
    }

    private static func workingDirectory(from path: String?) -> URL? {
        guard let path,
              !path.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return nil
        }
        return URL(
            fileURLWithPath:
                NSString(string: path).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }
}
