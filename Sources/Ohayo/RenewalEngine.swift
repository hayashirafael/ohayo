import Combine
import Foundation

struct ContinuousScheduleDefinition: Equatable {
    let task: ScheduledTask
    let intendedAccount: URL?
    let availableAccount: URL?
    var paused: Bool
    var recovery: RenewalRecoveryState?

    init(
        task: ScheduledTask,
        intendedAccount: URL?,
        availableAccount: URL?,
        paused: Bool = false,
        recovery: RenewalRecoveryState? = nil
    ) {
        self.task = task
        self.intendedAccount = intendedAccount.map {
            ProviderAccountContext.canonicalAccountDirectory($0)
        }
        self.availableAccount = availableAccount.map {
            ProviderAccountContext.canonicalAccountDirectory($0)
        }
        self.paused = paused
        self.recovery = recovery
    }

    var provider: Provider? {
        switch task.resolvedCommand.kind {
        case .claude: return .claude
        case .codex: return .codex
        case .shell: return nil
        }
    }
}

struct ContinuousScheduleInput: Equatable {
    var definitions: [ContinuousScheduleDefinition]
    var paused: Bool

    init(
        definitions: [ContinuousScheduleDefinition],
        paused: Bool = false
    ) {
        self.definitions = definitions
        self.paused = paused
    }
}

struct RenewalSnapshot: Equatable {
    struct Entry: Equatable {
        let taskID: UUID
        let account: URL?
        let phase: Phase
    }

    enum Phase: Equatable {
        case paused
        case accountMissing
        case conflict
        case invalidConfiguration
        case waitingForWindow
        case scheduled(Date)
        case dispatching
        case cooldown(Date, bootstrapOrigin: Bool)
        case retry(Date, attempt: Int, bootstrapOrigin: Bool)
        case quotaUnavailable(String)
        case needsAttention
    }

    var byTask: [UUID: Entry] = [:]

    subscript(taskID: UUID) -> Entry? {
        byTask[taskID]
    }

    var nextByAccount: [URL: Date] {
        var result: [URL: Date] = [:]
        for entry in byTask.values {
            guard let account = entry.account else { continue }
            let date: Date?
            switch entry.phase {
            case .scheduled(let value),
                 .cooldown(let value, _),
                 .retry(let value, _, _):
                date = value
            case .paused, .accountMissing, .conflict,
                 .invalidConfiguration, .waitingForWindow,
                 .dispatching, .quotaUnavailable, .needsAttention:
                date = nil
            }
            if let date {
                result[account] = date
            }
        }
        return result
    }

    var quotaUnavailableReasons: [URL: String] {
        Dictionary(uniqueKeysWithValues: byTask.values.compactMap { entry in
            guard let account = entry.account,
                  case .quotaUnavailable(let reason) = entry.phase else {
                return nil
            }
            return (account, reason)
        })
    }

    var needsAttentionAccounts: Set<URL> {
        Set(byTask.values.compactMap { entry in
            guard case .needsAttention = entry.phase else { return nil }
            return entry.account
        })
    }
}

/// Encadeia janelas de 5h por conta: arma no fim da janela detectada e re-arma
/// após cada disparo. Alimentado pelos agendamentos contínuos. Timers reais só
/// no app; o catch-up é testado com relógio e detector fakes.
@MainActor
final class RenewalEngine: ObservableObject {
    enum Trigger: Equatable {
        case bootstrap
        case scheduled
    }

    private(set) var nextRenewal: [URL: Date] = [:]
    private(set) var quotaUnavailableReasons: [URL: String] = [:]

