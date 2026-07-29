import Foundation

/// Encadeia janelas de 5h por conta: arma no fim da janela detectada e re-arma
/// após cada disparo. Alimentado pelos agendamentos contínuos. Timers reais só
/// no app; o catch-up é testado com relógio e detector fakes.
@MainActor
final class RenewalEngine {
    enum Trigger: Equatable {
        case bootstrap
        case scheduled
    }

    /// Preserva o outcome do controller até o motor: somente falha transitória
    /// faz retry, somente entrega/conclusão arma cooldown e ação humana fica
    /// bloqueada sem loop.
    var onRenew: ((URL, Trigger) async -> DispatchOutcome)?
    /// Snapshot de `nextRenewal` a cada mudança — vira "renova às HH:mm" na UI.
    var onStatus: (([URL: Date]) -> Void)?
    /// Motivos de indisponibilidade por conta. A UI mostra uma cópia genérica;
    /// o motivo técnico fica disponível para diagnóstico local.
    var onQuotaUnavailable: (([URL: String]) -> Void)?
    var onNeedsAttention: ((Set<URL>) -> Void)?
    var onRecoveryState: ((URL, RenewalRecoveryState?) -> Void)?

    private(set) var nextRenewal: [URL: Date] = [:] {
        didSet { onStatus?(nextRenewal) }
    }
    private(set) var quotaUnavailableReasons: [URL: String] = [:] {
        didSet { onQuotaUnavailable?(quotaUnavailableReasons) }
    }

