import Foundation

enum AgendamentoOutputMode: Equatable {
    case none
    case terminal
    case response
}

/// Estado editável de um Agendamento. A identidade e o snapshot-base nascem
/// juntos, evitando reconstruir uma edição a partir de dezenas de estados
/// independentes ou ressuscitar uma task removida enquanto o sheet estava
/// aberto.
struct AgendamentoDraft: Equatable {
    let uid: UUID
    let base: ScheduledTask?

    var name = ""
    var text = ""
    var kind: Message.Kind = .claude
    var model = Message.defaultModel
    var effort = Message.defaultEffort
    var safeMode = Message.defaultSafeMode
    var codexModel = ""
    var codexReasoning: Message.CodexReasoning?
    var codexAllowFullAccess = true
    var outputMode: AgendamentoOutputMode = .terminal
    var responseFormat: ResponseFileFormat = .markdown
    var responseDirectory: String
    var favoriteResponseDirectory = false
    var timeoutSeconds: Int?
    var notifyOnSuccess = false
    var account: String?
    var skill: String?
    var workingDir = ""
    var repetition: ScheduledTask.Repetition = .fixed
    var times: [Int] = [9 * 60]
    var weekdays: Set<Int> = Set(1...7)
    var bootstrapWhenInactive = false
    var enabled = true

    init(
        editing task: ScheduledTask?,
        defaultResponseDirectory: URL = AppPaths.responsesDirectory(),
        newID: @autoclosure () -> UUID = UUID()
    ) {
        uid = task?.uid ?? newID()
        base = task
        responseDirectory = defaultResponseDirectory.standardizedFileURL.path
        guard let task else { return }

        name = task.name ?? ""
        repetition = task.repetition
        times = AgendaMath.normalized(
            task.times.isEmpty ? [9 * 60] : task.times
        )
        weekdays = task.weekdays.isEmpty ? Set(1...7) : task.weekdays
        bootstrapWhenInactive = task.resolvedBootstrapWhenInactive
        enabled = task.enabled

        let message = task.resolvedCommand
        text = message.text
        kind = message.kind
        model = message.resolvedModel
        effort = message.resolvedEffort
        safeMode = message.resolvedSafeMode
        codexModel = message.codexModel ?? ""
        codexReasoning = message.codexReasoning
        codexAllowFullAccess = message.resolvedCodexAllowFullAccess
        outputMode = Self.outputMode(for: message)
        responseFormat = message.resolvedResponseFileFormat
        responseDirectory = message.responseDirectory
            ?? defaultResponseDirectory.standardizedFileURL.path
        timeoutSeconds = message.timeoutSeconds
        notifyOnSuccess = Self.effectiveNotifyOnSuccess(
            message.resolvedNotifyOnSuccess,
            outputMode: outputMode
        )
        account = Self.canonicalAccountPath(message.configDir)
        skill = message.skill
        workingDir = message.workingDir ?? ""
    }

    static func outputMode(for message: Message) -> AgendamentoOutputMode {
        if message.kind != .shell && message.resolvedRunInTerminal {
            return .terminal
        }
        if message.resolvedShowResponse { return .response }
        return .none
    }

    static func showsTimeout(for outputMode: AgendamentoOutputMode) -> Bool {
        outputMode != .terminal
    }

    static func supportsResponseFile(
        kind: Message.Kind,
        outputMode: AgendamentoOutputMode
    ) -> Bool {
        kind != .shell && outputMode == .response
    }

    static func effectiveNotifyOnSuccess(
        _ requested: Bool,
        outputMode: AgendamentoOutputMode
    ) -> Bool {
        requested && outputMode != .terminal
    }