    private let detector: SessionDetecting
    private let clock: Clock
    private let dispatch:
        (ScheduledTask, Trigger) async -> DispatchOutcome
    private let persistRecovery:
        (ScheduledTask, RenewalRecoveryState?) -> Void
    @Published private(set) var snapshot = RenewalSnapshot()
    private var lastInput: ContinuousScheduleInput?
    private var configurationGeneration: UInt = 0
    private var taskByAccount: [URL: ScheduledTask] = [:]
    private var snapshotBase: [UUID: RenewalSnapshot.Entry] = [:]
    private struct DetectionToken: Equatable {
        let generation: UInt
        let taskID: UUID
        let revision: String
        let provider: Provider
    }
    private struct RuntimeConfiguration {
        let accounts: Set<URL>
        let bootstrapAccounts: Set<URL>
        let recoveryStates: [URL: RenewalRecoveryState]
        let revisions: [URL: String]
        let providers: [URL: Provider]
        let paused: Bool
    }
    private let dedupeInterval: TimeInterval = 120
    private let retryBaseDelay: TimeInterval
    private let retryJitter: (URL, Int) -> Double
    private let maximumRetryDelay: TimeInterval = 15 * 60
    private let bootstrapCooldown: TimeInterval
    private var accounts: Set<URL> = []
    /// Contas para as quais o usuário consentiu que a ausência de uma janela
    /// detectável resulte em um disparo imediato.
    private var bootstrapAccounts: Set<URL> = []
    /// Cooldown persistido pelo AppState. Enquanto futuro, arma somente um
    /// wake local; ao vencer, volta a validar transcripts antes do disparo.
    private var bootstrapNotBefore: [URL: Date] = [:]
    /// Distingue um bootstrap opt-in de um hand-off agendado já autorizado.
    /// O segundo precisa sobreviver ao restart mesmo sem consentimento para
    /// iniciar uma janela que nunca existiu.
    private var cooldownBootstrapOrigins: [URL: Bool] = [:]
    private var bootstrapCooldownTimers: Set<URL> = []
    private var paused = false
    private var timers: [URL: Timer] = [:]
    private var lastRenewAt: [URL: Date] = [:]
    /// Evita que ausência de evidência dispare um loop: cada conta faz no
    /// máximo um bootstrap enquanto permanecer configurada nesta instância.
    /// Uma falha transitória não depende deste marcador; usa `pendingRetry`.
    private var attemptedRenewal: Set<URL> = []
    /// Contas cuja última tentativa falhou transitoriamente — `rearm` tenta de
    /// novo depois do backoff.
    private var pendingRetry: Set<URL> = []
    /// Subconjunto de retries originados pelo bootstrap opcional. Permite
    /// cancelar somente esse trabalho se o usuário revogar o consentimento,
    /// sem interromper uma renovação normal de janela já encadeada.
    private var bootstrapRetryAccounts: Set<URL> = []
    /// Auth, CLI, permissão e configuração exigem intervenção. Enquanto não
    /// surgir evidência real ou o consentimento/configuração mudar, ticks não
    /// repetem o mesmo alerta.
    private(set) var needsAttentionAccounts: Set<URL> = []
    private var retryAttempts: [URL: Int] = [:]
    private var retryNotBefore: [URL: Date] = [:]
    private var accountRevisions: [URL: String] = [:]
    private var accountProviders: [URL: Provider] = [:]
    private var inFlightAccounts: Set<URL> = []

    init(
        detector: SessionDetecting,
        clock: Clock = SystemClock(),
        retryBaseDelay: TimeInterval = 60,
        bootstrapCooldown: TimeInterval = SessionDetector.blockDuration,
        retryJitter: @escaping (URL, Int) -> Double =
            RenewalEngine.stableRetryJitter,
        dispatch: @escaping (
            ScheduledTask,
            Trigger
        ) async -> DispatchOutcome = { _, _ in .completed },
        persistRecovery: @escaping (
            ScheduledTask,
            RenewalRecoveryState?
        ) -> Void = { _, _ in }
    ) {
        self.detector = detector
        self.clock = clock
        self.retryBaseDelay = retryBaseDelay
        self.bootstrapCooldown = bootstrapCooldown
        self.retryJitter = retryJitter
        self.dispatch = dispatch
        self.persistRecovery = persistRecovery
    }