    private let detector: SessionDetecting
    private let clock: Clock
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
    private(set) var needsAttentionAccounts: Set<URL> = [] {
        didSet { onNeedsAttention?(needsAttentionAccounts) }
    }
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
        retryJitter: @escaping (URL, Int) -> Double = RenewalEngine.stableRetryJitter
    ) {
        self.detector = detector
        self.clock = clock
        self.retryBaseDelay = retryBaseDelay
        self.bootstrapCooldown = bootstrapCooldown
        self.retryJitter = retryJitter
    }

    func configure(
        accounts: Set<URL>,
        bootstrapAccounts: Set<URL>,
        bootstrapNotBefore: [URL: Date] = [:],
        recoveryStates: [URL: RenewalRecoveryState]? = nil,
        accountRevisions: [URL: String]? = nil,
        accountProviders: [URL: Provider]? = nil,
        paused: Bool
    ) async {
        let normalized = Set(accounts.map {
            ProviderAccountContext.canonicalAccountDirectory($0)
        })
        let normalizedBootstrap = Set(
            bootstrapAccounts.map {
                ProviderAccountContext.canonicalAccountDirectory($0)
            }
        ).intersection(normalized)
        let revokedBootstrap = self.bootstrapAccounts.subtracting(
            normalizedBootstrap
        )
        var normalizedNotBefore: [URL: Date] = [:]
        for (account, date) in bootstrapNotBefore {
            let normalizedAccount =
                ProviderAccountContext.canonicalAccountDirectory(account)
            if normalizedBootstrap.contains(normalizedAccount) {
                normalizedNotBefore[normalizedAccount] = max(
                    normalizedNotBefore[normalizedAccount] ?? date,
                    date
                )
            }
        }
        let normalizedRecoveryStates = recoveryStates.map { states in
            var result: [URL: RenewalRecoveryState] = [:]
            for (account, state) in states {
                let normalizedAccount =
                    ProviderAccountContext.canonicalAccountDirectory(account)
                if normalized.contains(normalizedAccount) {
                    result[normalizedAccount] = state
                }
            }
            return result
        }
        let normalizedRevisions = accountRevisions.map { revisions in
            var result: [URL: String] = [:]
            for (account, revision) in revisions {
                let normalizedAccount =
                    ProviderAccountContext.canonicalAccountDirectory(account)
                if normalized.contains(normalizedAccount) {
                    result[normalizedAccount] = revision
                }
            }
            return result
        }
        let normalizedProviders = accountProviders.map { providers in
            var result: [URL: Provider] = [:]
            for (account, provider) in providers {
                let normalizedAccount =
                    ProviderAccountContext.canonicalAccountDirectory(account)
                if normalized.contains(normalizedAccount) {
                    result[normalizedAccount] = provider
                }
            }
            return result
        }
        let removedAccounts = self.accounts.subtracting(normalized)
        self.accounts = normalized
        self.bootstrapAccounts = normalizedBootstrap
        self.bootstrapNotBefore = normalizedNotBefore
        self.cooldownBootstrapOrigins = Dictionary(
            uniqueKeysWithValues: normalizedNotBefore.keys.map { ($0, true) }
        )
        if let normalizedRevisions {
            self.accountRevisions = normalizedRevisions
        } else {
            self.accountRevisions = self.accountRevisions.filter {
                normalized.contains($0.key)
            }
        }
        if let normalizedProviders {
            self.accountProviders = normalizedProviders
        } else {
            self.accountProviders = self.accountProviders.filter {
                normalized.contains($0.key)
            }
        }
        self.paused = paused
        // Reconstrói o estado local a partir do snapshot autoritativo recebido
        // abaixo; limpa primeiro para não conservar bloqueios de contas
        // removidas ou revisões anteriores.
        needsAttentionAccounts.removeAll()
        // `configure` recebe o snapshot persistido mais recente. Recria
        // timers de cooldown a partir dele para não conservar um deadline
        // antigo quando a task revoga o opt-in ou muda de conta.
        for account in Array(bootstrapCooldownTimers) {
            timers[account]?.invalidate()
            timers[account] = nil
            nextRenewal[account] = nil
            bootstrapCooldownTimers.remove(account)
        }
        for account in Array(timers.keys) where paused || !normalized.contains(account) {
            timers[account]?.invalidate()
            timers[account] = nil
            bootstrapCooldownTimers.remove(account)
        }
        if paused {
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
            if let normalizedRecoveryStates {
                for account in normalized {
                    attemptedRenewal.remove(account)
                    pendingRetry.remove(account)
                    bootstrapRetryAccounts.remove(account)
                    retryAttempts[account] = nil
                    retryNotBefore[account] = nil
                    needsAttentionAccounts.remove(account)
                    self.bootstrapNotBefore[account] = nil
                    self.cooldownBootstrapOrigins[account] = nil
                }
                for (account, recovery) in normalizedRecoveryStates {
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
        }
        await rearmAll()
    }

    /// Chamar ao acordar do sleep — e após cada disparo (a janela pode ter mudado).
    func handleWake() async { await rearmAll() }

    func rearmAll() async {
        guard !paused else { return }
        for account in accounts { await rearm(account) }
    }

    private func rearm(_ account: URL) async {
        guard !inFlightAccounts.contains(account) else { return }
        if needsAttentionAccounts.contains(account) {
            switch await quotaWindowState(for: account) {
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
            switch await quotaWindowState(for: account) {
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
        switch await quotaWindowState(for: account) {
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
        guard !paused, accounts.contains(account) else {
            pendingRetry.remove(account)
            return
        }
        guard !inFlightAccounts.contains(account) else { return }
        let now = clock.now
        if let last = lastRenewAt[account], now.timeIntervalSince(last) < dedupeInterval { return }
        attemptedRenewal.insert(account)
        nextRenewal[account] = nil
        let trigger: Trigger = bootstrapAttempt ? .bootstrap : .scheduled
        let crashSafeNotBefore = now.addingTimeInterval(bootstrapCooldown)
        bootstrapNotBefore[account] = crashSafeNotBefore
        cooldownBootstrapOrigins[account] = bootstrapAttempt
        onRecoveryState?(
            account,
            .cooldown(
                notBefore: crashSafeNotBefore,
                bootstrapOrigin: bootstrapAttempt
            )
        )
        let dispatchedRevision = accountRevisions[account]
        inFlightAccounts.insert(account)
        let outcome = await onRenew?(account, trigger) ?? .completed
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
            onRecoveryState?(
                account,
                .cooldown(
                    notBefore: staleNotBefore,
                    bootstrapOrigin: bootstrapAttempt
                )
            )
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
            onRecoveryState?(
                account,
                .retry(
                    notBefore: retryAt,
                    attempt: attempt,
                    bootstrapOrigin: bootstrapAttempt
                )
            )
            return
        case .needsAttention:
            clearRetry(for: account)
            needsAttentionAccounts.insert(account)
            attemptedRenewal.remove(account)
            bootstrapNotBefore[account] = nil
            cooldownBootstrapOrigins[account] = nil
            nextRenewal[account] = nil
            onRecoveryState?(
                account,
                .needsAttention(bootstrapOrigin: bootstrapAttempt)
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
        onRecoveryState?(
            account,
            .cooldown(
                notBefore: handoffNotBefore,
                bootstrapOrigin: bootstrapAttempt
            )
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
        onRecoveryState?(account, nil)
    }

    private func quotaWindowState(for account: URL) async -> QuotaWindowState {
        let provider = accountProviders[account]
            ?? Provider.detect(at: account)
            ?? .claude
        return await detector.quotaWindowState(
            account: account,
            provider: provider
        )
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