    static func canonicalAccountPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return ProviderAccountContext.canonicalAccountDirectory(
            URL(fileURLWithPath: path)
        ).path
    }

    mutating func changeKind(to newKind: Message.Kind) {
        guard kind != newKind else { return }
        kind = newKind
        account = nil
        skill = nil
        if newKind == .shell {
            if outputMode == .terminal { outputMode = .none }
            if repetition == .continuous { repetition = .fixed }
        }
    }

    mutating func selectSkill(_ newSkill: String?) {
        skill = newSkill
        if newSkill?.isEmpty == false {
            safeMode = false
        }
    }

    func normalizedTask() -> ScheduledTask {
        let trimmedText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let effectiveAccount =
            kind == .shell ? nil : Self.canonicalAccountPath(account)
        let trimmedModel = codexModel.trimmingCharacters(
            in: .whitespaces
        )
        let trimmedResponseDirectory = responseDirectory.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let savesResponseFile = Self.supportsResponseFile(
            kind: kind,
            outputMode: outputMode
        )
        let command = Message(
            text: trimmedText,
            kind: kind,
            model: kind == .claude && model != Message.defaultModel
                ? model : nil,
            effort: kind == .claude && effort != Message.defaultEffort
                ? effort : nil,
            safeMode: kind == .claude
                && safeMode != Message.defaultSafeMode
                ? safeMode : nil,
            configDir: effectiveAccount,
            workingDir: kind != .shell && !workingDir.isEmpty
                ? workingDir : nil,
            showResponse: outputMode == .response ? true : nil,
            runInTerminal: kind != .shell && outputMode != .terminal
                ? false : nil,
            timeoutSeconds: Message.normalizedTimeoutSeconds(
                timeoutSeconds,
                for: kind
            ),
            notifyOnSuccess: Self.effectiveNotifyOnSuccess(
                notifyOnSuccess,
                outputMode: outputMode
            ) ? true : nil,
            codexModel: kind == .codex && !trimmedModel.isEmpty
                ? trimmedModel : nil,
            codexReasoning: kind == .codex ? codexReasoning : nil,
            codexAllowFullAccess: kind == .codex && !codexAllowFullAccess
                ? false : nil,
            responseFileFormat: savesResponseFile
                ? responseFormat : nil,
            responseDirectory: savesResponseFile
                && !trimmedResponseDirectory.isEmpty
                ? trimmedResponseDirectory : nil,
            skill: kind != .shell && skill?.isEmpty == false ? skill : nil
        )
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var task = ScheduledTask(
            uid: uid,
            name: trimmedName.isEmpty ? nil : trimmedName,
            command: command,
            repetition: repetition,
            times: repetition == .fixed
                ? AgendaMath.normalized(times) : [],
            weekdays: repetition == .fixed
                ? weekdays.filter { (1...7).contains($0) } : [],
            bootstrapWhenInactive: repetition == .continuous
                ? bootstrapWhenInactive : nil
        )
        task.enabled = enabled
        return task
    }
}

enum AgendamentoIssue: Equatable {
    case emptyMessage
    case missingTime
    case missingWeekday
    case continuousShell
    case continuousConflict(existing: UUID)
    case accountUnavailable(URL)
}

struct AgendamentoEvaluation: Equatable {
    let normalized: ScheduledTask
    let issues: [AgendamentoIssue]

    var canSave: Bool { issues.isEmpty }
}

/// Snapshot consumido pelo formulário. Todos os campos visuais derivam da
/// mesma avaliação, evitando repetir I/O e varreduras do AppState no `body`.
struct AgendamentoFormSnapshot: Equatable {
    let evaluation: AgendamentoEvaluation

    var canSave: Bool { evaluation.canSave }
    var firstIssue: AgendamentoIssue? { evaluation.issues.first }
    var hasContinuousConflict: Bool {
        evaluation.issues.contains {
            if case .continuousConflict = $0 { return true }
            return false
        }
    }
    var hasAccountUnavailableIssue: Bool {
        evaluation.issues.contains {
            if case .accountUnavailable = $0 { return true }
            return false
        }
    }
}

enum AgendamentoChange: Equatable {
    case save(AgendamentoDraft)
    case setEnabled(id: UUID, enabled: Bool)
    case delete(id: UUID)
    case disableAccount(URL)
}

enum AgendamentoChangeReceipt: Equatable {
    case saved(ScheduledTask)
    case enabled(UUID, Bool)
    case deleted(UUID)
    case disabledAccount(URL, [UUID])
}

enum AgendamentoEditError: Error, Equatable {
    case invalid([AgendamentoIssue])
    case notFound(UUID)
    case stale(UUID)
}

/// Única seam de mutação dos Agendamentos usada pelas views. Avaliação e
/// commit compartilham a mesma regra, mas `apply` reavalia contra o AppState
/// atual para fechar a corrida entre preview e clique em Salvar.
@MainActor
final class AgendamentoEditor {
    typealias IsDirectory = (URL) -> Bool

    private let state: AppState
    private let isDirectory: IsDirectory