    /// Entrada única do lifecycle. O caller fornece cada task contínua com sua
    /// identidade pretendida e disponibilidade atual; conflito, pause, pasta
    /// ausente, Provider, revisão e recovery passam a ser resolvidos juntos.
    func synchronize(_ input: ContinuousScheduleInput) async {
        if lastInput == input {
            await rearmAll()
            return
        }
        configurationGeneration &+= 1
        lastInput = input

        var groups: [URL: [ContinuousScheduleDefinition]] = [:]
        var base: [UUID: RenewalSnapshot.Entry] = [:]
        for definition in input.definitions {
            if let account = definition.intendedAccount {
                groups[account, default: []].append(definition)
            } else {
                base[definition.task.uid] = RenewalSnapshot.Entry(
                    taskID: definition.task.uid,
                    account: nil,
                    phase: .invalidConfiguration
                )
            }
        }

        var tasks: [URL: ScheduledTask] = [:]
        var activeAccounts: Set<URL> = []
        var bootstrapAccounts: Set<URL> = []
        var recoveryStates: [URL: RenewalRecoveryState] = [:]
        var revisions: [URL: String] = [:]
        var providers: [URL: Provider] = [:]

        for (intendedAccount, definitions) in groups {
            if definitions.count != 1 {
                for definition in definitions {
                    base[definition.task.uid] = RenewalSnapshot.Entry(
                        taskID: definition.task.uid,
                        account: intendedAccount,
                        phase: .conflict
                    )
                }
                continue
            }
            guard let definition = definitions.first else { continue }
            if input.paused || definition.paused {
                base[definition.task.uid] = RenewalSnapshot.Entry(
                    taskID: definition.task.uid,
                    account: intendedAccount,
                    phase: .paused
                )
                continue
            }
            guard let account = definition.availableAccount else {
                base[definition.task.uid] = RenewalSnapshot.Entry(
                    taskID: definition.task.uid,
                    account: intendedAccount,
                    phase: .accountMissing
                )
                continue
            }
            guard account == intendedAccount else {
                base[definition.task.uid] = RenewalSnapshot.Entry(
                    taskID: definition.task.uid,
                    account: intendedAccount,
                    phase: .invalidConfiguration
                )
                continue
            }
            guard let provider = definition.provider else {
                base[definition.task.uid] = RenewalSnapshot.Entry(
                    taskID: definition.task.uid,
                    account: intendedAccount,
                    phase: .invalidConfiguration
                )
                continue
            }

            tasks[account] = definition.task
            activeAccounts.insert(account)
            revisions[account] = definition.task.renewalRevision
            providers[account] = provider
            if definition.task.resolvedBootstrapWhenInactive {
                bootstrapAccounts.insert(account)
            }
            if let recovery = definition.recovery {
                recoveryStates[account] = recovery
            }
        }

        taskByAccount = tasks
        snapshotBase = base
        await apply(RuntimeConfiguration(
            accounts: activeAccounts,
            bootstrapAccounts: bootstrapAccounts,
            recoveryStates: recoveryStates,
            revisions: revisions,
            providers: providers,
            paused: input.paused
        ))
        publishSnapshot()
    }

