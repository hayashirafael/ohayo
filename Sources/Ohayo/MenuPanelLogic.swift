import Foundation

/// Lógica pura do painel do menu — testável sem UI. As dependências de
/// AppState entram como closures/dicionários para os testes não tocarem disco.
enum MenuPanelLogic {
    /// Contas com pelo menos um agendamento habilitado, sem duplicatas,
    /// ordenadas pelo rótulo (mesma regra do menu antigo).
    static func scheduledAccounts(tasks: [ScheduledTask],
                                  accountDir: (ScheduledTask) -> URL?,
                                  label: (URL) -> String) -> [URL] {
        let dirs = Set(tasks.filter { $0.enabled }.compactMap { accountDir($0) })
        return dirs.sorted {
            label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending
        }
    }

    /// Nome de exibição de um agendamento no painel: nome explícito → texto do
    /// comando truncado; contínuo sem nome vira o fallback ("renovação").
    static func eventName(_ task: ScheduledTask, renewalFallbackName: String) -> String {
        if let name = task.name, !name.isEmpty { return name }
        if task.repetition == .continuous { return renewalFallbackName }
        let text = task.resolvedCommand.text
        return text.count > 30 ? String(text.prefix(30)) + "…" : text
    }

    /// Um disparo futuro no painel: a tarefa, a conta que ela mira, o nome de
    /// exibição e a data do próximo disparo.
    struct UpcomingEvent: Equatable {
        let taskUID: UUID
        /// Tarefas shell não pertencem a uma conta de provedor.
        let account: URL?
        let name: String
        let date: Date
    }

    /// Próximos disparos entre todas as contas, ordenados por data, limitados
    /// a `limit`. Pula contas pausadas (o FireController descartaria o
    /// disparo) e datas passadas. A mesma conta pode aparecer mais de uma vez.
    static func upcomingEvents(tasks: [ScheduledTask],
                               nextRenewals: [URL: Date], nextTaskFires: [UUID: Date],
                               isPaused: (URL) -> Bool,
                               isQuotaUnavailable: (URL) -> Bool = { _ in false },
                               needsAttention: (URL) -> Bool = { _ in false },
                               accountDir: (ScheduledTask) -> URL?, now: Date,
                               limit: Int, renewalFallbackName: String) -> [UpcomingEvent] {
        var events: [UpcomingEvent] = []
        for task in tasks where task.enabled {
            let account = accountDir(task)
            guard account != nil || task.resolvedCommand.kind == .shell else { continue }
            if let account, isPaused(account) { continue }
            if task.repetition == .continuous,
               let account,
               isQuotaUnavailable(account) || needsAttention(account) {
                continue
            }
            let date: Date?
            switch task.repetition {
            case .continuous:
                date = account.flatMap { nextRenewals[$0] }
            case .fixed: date = nextTaskFires[task.uid]
            }
            if let date, date > now {
                events.append(UpcomingEvent(
                    taskUID: task.uid, account: account,
                    name: eventName(task, renewalFallbackName: renewalFallbackName),
                    date: date))
            }
        }
        return Array(events.sorted { $0.date < $1.date }.prefix(max(0, limit)))
    }

    /// O que o painel mostra quando não há disparo futuro a exibir.
    enum PanelEmptyState {
        case noSchedules
        case allDisabled
        case allPaused
        case conflict
        case accountMissing
        case invalidConfiguration
        case quotaUnavailable
        case needsAttention
        case waiting
    }

    /// Prioriza bloqueios explícitos do lifecycle; depois distingue pausa,
    /// indisponibilidade e espera normal por janela/data.
    static func emptyState(tasks: [ScheduledTask],
                           accountDir: (ScheduledTask) -> URL?,
                           isPaused: (URL) -> Bool,
                           isQuotaUnavailable: (URL) -> Bool = { _ in false },
                           needsAttention: (URL) -> Bool = { _ in false },
                           continuousPhase:
                            (ScheduledTask) -> RenewalSnapshot.Phase? =
                            { _ in nil })
        -> PanelEmptyState {
        if tasks.isEmpty { return .noSchedules }
        let enabled = tasks.filter { $0.enabled }
        if enabled.isEmpty { return .allDisabled }
        if enabled.contains(where: {
            $0.repetition == .continuous
                && continuousPhase($0) == .conflict
        }) {
            return .conflict
        }
        if enabled.contains(where: {
            $0.repetition == .continuous
                && continuousPhase($0) == .accountMissing
        }) {
            return .accountMissing
        }
        if enabled.contains(where: {
            $0.repetition == .continuous
                && continuousPhase($0) == .invalidConfiguration
        }) {
            return .invalidConfiguration
        }
        if enabled.contains(where: { $0.resolvedCommand.kind == .shell }) {
            return .waiting
        }
        let accounts = Set(enabled.compactMap { accountDir($0) })
        if accounts.isEmpty { return .waiting }
        if accounts.allSatisfy(isPaused) { return .allPaused }
        let continuousAccounts = Set(
            enabled
                .filter { $0.repetition == .continuous }
                .compactMap(accountDir)
        )
        if continuousAccounts.contains(
            where: { !isPaused($0) && isQuotaUnavailable($0) }
        ) {
            return .quotaUnavailable
        }
        if continuousAccounts.contains(
            where: { !isPaused($0) && needsAttention($0) }
        ) {
            return .needsAttention
        }
        return .waiting
    }
}
