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
    private let responseFileWriter: ResponseFileWriting
    private let clock: Clock
    private let preparer: DispatchPreparer
    /// Execuções da mesma conta são serializadas; contas diferentes podem
    /// avançar em paralelo. O estado anterior era um único `isRunning` global
    /// que descartava silenciosamente qualquer disparo concorrente.
    private enum ExecutionKey: Hashable {
        case provider(Provider, account: URL)
        case shell(workingDirectory: URL?)

        static func resolve(_ dispatch: PreparedDispatch) -> ExecutionKey {
            switch dispatch.target {
            case .provider(let plan):
                return .provider(
                    plan.account.provider,
                    account: plan.account.configDirectory
                )
            case .shell(let workingDirectory):
                return .shell(workingDirectory: workingDirectory)
            }
        }
    }
    private var runningKeys: Set<ExecutionKey> = []
    private struct ExecutionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var executionWaiters: [ExecutionKey: [ExecutionWaiter]] = [:]
    private let log = Logger(subsystem: "io.github.hayashirafael.Ohayo", category: "fire")

    static let responseLimit = 4000

    init(state: AppState, detector: SessionDetecting, runner: CommandRunning,
         terminalLauncher: TerminalLaunching? = nil,
         notifier: Notifying, clock: Clock = SystemClock(),
         authenticationChecker: AuthenticationChecking = AllowAllAuthenticationChecker(),
         preparer: DispatchPreparer? = nil,
         responseFileWriter: ResponseFileWriting =
             SystemResponseFileWriter()) {
        self.state = state
        self.detector = detector
        self.runner = runner
        self.terminalLauncher = terminalLauncher
        self.authenticationChecker = authenticationChecker
        self.notifier = notifier
        self.responseFileWriter = responseFileWriter
        self.clock = clock
        self.preparer = preparer ?? DispatchPreparer(
            homeDirectory: state.dispatchHomeDirectory
        )
    }

    /// Retorna um outcome de domínio para os motores distinguirem conclusão,
    /// hand-off, ação humana e falha transitória. Disparos concorrentes da
    /// mesma conta aguardam sua vez em vez de serem perdidos.
    @discardableResult
    func fire(_ intent: DispatchIntent) async -> DispatchOutcome {
        switch preparer.prepare(intent) {
        case .success(let dispatch):
            return await fire(
                dispatch,
                scheduledSnapshot: Self.scheduledSnapshot(for: intent)
            )
        case .failure(let error):
            return block(intent, because: error)
        }
    }

    private func fire(
        _ dispatch: PreparedDispatch,
        scheduledSnapshot: ScheduledTask?
    ) async -> DispatchOutcome {
        let message = dispatch.message
        let origin = dispatch.origin
        let taskName = dispatch.taskName
        let accountDir = dispatch.accountDirectory
        let account = accountDir?.lastPathComponent ?? "shell"
        var eventMessage = message
        if let accountDir {
            // Histórico consome a mesma Account já canonicalizada que quota,
            // autenticação e adapters; nunca reinfere `configDir` cru.
            eventMessage.configDir = accountDir.path
        }
        let executionKey = ExecutionKey.resolve(dispatch)
        guard await acquireExecutionSlot(for: executionKey) else {
            log.info("fire: descartado — espera cancelada")
            return .paused
        }
        defer { releaseExecutionSlot(for: executionKey) }

        guard canContinue(
            scheduledSnapshot,
            origin: origin
        ) else {
            log.info(
                "fire: descartado — cancelado ou agendamento mudou"
            )
            return .paused
        }

        // Conta pausada: descarta sem executar nem registrar. O outcome
        // `.paused` avança a agenda — ao retomar, vale só o próximo evento da
        // cadeia (nunca catch-up retroativo do que foi pausado).
        // Exceção: disparo manual (.manual) sobrepõe a pausa — é ação explícita
        // do usuário na tela ("Executar agora"), que sempre executa (mesma
        // semântica do shell, que nunca é pausado).
        if origin != .manual,
           let accountDir,
           state.isPaused(accountDir) {
            log.info("fire: descartado — conta pausada origin=\(String(describing: origin), privacy: .public) conta=\(account, privacy: .public)")
            return .paused
        }

        log.info("fire: inicio origin=\(String(describing: origin), privacy: .public) conta=\(account, privacy: .public) msg=\(message.text, privacy: .private)")

        // Só a renovação contínua evita um disparo redundante. Horários fixos
        // são compromissos de execução (inclusive no batch com resposta) e
        // devem rodar mesmo quando a conta já tem uma janela ativa.
        if origin == .renewal,
           let accountDir,
           let provider = dispatch.provider {
            let quotaState = await detector.quotaWindowState(
                account: accountDir,
                provider: provider
            )
            guard canContinue(
                scheduledSnapshot,
                origin: origin,
                account: accountDir
            ) else {
                log.info(
                    "fire: descartado — agendamento mudou durante quota"
                )
                return .paused
            }
            switch quotaState {
            case .active(let end):
                log.info("fire: renovacao pulada (janela ativa ate \(String(describing: end), privacy: .public)) conta=\(account, privacy: .public)")
                state.recordEvent(state.makeEvent(date: clock.now,
                                                  result: .skipped(activeUntil: end),
                                                  message: eventMessage, origin: origin))
                return .skipped
            case .unavailable(let reason):
                let summary = state.strings.quotaUnavailableEvent
                log.error("fire: quota indisponivel, disparo bloqueado motivo=\(reason, privacy: .private)")
                state.recordEvent(state.makeEvent(
                    date: clock.now,
                    result: .failure(message: summary),
                    message: eventMessage,
                    origin: origin
                ))
                notifyFailure(detail: summary)
                return .needsAttention
            case .inactive:
                break
            }
        }

        if let accountContext = dispatch.account {
            let authenticationStatus =
                await authenticationChecker.status(for: accountContext)
            guard canContinue(
                scheduledSnapshot,
                origin: origin,
                account: accountContext.configDirectory
            ) else {
                log.info(
                    "fire: descartado — agendamento mudou durante autenticação"
                )
                return .paused
            }
            switch authenticationStatus {
            case .authenticated, .unknown:
                break
            case .unauthenticated(let log):
                let summary = state.strings.authenticationRequired(
                    accountContext.provider,
                    configDir: accountContext.configDirectory
                )
                state.recordEvent(state.makeEvent(date: clock.now,
                                                  result: .failure(message: summary),
                                                  message: eventMessage, origin: origin,
                                                  response: log.isEmpty ? nil : String(log.prefix(Self.responseLimit))))
                if origin != .manual {
                    notifyFailure(detail: summary)
                }
                return .needsAttention
            }
        }

        if message.resolvedRunInTerminal, let terminalLauncher {
            let outcome: DispatchOutcome
            switch await terminalLauncher.launch(dispatch) {
            case .success:
                log.info("fire: launch terminal ok conta=\(account, privacy: .public)")
                if let provider = dispatch.provider {
                    state.cliFound[provider] = true
                }
                // Abrir o Terminal comprova apenas o hand-off interativo. O
                // Ohayo não observa o exit status dessa sessão e, portanto,
                // não pode declarar sucesso nem emitir notifyOnSuccess.
                state.recordEvent(state.makeEvent(date: clock.now, result: .launched,
                                                  message: eventMessage, origin: origin))
                outcome = .launched
            case .failure(let error):
                if case .cliNotFound(let provider) = error { state.cliFound[provider] = false }
                let summary = error.userMessage(language: state.language)
                log.error("fire: launch terminal falhou: \(summary, privacy: .public)")
                state.recordEvent(state.makeEvent(date: clock.now,
                                                  result: .failure(message: summary),
                                                  message: eventMessage, origin: origin))
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
        switch await runner.run(dispatch) {
        case .success(let output):
            log.info("fire: runner ok conta=\(account, privacy: .public)")
            if let provider = dispatch.provider {
                state.cliFound[provider] = true
            }
            let response = message.resolvedShowResponse && !output.isEmpty
                ? String(output.prefix(Self.responseLimit)) : nil
            var responseFilePath: String?
            var responseFileError: String?
            let exportsResponseFile =
                response != nil && message.kind != .shell
            let responseFileFormat = exportsResponseFile
                ? message.resolvedResponseFileFormat : nil
            if exportsResponseFile {
                let directory = responseDirectory(for: message)
                switch await responseFileWriter.write(
                    response: output,
                    format: message.resolvedResponseFileFormat,
                    directory: directory,
                    taskName: taskName,
                    fallbackName: state.strings.responseFileDefaultName,
                    date: clock.now
                ) {
                case .success(let file):
                    responseFilePath = file.standardizedFileURL.path
                case .failure(.failed(let detail)):
                    responseFileError = detail
                }
            }
            state.recordEvent(state.makeEvent(date: clock.now, result: .success,
                                              message: eventMessage, origin: origin,
                                              response: response,
                                              responseFileFormat: responseFileFormat,
                                              responseFilePath: responseFilePath,
                                              responseFileError: responseFileError))
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
                notifySuccess(
                    message: message,
                    taskName: taskName,
                    accountDir: accountDir
                )
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
                                              message: eventMessage, origin: origin,
                                              response: detail))
            if origin != .manual {
                notifyFailure(detail: summary)
            }
            outcome = Self.dispatchOutcome(for: error)
        }
        return outcome
    }

    private func responseDirectory(for message: Message) -> URL {
        guard let path = message.responseDirectory,
              !path.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return AppPaths.responsesDirectory(
                home: state.dispatchHomeDirectory
            )
        }
        return URL(
            fileURLWithPath:
                NSString(string: path).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }

    private static func scheduledSnapshot(
        for intent: DispatchIntent
    ) -> ScheduledTask? {
        switch intent {
        case .agenda(let task), .renewal(let task):
            return task
        case .manual, .direct:
            return nil
        }
    }

    private func isStillCurrent(
        _ snapshot: ScheduledTask?,
        origin: FireOrigin
    ) -> Bool {
        guard let snapshot else { return true }
        let matches = state.tasks.filter { $0.uid == snapshot.uid }
        guard matches.count == 1,
              let current = matches.first,
              current.enabled,
              current == snapshot else {
            return false
        }
        switch origin {
        case .agenda:
            return current.repetition == .fixed
        case .renewal:
            return current.repetition == .continuous
        case .manual, .scheduled:
            return true
        }
    }

    private func canContinue(
        _ snapshot: ScheduledTask?,
        origin: FireOrigin,
        account: URL? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              isStillCurrent(snapshot, origin: origin) else {
            return false
        }
        guard origin != .manual,
              let account else {
            return true
        }
        return !state.isPaused(account)
    }

    private func block(
        _ intent: DispatchIntent,
        because error: DispatchPreparationError
    ) -> DispatchOutcome {
        let payload = intent.payload
        let summary: String
        switch error {
        case .explicitAccountMissing:
            summary = state.strings.accountFolderMissingEvent
        case .continuousShell:
            summary = state.strings.continuousShellInvalidEvent
        }
        log.error(
            "fire: preparação bloqueada origin=\(String(describing: payload.origin), privacy: .public)"
        )
        state.recordEvent(state.makeEvent(
            date: clock.now,
            result: .failure(message: summary),
            message: payload.message,
            origin: payload.origin
        ))
        return .needsAttention
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
    private func acquireExecutionSlot(for key: ExecutionKey) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard runningKeys.contains(key) else {
            runningKeys.insert(key)
            return true
        }
        log.info("fire: aguardando execucao anterior da mesma conta")
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                executionWaiters[key, default: []].append(
                    ExecutionWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelExecutionWaiter(waiterID, for: key)
            }
        }
    }

    private func cancelExecutionWaiter(
        _ id: UUID,
        for key: ExecutionKey
    ) {
        guard var waiters = executionWaiters[key],
              let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let cancelled = waiters.remove(at: index)
        executionWaiters[key] = waiters.isEmpty ? nil : waiters
        cancelled.continuation.resume(returning: false)
    }

    private func releaseExecutionSlot(for key: ExecutionKey) {
        if var waiters = executionWaiters[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                executionWaiters[key] = nil
            } else {
                executionWaiters[key] = waiters
            }
            next.continuation.resume(returning: true)
        } else {
            runningKeys.remove(key)
        }
    }

    /// Notificação opt-in de sucesso (notifyOnSuccess): título com o nome da
    /// tarefa (fallback no texto do comando), corpo "conta · HH:MM · resultado".
    /// Sem gate por origem — a flag é opt-in explícito por tarefa; a contínua
    /// notifica a cada renovação efetiva, nunca nos skips (sem hook lá).
    private func notifySuccess(
        message: Message,
        taskName: String?,
        accountDir: URL?
    ) {
        let accountLabel = accountDir.map { state.label(for: $0) }
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
    func status(
        for account: ProviderAccountContext
    ) async -> AuthenticationStatus {
        .authenticated
    }
}