    private func apply(_ configuration: RuntimeConfiguration) async {
        // `ContinuousScheduleDefinition` canonicaliza as contas na entrada;
        // esta projeção já nasce coerente e não repete normalização por mapa.
        let normalized = configuration.accounts
        let normalizedBootstrap =
            configuration.bootstrapAccounts.intersection(normalized)
        let revokedBootstrap = self.bootstrapAccounts.subtracting(
            normalizedBootstrap
        )
        let removedAccounts = self.accounts.subtracting(normalized)
        self.accounts = normalized
        self.bootstrapAccounts = normalizedBootstrap
        self.bootstrapNotBefore = [:]
        self.cooldownBootstrapOrigins = [:]
        self.accountRevisions = configuration.revisions
        self.accountProviders = configuration.providers
        self.paused = configuration.paused
        // Reconstrói o estado local a partir do snapshot autoritativo recebido
        // abaixo; limpa primeiro para não conservar bloqueios de contas
        // removidas ou revisões anteriores.
        needsAttentionAccounts.removeAll()
        // A configuração recebe o snapshot persistido mais recente. Recria
        // timers de cooldown a partir dele para não conservar um deadline
        // antigo quando a task revoga o opt-in ou muda de conta.
        for account in Array(bootstrapCooldownTimers) {
            timers[account]?.invalidate()
            timers[account] = nil
            nextRenewal[account] = nil
            bootstrapCooldownTimers.remove(account)
        }
        for account in Array(timers.keys)
            where configuration.paused || !normalized.contains(account) {
            timers[account]?.invalidate()
            timers[account] = nil
            bootstrapCooldownTimers.remove(account)
        }
        if configuration.paused {
            nextRenewal = [:]
            quotaUnavailableReasons = [:]
            bootstrapCooldownTimers.removeAll()
            attemptedRenewal.removeAll()
            pendingRetry.removeAll()
            bootstrapRetryAccounts.removeAll()
            needsAttentionAccounts.removeAll()
            retryAttempts.removeAll()
            retryNotBefore.removeAll()
            cooldownBootstrapOrigins.removeAll()
        } else {
            for account in Array(nextRenewal.keys) where !normalized.contains(account) {
                nextRenewal[account] = nil
            }
            for account in removedAccounts {
                lastRenewAt[account] = nil
                retryAttempts[account] = nil
                retryNotBefore[account] = nil
                quotaUnavailableReasons[account] = nil
                bootstrapCooldownTimers.remove(account)
                cooldownBootstrapOrigins[account] = nil
                needsAttentionAccounts.remove(account)
            }
            attemptedRenewal = attemptedRenewal.filter { normalized.contains($0) }
            pendingRetry = pendingRetry.filter { normalized.contains($0) }
            bootstrapRetryAccounts = bootstrapRetryAccounts.filter {
                normalized.contains($0)
            }
            needsAttentionAccounts = needsAttentionAccounts.filter {
                normalized.contains($0)
            }
            for account in revokedBootstrap {
                attemptedRenewal.remove(account)
                needsAttentionAccounts.remove(account)
                if bootstrapRetryAccounts.contains(account) {
                    clearRetry(for: account)
                    nextRenewal[account] = nil
                }
            }
            for account in normalized {
                attemptedRenewal.remove(account)
                pendingRetry.remove(account)
                bootstrapRetryAccounts.remove(account)
                retryAttempts[account] = nil
                retryNotBefore[account] = nil
                needsAttentionAccounts.remove(account)
            }
            for (account, recovery) in configuration.recoveryStates {
                attemptedRenewal.insert(account)
                switch recovery {
                case .cooldown(let notBefore, let bootstrapOrigin):
                    self.bootstrapNotBefore[account] = notBefore
                    self.cooldownBootstrapOrigins[account] = bootstrapOrigin
                case .retry(
                    let notBefore,
                    let attempt,
                    let bootstrapOrigin
                ):
                    pendingRetry.insert(account)
                    retryNotBefore[account] = notBefore
                    retryAttempts[account] = max(1, attempt)
                    if bootstrapOrigin {
                        bootstrapRetryAccounts.insert(account)
                    }
                case .needsAttention:
                    needsAttentionAccounts.insert(account)
                }
            }
        }
        await rearmAll()
    }

    /// Chamar ao acordar do sleep — e após cada disparo (a janela pode ter mudado).
    func handleWake() async { await rearmAll() }

    func rearmAll() async {
        guard !paused else { return }
        for account in accounts {
            await rearm(account, publishWhenFinished: false)
        }
        publishSnapshot()
    }

