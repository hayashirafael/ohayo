import Foundation
import os

protocol Notifying {
    func notifyFailure(title: String, message: String)
    func notifyResponse(title: String, response: String)
    func notifySuccess(title: String, body: String)
}

/// Orquestra um disparo: renovação redundante pode pular; demais origens
/// executam e registram o resultado em AppState.
@MainActor
final class FireController {
    private let state: AppState
    private let detector: SessionDetecting
    private let runner: CommandRunning
    private let terminalLauncher: TerminalLaunching?
    private let authenticationChecker: AuthenticationChecking
    private let notifier: Notifying
    private let clock: Clock
    /// Execuções da mesma conta são serializadas; contas diferentes podem
    /// avançar em paralelo. O estado anterior era um único `isRunning` global
    /// que descartava silenciosamente qualquer disparo concorrente.
    private enum ExecutionKey: Hashable {
        case provider(Provider, account: URL)
        case shell(workingDirectory: URL?)

        static func resolve(message: Message, account: URL) -> ExecutionKey {
            switch message.kind {
            case .claude:
                return .provider(
                    .claude,
                    account: ProviderAccountContext.canonicalAccountDirectory(account)
                )
            case .codex:
                return .provider(
                    .codex,
                    account: ProviderAccountContext.canonicalAccountDirectory(account)
                )
            case .shell:
                guard let path = message.workingDir,
                      !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .shell(workingDirectory: nil)
                }
                let expanded = NSString(string: path).expandingTildeInPath
                return .shell(
                    workingDirectory: URL(fileURLWithPath: expanded).standardizedFileURL
                )
            }
        }
    }
    private var runningKeys: Set<ExecutionKey> = []
    private var executionWaiters: [ExecutionKey: [CheckedContinuation<Void, Never>]] = [:]
    private let log = Logger(subsystem: "io.github.hayashirafael.Ohayo", category: "fire")

    static let responseLimit = 4000

    init(state: AppState, detector: SessionDetecting, runner: CommandRunning,
         terminalLauncher: TerminalLaunching? = nil,
         notifier: Notifying, clock: Clock = SystemClock(),
         authenticationChecker: AuthenticationChecking = AllowAllAuthenticationChecker()) {
        self.state = state
        self.detector = detector
        self.runner = runner
        self.terminalLauncher = terminalLauncher
        self.authenticationChecker = authenticationChecker
        self.notifier = notifier
        self.clock = clock
    }

    /// Retorna um outcome de domínio para os motores distinguirem conclusão,
    /// hand-off, ação humana e falha transitória. Disparos concorrentes da
    /// mesma conta aguardam sua vez em vez de serem perdidos.
    @discardableResult
    func fire(message: Message, origin: FireOrigin,
              taskName: String? = nil) async -> DispatchOutcome {
        let accountDir = state.effectiveConfigDir(for: message)
        let account = accountDir.lastPathComponent
        let executionKey = ExecutionKey.resolve(message: message, account: accountDir)
        await acquireExecutionSlot(for: executionKey)
        defer { releaseExecutionSlot(for: executionKey) }

        // Conta pausada: descarta sem executar nem registrar. O outcome
        // `.paused` avança a agenda — ao retomar, vale só o próximo evento da
        // cadeia (nunca catch-up retroativo do que foi pausado).
        // Exceção: disparo manual (.manual) sobrepõe a pausa — é ação explícita
        // do usuário na tela ("Executar agora"), que sempre executa (mesma
        // semântica do shell, que nunca é pausado).
        if origin != .manual, message.kind != .shell, state.isPaused(accountDir) {
            log.info("fire: descartado — conta pausada origin=\(String(describing: origin), privacy: .public) conta=\(account, privacy: .public)")
            return .paused
        }

        log.info("fire: inicio origin=\(String(describing: origin), privacy: .public) conta=\(account, privacy: .public) msg=\(message.text, privacy: .private)")

        // Só a renovação contínua evita um disparo redundante. Horários fixos
        // são compromissos de execução (inclusive no batch com resposta) e
        // devem rodar mesmo quando a conta já tem uma janela ativa.
        if origin == .renewal, message.kind != .shell {
            let provider: Provider =
                message.kind == .codex ? .codex : .claude
            switch await detector.quotaWindowState(
                account: accountDir,
                provider: provider
            ) {
            case .active(let end):
                log.info("fire: renovacao pulada (janela ativa ate \(String(describing: end), privacy: .public)) conta=\(account, privacy: .public)")
                state.recordEvent(state.makeEvent(date: clock.now,
                                                  result: .skipped(activeUntil: end),
                                                  message: message, origin: origin))
                return .skipped
            case .unavailable(let reason):
                let summary = state.strings.quotaUnavailableEvent
                log.error("fire: quota indisponivel, disparo bloqueado motivo=\(reason, privacy: .private)")
                state.recordEvent(state.makeEvent(
                    date: clock.now,
                    result: .failure(message: summary),
                    message: message,
                    origin: origin
                ))
                notifyFailure(detail: summary)
                return .needsAttention
            case .inactive:
                break
            }
        }

        if message.kind != .shell {
            switch await authenticationChecker.status(for: message.kind == .codex ? .codex : .claude,
                                                       configDir: accountDir) {
            case .authenticated, .unknown:
                break
            case .unauthenticated(let log):
                let provider: Provider = message.kind == .codex ? .codex : .claude
                let summary = state.strings.authenticationRequired(provider, configDir: accountDir)
                state.recordEvent(state.makeEvent(date: clock.now,
                                                  result: .failure(message: summary),
                                                  message: message, origin: origin,
                                                  response: log.isEmpty ? nil : String(log.prefix(Self.responseLimit))))
                if origin != .manual {
                    notifyFailure(detail: summary)
                }
                return .needsAttention
            }
        }

        if message.resolvedRunInTerminal, let terminalLauncher {
            let outcome: DispatchOutcome
            switch await terminalLauncher.launch(message) {
            case .success:
                log.info("fire: launch terminal ok conta=\(account, privacy: .public)")
                state.cliFound[message.kind == .codex ? .codex : .claude] = true
                // Abrir o Terminal comprova apenas o hand-off interativo. O
                // Ohayo não observa o exit status dessa sessão e, portanto,
                // não pode declarar sucesso nem emitir notifyOnSuccess.
                state.recordEvent(state.makeEvent(date: clock.now, result: .launched,
                                                  message: message, origin: origin))
                outcome = .launched
            case .failure(let error):
                if case .cliNotFound(let provider) = error { state.cliFound[provider] = false }
                let summary = error.userMessage(language: state.language)
                log.error("fire: launch terminal falhou: \(summary, privacy: .public)")
                state.recordEvent(state.makeEvent(date: clock.now,
                                                  result: .failure(message: summary),
                                                  message: message, origin: origin))
                if origin != .manual {
                    notifyFailure(detail: summary)
                }
                // Falha ao entregar a sessão ao Terminal (permissão,
                // AppleScript ou CLI ausente) exige intervenção; reabrir a
                // cada tick criaria uma sequência de janelas/alertas.
                outcome = .needsAttention
            }
            return outcome
        }

        let outcome: DispatchOutcome
        switch await runner.run(message) {
        case .success(let output):
            log.info("fire: runner ok conta=\(account, privacy: .public)")
            state.cliFound[message.kind == .codex ? .codex : .claude] = true
            let response = message.resolvedShowResponse && !output.isEmpty
                ? String(output.prefix(Self.responseLimit)) : nil
            state.recordEvent(state.makeEvent(date: clock.now, result: .success,
                                              message: message, origin: origin,
                                              response: response))
            if let response {
                // A notificação de resposta já comunica o sucesso — não duplica.
                let content = notificationContent(
                    detailedTitle: state.strings.notificationResponseTitle(message.text),
                    detailedBody: response,
                    genericTitle: state.strings.genericNotificationResponseTitle,
                    genericBody: state.strings.genericNotificationResponseBody
                )
                notifier.notifyResponse(title: content.title, response: content.body)
            } else if message.resolvedNotifyOnSuccess {
                notifySuccess(message: message, taskName: taskName, accountDir: accountDir)
            }
            outcome = .completed
        case .failure(let error):
            if case .cliNotFound(let provider) = error { state.cliFound[provider] = false }
            let summary: String
            var detail: String? = nil
            if case .failed(let full) = error {
                summary = Self.failureSummary(full)
                if full != summary {
                    let truncated = String(full.prefix(Self.responseLimit))
                    detail = full.count > Self.responseLimit
                        ? truncated + "\n[log truncated]" : truncated
                }
            } else {
                summary = error.userMessage(language: state.language)
            }
            log.error("fire: runner falhou: \(summary, privacy: .public)")
            state.recordEvent(state.makeEvent(date: clock.now,
                                              result: .failure(message: summary),
                                              message: message, origin: origin,
                                              response: detail))
            if origin != .manual {
                notifyFailure(detail: summary)
            }
            outcome = Self.dispatchOutcome(for: error)
        }
        return outcome
    }

    /// Fail closed: só falhas reconhecidamente transitórias entram no loop de
    /// retry. Modelo/configuração/permissão e exits desconhecidos exigem ação
    /// humana; tratá-los como rede causaria retries ilimitados a cada 15 min.
    static func dispatchOutcome(for error: RunnerError) -> DispatchOutcome {
        switch error {
        case .cliNotFound:
            return .needsAttention
        case .timeout:
            return .retryableFailure
        case .failed(let log):
            let transientMarkers = [
                "network", "sem rede", "connection reset", "connection refused",
                "connection timed out", "econnreset", "econnrefused", "enotfound",
                "dns", "socket", "temporarily unavailable", "service unavailable",
                "overloaded", "rate limit", "rate_limit", "too many requests",
                "try again", "http 429", "\"status\":429", "status 429",
                "internal server error", "bad gateway", "gateway timeout",
                "http 500", "http 502", "http 503", "http 504",
                "\"status\":500", "\"status\":502", "\"status\":503", "\"status\":504",
            ]
            return transientMarkers.contains {
                log.localizedCaseInsensitiveContains($0)
            } ? .retryableFailure : .needsAttention
        }
    }

    /// Entrega o slot diretamente ao primeiro waiter ao liberar, preservando
    /// FIFO sem abrir uma janela em que um terceiro disparo poderia furar fila.
    private func acquireExecutionSlot(for key: ExecutionKey) async {
        guard runningKeys.contains(key) else {
            runningKeys.insert(key)
            return
        }
        log.info("fire: aguardando execucao anterior da mesma conta")
        await withCheckedContinuation { continuation in
            executionWaiters[key, default: []].append(continuation)
        }
    }

    private func releaseExecutionSlot(for key: ExecutionKey) {
        if var waiters = executionWaiters[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                executionWaiters[key] = nil
            } else {
                executionWaiters[key] = waiters
            }
            next.resume()
        } else {
            runningKeys.remove(key)
        }
    }

    /// Notificação opt-in de sucesso (notifyOnSuccess): título com o nome da
    /// tarefa (fallback no texto do comando), corpo "conta · HH:MM · resultado".
    /// Sem gate por origem — a flag é opt-in explícito por tarefa; a contínua
    /// notifica a cada renovação efetiva, nunca nos skips (sem hook lá).
    private func notifySuccess(message: Message, taskName: String?, accountDir: URL) {
        let accountLabel = message.kind == .shell ? nil : state.label(for: accountDir)
        let content = notificationContent(
            detailedTitle: state.strings.notificationSuccessTitle(taskName ?? message.text),
            detailedBody: state.strings.notificationSuccessBody(
                account: accountLabel,
                time: Fmt.hhmm(clock.now, language: state.language)
            ),
            genericTitle: state.strings.genericNotificationSuccessTitle,
            genericBody: state.strings.genericNotificationSuccessBody
        )
        notifier.notifySuccess(title: content.title, body: content.body)
    }

    private func notifyFailure(detail: String) {
        let content = notificationContent(
            detailedTitle: state.strings.notificationFailureTitle,
            detailedBody: detail,
            genericTitle: state.strings.genericNotificationFailureTitle,
            genericBody: state.strings.genericNotificationFailureBody
        )
        notifier.notifyFailure(title: content.title, message: content.body)
    }

    private func notificationContent(
        detailedTitle: String,
        detailedBody: String,
        genericTitle: String,
        genericBody: String
    ) -> (title: String, body: String) {
        state.showSensitiveNotificationDetails
            ? (detailedTitle, detailedBody)
            : (genericTitle, genericBody)
    }

    /// Resumo de um log longo para o título do histórico: a última linha não
    /// vazia (onde CLIs imprimem o erro final), truncada — o texto completo
    /// vai em `response` e vira detalhe expansível na UI.
    static func failureSummary(_ full: String) -> String {
        let line = full.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? full
        return String(line.prefix(120))
    }
}

struct AllowAllAuthenticationChecker: AuthenticationChecking {
    func status(for provider: Provider, configDir: URL) async -> AuthenticationStatus {
        .authenticated
    }
}