    init(
        state: AppState,
        isDirectory: @escaping IsDirectory = { directory in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    ) {
        self.state = state
        self.isDirectory = isDirectory
    }

    func formSnapshot(
        for draft: AgendamentoDraft
    ) -> AgendamentoFormSnapshot {
        AgendamentoFormSnapshot(evaluation: evaluate(draft))
    }

    func evaluate(_ draft: AgendamentoDraft) -> AgendamentoEvaluation {
        let normalized = draft.normalizedTask()
        var issues: [AgendamentoIssue] = []

        if normalized.resolvedCommand.text.isEmpty {
            issues.append(.emptyMessage)
        }
        switch normalized.repetition {
        case .fixed:
            if normalized.times.isEmpty {
                issues.append(.missingTime)
            }
            if normalized.weekdays.isEmpty {
                issues.append(.missingWeekday)
            }
        case .continuous:
            if normalized.resolvedCommand.kind == .shell {
                issues.append(.continuousShell)
            }
        }

        if let path = normalized.resolvedCommand.configDir,
           !path.isEmpty {
            let directory =
                ProviderAccountContext.canonicalAccountDirectory(
                    URL(fileURLWithPath: path)
                )
            if !isDirectory(directory) {
                issues.append(.accountUnavailable(directory))
            }
        }

        if normalized.enabled,
           normalized.repetition == .continuous,
           let account = state.intendedAccountDir(for: normalized),
           let existing = state.tasks.first(where: {
               $0.uid != normalized.uid
                   && $0.enabled
                   && $0.repetition == .continuous
                   && state.intendedAccountDir(for: $0) == account
           }) {
            issues.append(.continuousConflict(existing: existing.uid))
        }

        return AgendamentoEvaluation(
            normalized: normalized,
            issues: issues
        )
    }

    @discardableResult
    func apply(
        _ change: AgendamentoChange
    ) -> Result<AgendamentoChangeReceipt, AgendamentoEditError> {
        switch change {
        case .save(let draft):
            let evaluation = evaluate(draft)
            guard evaluation.canSave else {
                return .failure(.invalid(evaluation.issues))
            }
            var updated = state.tasks
            if let base = draft.base {
                guard let index = updated.firstIndex(
                    where: { $0.uid == draft.uid }
                ) else {
                    return .failure(.notFound(draft.uid))
                }
                guard updated[index] == base else {
                    return .failure(.stale(draft.uid))
                }
                updated[index] = evaluation.normalized
            } else {
                guard !updated.contains(
                    where: { $0.uid == draft.uid }
                ) else {
                    return .failure(.stale(draft.uid))
                }
                updated.append(evaluation.normalized)
            }
            state.tasks = updated
            return .success(.saved(evaluation.normalized))

        case .setEnabled(let id, let enabled):
            guard let index = state.tasks.firstIndex(
                where: { $0.uid == id }
            ) else {
                return .failure(.notFound(id))
            }
            if state.tasks[index].enabled == enabled {
                return .success(.enabled(id, enabled))
            }
            var updated = state.tasks
            updated[index].enabled = enabled
            if enabled,
               updated[index].repetition == .continuous,
               let account = state.intendedAccountDir(
                   for: updated[index]
               ),
               let existing = updated.first(where: {
                   $0.uid != id
                       && $0.enabled
                       && $0.repetition == .continuous
                       && state.intendedAccountDir(for: $0) == account
               }) {
                return .failure(.invalid([
                    .continuousConflict(existing: existing.uid),
                ]))
            }
            state.tasks = updated
            return .success(.enabled(id, enabled))

        case .delete(let id):
            guard state.tasks.contains(where: { $0.uid == id }) else {
                return .failure(.notFound(id))
            }
            state.tasks = state.tasks.filter { $0.uid != id }
            return .success(.deleted(id))

        case .disableAccount(let directory):
            let canonical =
                ProviderAccountContext.canonicalAccountDirectory(
                    directory
                )
            var updated = state.tasks
            var disabled: [UUID] = []
            for index in updated.indices
                where updated[index].enabled {
                guard let path =
                        updated[index].resolvedCommand.configDir,
                      ProviderAccountContext
                        .canonicalAccountDirectory(
                            URL(fileURLWithPath: path)
                        ) == canonical else {
                    continue
                }
                updated[index].enabled = false
                disabled.append(updated[index].uid)
            }
            if !disabled.isEmpty {
                state.tasks = updated
            }
            return .success(.disabledAccount(canonical, disabled))
        }
    }
}