    private func rearm(
        _ account: URL,
        publishWhenFinished: Bool = true
    ) async {
        defer {
            if publishWhenFinished {
                publishSnapshot()
            }
        }
        guard !inFlightAccounts.contains(account) else { return }
        if needsAttentionAccounts.contains(account) {
            guard let state =
                await currentQuotaWindowState(for: account) else {
                return
            }
            switch state {
            case .active(let end):
                quotaUnavailableReasons[account] = nil
                needsAttentionAccounts.remove(account)
                clearDurableRecovery(for: account)
                armWindowTimer(account, at: end)
            case .unavailable(let reason):
                haltForUnavailable(account, reason: reason)
            case .inactive:
                quotaUnavailableReasons[account] = nil
                nextRenewal[account] = nil
            }
            return
        }
        if pendingRetry.contains(account) {
            // Uma execução pode ter respondido tarde e produzido evidência
            // mesmo após o runner reportar timeout. Nesse caso cancela o retry
            // antes de abrir outra janela.
            guard let state =
                await currentQuotaWindowState(for: account) else {
                return
            }
            switch state {
            case .active(let end):
                quotaUnavailableReasons[account] = nil
                clearRetry(for: account)
                clearDurableRecovery(for: account)
                armWindowTimer(account, at: end)
                return
            case .unavailable(let reason):
                haltForUnavailable(account, reason: reason)
                return
            case .inactive:
                quotaUnavailableReasons[account] = nil
            }
            if let notBefore = retryNotBefore[account], notBefore > clock.now {
                nextRenewal[account] = notBefore
                return
            }
            pendingRetry.remove(account)
            retryNotBefore[account] = nil
            let bootstrapAttempt = bootstrapRetryAccounts.contains(account)
            await renew(account, bootstrapAttempt: bootstrapAttempt)
            return
        }
        if let armed = nextRenewal[account],
           armed > clock.now,
           timers[account] != nil,
           !bootstrapCooldownTimers.contains(account) {
            return
        }
        guard let state =
            await currentQuotaWindowState(for: account) else {
            return
        }
        switch state {
        case .active(let end):
            quotaUnavailableReasons[account] = nil
            clearRetry(for: account)
            clearDurableRecovery(for: account)
            armWindowTimer(account, at: end)
        case .unavailable(let reason):
            haltForUnavailable(account, reason: reason)
        case .inactive:
            quotaUnavailableReasons[account] = nil
            let wasCooldown = bootstrapCooldownTimers.remove(account) != nil
            let missed = !wasCooldown
                && (nextRenewal[account].map { $0 <= clock.now } ?? false)
            timers[account]?.invalidate(); timers[account] = nil
            nextRenewal[account] = nil
            let hasBootstrapConsent = bootstrapAccounts.contains(account)
            let notBefore = bootstrapNotBefore[account]
            let cooldownOrigin = cooldownBootstrapOrigins[account]
            let scheduledCooldown = cooldownOrigin == false
            let authorizedCooldown = scheduledCooldown || hasBootstrapConsent
            let cooldownEligible = authorizedCooldown
                && (notBefore.map { $0 <= clock.now } ?? false)
            let firstBootstrapEligible = hasBootstrapConsent
                && notBefore == nil
                && !attemptedRenewal.contains(account)
            let mayRenew = cooldownEligible || firstBootstrapEligible
            if !missed, authorizedCooldown, !mayRenew,
               let notBefore, notBefore > clock.now {
                armBootstrapTimer(account, at: notBefore)
                return
            }
            if missed || mayRenew {
                let isBootstrap = !missed
                    && (cooldownEligible
                        ? cooldownOrigin != false
                        : firstBootstrapEligible)
                await renew(
                    account,
                    bootstrapAttempt: isBootstrap
                )
            }
        }
    }

    private func armWindowTimer(_ account: URL, at date: Date) {
        bootstrapCooldownTimers.remove(account)
        nextRenewal[account] = date
        timers[account]?.invalidate()
        let t = Timer(fire: date.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timers[account] = nil
                await self.renew(account)
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timers[account] = t
    }

    private func armBootstrapTimer(_ account: URL, at date: Date) {
        nextRenewal[account] = date
        timers[account]?.invalidate()
        bootstrapCooldownTimers.insert(account)
        let timer = Timer(
            fire: date.addingTimeInterval(1),
            interval: 0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timers[account] = nil
                await self.rearm(account)
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        timers[account] = timer
    }

    private func renew(
        _ account: URL,
        bootstrapAttempt: Bool = false
    ) async {
        defer { publishSnapshot() }
        guard !paused, accounts.contains(account) else {
            pendingRetry.remove(account)
            return
        }
        guard !inFlightAccounts.contains(account) else { return }
        guard let task = taskByAccount[account] else {
            needsAttentionAccounts.insert(account)
            nextRenewal[account] = nil
            return
        }
        let now = clock.now
        if let last = lastRenewAt[account], now.timeIntervalSince(last) < dedupeInterval { return }
        attemptedRenewal.insert(account)
        nextRenewal[account] = nil
        let trigger: Trigger = bootstrapAttempt ? .bootstrap : .scheduled
        let crashSafeNotBefore = now.addingTimeInterval(bootstrapCooldown)
        bootstrapNotBefore[account] = crashSafeNotBefore
        cooldownBootstrapOrigins[account] = bootstrapAttempt
        emitRecovery(
            .cooldown(
                notBefore: crashSafeNotBefore,
                bootstrapOrigin: bootstrapAttempt
            ),
            for: task
        )
        let dispatchedRevision = accountRevisions[account]
        inFlightAccounts.insert(account)
        publishSnapshot()
        let outcome = await dispatch(task, trigger)
        inFlightAccounts.remove(account)
        guard !paused, accounts.contains(account) else {
            clearRetry(for: account)
            nextRenewal[account] = nil
            return
        }
        if accountRevisions[account] != dispatchedRevision {
            // A tarefa mudou durante o await. O hand-off antigo pode já ter
            // chegado ao CLI, então não aplica seu outcome à revisão nova nem
            // dispara outro comando imediatamente. Um cooldown conservador,
            // ainda substituível por transcript real, evita duplicação.
            clearRetry(for: account)
            needsAttentionAccounts.remove(account)
            attemptedRenewal.insert(account)
            let staleNotBefore = clock.now.addingTimeInterval(bootstrapCooldown)
            bootstrapNotBefore[account] = staleNotBefore
            cooldownBootstrapOrigins[account] = bootstrapAttempt
            nextRenewal[account] = nil
            let lease = RenewalRecoveryState.cooldown(
                notBefore: staleNotBefore,
                bootstrapOrigin: bootstrapAttempt
            )
            if let currentTask = taskByAccount[account] {
                // A lease pertence ao hand-off da conta, não ao outcome antigo.
                // Persiste na revisão corrente para sobreviver a restart.
                emitRecovery(lease, for: currentTask)
            }
            await rearm(account)
            return
        }
        // O callback é suspensível. O usuário pode revogar o consentimento
        // enquanto Terminal/controller processam o hand-off; nesse caso nem
        // retry nem cooldown podem sobreviver ao retorno, qualquer que seja o
        // outcome.
        if bootstrapAttempt, !bootstrapAccounts.contains(account) {
            clearRetry(for: account)
            attemptedRenewal.remove(account)
            clearDurableRecovery(for: account)
            nextRenewal[account] = nil
            return
        }
        switch outcome {
        case .retryableFailure:
            let attempt = (retryAttempts[account] ?? 0) + 1
            retryAttempts[account] = attempt
            let exponent = min(attempt - 1, 10)
            let exponential = retryBaseDelay * pow(2, Double(exponent))
            let jittered = exponential * retryJitter(account, attempt)
            let delay = min(maximumRetryDelay, max(1, jittered))
            let retryAt = clock.now.addingTimeInterval(delay)
            pendingRetry.insert(account)
            if bootstrapAttempt {
                bootstrapRetryAccounts.insert(account)
            } else {
                bootstrapRetryAccounts.remove(account)
            }
            retryNotBefore[account] = retryAt
            nextRenewal[account] = retryAt
            emitRecovery(
                .retry(
                    notBefore: retryAt,
                    attempt: attempt,
                    bootstrapOrigin: bootstrapAttempt
                ),
                for: task
            )
            return
        case .needsAttention:
            clearRetry(for: account)
            needsAttentionAccounts.insert(account)
            attemptedRenewal.remove(account)
            bootstrapNotBefore[account] = nil
            cooldownBootstrapOrigins[account] = nil
            nextRenewal[account] = nil
            emitRecovery(
                .needsAttention(bootstrapOrigin: bootstrapAttempt),
                for: task
            )
            return
        case .paused:
            clearRetry(for: account)
            clearDurableRecovery(for: account)
            nextRenewal[account] = nil
            return
        case .completed, .launched, .skipped:
            break
        }
        needsAttentionAccounts.remove(account)
        clearRetry(for: account)
        let completionTime = clock.now
        lastRenewAt[account] = completionTime
        // O cooldown evita duplicar um hand-off cujo transcript demora ou
        // nunca aparece. Também é necessário para hand-offs agendados: nesses
        // casos o recovery não depende do opt-in de bootstrap inicial.
        let handoffNotBefore = completionTime.addingTimeInterval(
            bootstrapCooldown
        )
        bootstrapNotBefore[account] = handoffNotBefore
        cooldownBootstrapOrigins[account] = bootstrapAttempt
        emitRecovery(
            .cooldown(
                notBefore: handoffNotBefore,
                bootstrapOrigin: bootstrapAttempt
            ),
            for: task
        )
        await rearm(account) // encadeia
    }

    private func clearRetry(for account: URL) {
        pendingRetry.remove(account)
        bootstrapRetryAccounts.remove(account)
        retryAttempts[account] = nil
        retryNotBefore[account] = nil
    }

    private func clearDurableRecovery(for account: URL) {
        bootstrapNotBefore[account] = nil
        cooldownBootstrapOrigins[account] = nil
        emitRecovery(nil, for: account)
    }

    private func emitRecovery(
        _ recovery: RenewalRecoveryState?,
        for task: ScheduledTask
    ) {
        persistRecovery(task, recovery)
    }

    private func emitRecovery(
        _ recovery: RenewalRecoveryState?,
        for account: URL
    ) {
        if let task = taskByAccount[account] {
            emitRecovery(recovery, for: task)
        }
    }

    private func detectionToken(for account: URL) -> DetectionToken? {
        guard accounts.contains(account),
              let task = taskByAccount[account],
              let revision = accountRevisions[account],
              let provider = accountProviders[account] else {
            return nil
        }
        return DetectionToken(
            generation: configurationGeneration,
            taskID: task.uid,
            revision: revision,
            provider: provider
        )
    }

    /// O detector é suspensível. Uma edição pode trocar task/provider enquanto
    /// a leitura está em voo; só o resultado da configuração ainda corrente
    /// pode alterar retry, timer ou disparar um comando.
    private func currentQuotaWindowState(
        for account: URL
    ) async -> QuotaWindowState? {
        guard let token = detectionToken(for: account) else { return nil }
        let state = await detector.quotaWindowState(
            account: account,
            provider: token.provider
        )
        guard detectionToken(for: account) == token else { return nil }
        return state
    }

    /// Falha fechado: se a fonte de quota não pode ser lida com confiança,
    /// cancela timer/retry e não converte o erro em ausência de janela.
    private func haltForUnavailable(_ account: URL, reason: String) {
        timers[account]?.invalidate()
        timers[account] = nil
        bootstrapCooldownTimers.remove(account)
        nextRenewal[account] = nil
        // Um retry já autorizado apenas pausa enquanto a fonte está
        // indisponível; preservar origem/tentativa permite retomá-lo quando a
        // leitura volta, sem convertê-lo em novo bootstrap.
        if !pendingRetry.contains(account) {
            clearRetry(for: account)
        }
        quotaUnavailableReasons[account] = reason
    }

    private func publishSnapshot() {
        var entries = snapshotBase
        for (account, task) in taskByAccount {
            let phase: RenewalSnapshot.Phase
            if let reason = quotaUnavailableReasons[account] {
                phase = .quotaUnavailable(reason)
            } else if needsAttentionAccounts.contains(account) {
                phase = .needsAttention
            } else if inFlightAccounts.contains(account) {
                phase = .dispatching
            } else if pendingRetry.contains(account),
                      let retryAt =
                        retryNotBefore[account] ?? nextRenewal[account] {
                phase = .retry(
                    retryAt,
                    attempt: max(1, retryAttempts[account] ?? 1),
                    bootstrapOrigin:
                        bootstrapRetryAccounts.contains(account)
                )
            } else if bootstrapCooldownTimers.contains(account),
                      let cooldownAt = nextRenewal[account] {
                phase = .cooldown(
                    cooldownAt,
                    bootstrapOrigin:
                        cooldownBootstrapOrigins[account] ?? false
                )
            } else if let scheduledAt = nextRenewal[account] {
                phase = .scheduled(scheduledAt)
            } else {
                phase = .waitingForWindow
            }
            entries[task.uid] = RenewalSnapshot.Entry(
                taskID: task.uid,
                account: account,
                phase: phase
            )
        }
        let updated = RenewalSnapshot(byTask: entries)
        if snapshot != updated {
            snapshot = updated
        }
    }

    /// Jitter estável por conta/tentativa (90–110%): evita rajadas após wake ou
    /// falha de rede sem tornar o comportamento impossível de reproduzir.
    nonisolated private static func stableRetryJitter(
        account: URL,
        attempt: Int
    ) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(account.standardizedFileURL.path)#\(attempt)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return 0.9 + Double(hash % 21) / 100
    }
}
