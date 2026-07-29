import AppKit
import Combine
import Foundation
import os

/// Composição: cria as unidades, liga o engine ao controller e observa
/// wake do sleep e mudança do relógio do sistema.
@MainActor
final class AppEnvironment: ObservableObject {
    let state: AppState
    /// Observabilidade: log de decisões e mudanças de estado deste ambiente.
    private let log = Logger(subsystem: "io.github.hayashirafael.Ohayo", category: "env")
    private let controller: FireController
    private let detector: SessionDetecting
    private let renewalEngine: RenewalEngine
    private let taskScheduler: TaskScheduler
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var statusTimer: Timer?
    /// Evita que um tick lento (por exemplo, ao ler transcripts grandes)
    /// sobreponha o próximo disparo do Timer e publique um snapshot antigo.
    private var statusTickInProgress = false
    /// O painel e o tick podem pedir a mesma confirmação de janela ao mesmo
    /// tempo. Uma única leitura é suficiente; a próxima manutenção revalida.
    private var windowRefreshInProgress = false
    private var windowRefreshRequested = false
    /// Última reconfiguração agendada — os testes aguardam via `.value`.
    private(set) var reconfigureTask: Task<Void, Never>?
    /// Garante last-write-wins quando uma configuração antiga fica suspensa
    /// em um bootstrap enquanto a pessoa edita/remove tarefas.
    private var reconfigureGeneration: UInt = 0
    /// Snapshot da disponibilidade dos alvos contínuos. Mudanças no
    /// filesystem não publicam `$tasks`; status/wake usam este mapa para
    /// reincluir uma conta quando um volume volta (ou retirá-la quando some).
    private var continuousAccountAvailability: [UUID: Bool] = [:]
    /// Último catch-up de wake/clock-change — exposto apenas como seam
    /// determinístico para testes aguardarem a operação real, sem sleeps.
    private(set) var wakeTask: Task<Void, Never>?

    /// Parâmetros injetáveis só para teste (nil = produção).
    /// `probeCLIs: false` pula a sonda de launch (spawna login shell).
    init(state: AppState? = nil,
         taskScheduler: TaskScheduler? = nil,
         detector: SessionDetecting = SessionDetector(),
         terminalLauncher: TerminalLaunching = TerminalLauncher(),
         runner: CommandRunning = CommandRunner(),
         notifier: Notifying = SystemNotifier(),
         authenticationChecker: AuthenticationChecking = CLIAuthenticationChecker(),
         probeCLIs: Bool = true) {
        // Depois de o lock de instância ser adquirido, nenhum script de outro
        // Ohayo ainda está sendo entregue. Resíduos de crash podem ser
        // desvinculados imediatamente (sessões já abertas mantêm o fd).
        TerminalLauncher.cleanupStaleScripts(olderThan: 0)
        let state = state ?? AppState()
        let taskScheduler = taskScheduler ?? TaskScheduler()
        let detector = detector
        self.state = state
        self.detector = detector
        self.controller = FireController(state: state, detector: detector,
                                         runner: runner,
                                         terminalLauncher: terminalLauncher,
                                         notifier: notifier,
                                         authenticationChecker: authenticationChecker)
        self.renewalEngine = RenewalEngine(detector: detector)
        self.taskScheduler = taskScheduler

        renewalEngine.onRenew = { [weak self] account, trigger in
            guard let self else { return .paused }
            return await self.dispatchRenewal(
                account: account,
                trigger: trigger
            )
        }
        renewalEngine.onStatus = { [weak self] next in
            self?.state.nextRenewals = next
        }
        renewalEngine.onQuotaUnavailable = { [weak self] reasons in
            self?.state.quotaUnavailableReasons = reasons
        }
        renewalEngine.onNeedsAttention = { [weak self] accounts in
            self?.state.renewalNeedsAttention = accounts
        }
        renewalEngine.onRecoveryState = { [weak self] account, recovery in
            guard let self else { return }
            let matches = self.state.tasks.filter {
                $0.enabled && $0.repetition == .continuous
                    && self.state.accountDir(for: $0) == account
            }
            guard matches.count == 1, let task = matches.first else { return }
            self.state.setRenewalRecoveryState(recovery, for: task)
        }

        taskScheduler.onFire = { [weak self] task in
            guard let self else { return false }
            let cmd = task.resolvedCommand
            // Conta explícita cuja pasta sumiu: não dispara (cairia na conta
            // padrão errada); registra a falha para a UI avisar.
            if cmd.kind != .shell, let path = cmd.configDir, !path.isEmpty,
               self.state.accountDir(for: task) == nil {
                self.state.recordEvent(self.state.makeEvent(
                    date: Date(), result: .failure(message: self.state.strings.accountFolderMissingEvent),
                    message: cmd, origin: .agenda))
                return true
            }
            let outcome = await self.controller.fire(
                message: cmd, origin: .agenda, taskName: task.name)
            return outcome.advancesSchedule
        }
        taskScheduler.onStatus = { [weak self] next in
            self?.state.nextTaskFires = next
        }

        // Sonda dos CLIs fora da thread principal: quando `claude`/`codex` não
        // estão nos candidatos padrão, `locate()` faz spawn de um shell de
        // login (`command -v ...`) — um stall real no launch. `cliFound` já
        // começa `true` para os dois, então o ícone de erro não pisca enquanto
        // isso resolve.
        if probeCLIs {
            Task.detached {
                let claude = CommandRunner.locate(.claude) != nil
                let codex = CommandRunner.locate(.codex) != nil
                await MainActor.run {
                    state.cliFound[.claude] = claude
                    state.cliFound[.codex] = codex
                }
            }
        }
        // O wake de launch é agendado antes da primeira configuração
        // assíncrona. Sem semear este snapshot, ele interpreta o estado
        // inicial como uma mudança de filesystem, invalida a configuração
        // recém-criada e pode adiar o primeiro bootstrap/retry.
        continuousAccountAvailability =
            currentContinuousAccountAvailability()
        // Ocorrências fixas que passaram com o app fechado: só registra no
        // histórico (nunca dispara retroativamente entre launches); depois
        // marca o heartbeat deste launch.
        state.recordMissedWhileClosed()
        state.recordAlive()
        scheduleWakeHandling() // catch-up do boot via mesmo caminho do wake/clock-change

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleWakeHandling() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleWakeHandling() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleWakeHandling() }
        })

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.statusTick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer

        // Editar a lista de agendamentos reconfigura os dois motores.
        state.$tasks
            .dropFirst()
            .sink { [weak self] _ in self?.reconfigureSchedules() }
            .store(in: &cancellables)
        state.$pausedAccounts
            .dropFirst()
            .sink { [weak self] _ in self?.reconfigureSchedules() }
            .store(in: &cancellables)
        reconfigureSchedules()
    }

    /// Último guard antes de entregar uma renovação. Mantido como método
    /// separado para testar as corridas entre edição/pausa e um timer que já
    /// entrou no MainActor.
    func dispatchRenewal(
        account: URL,
        trigger: RenewalEngine.Trigger
    ) async -> DispatchOutcome {
        guard !state.isPaused(account) else { return .paused }
        let matches = state.tasks.filter {
            $0.enabled && $0.repetition == .continuous
                && state.accountDir(for: $0) == account
        }
        // Payload legado/corrompido pode conter dois contínuos na mesma
        // conta. Nunca deixa o consentimento de um disparar o comando do
        // outro; a UI continua disponível para a pessoa corrigir o conflito.
        guard matches.count == 1, let task = matches.first else {
            return .needsAttention
        }
        if trigger == .bootstrap {
            // O setter da task publica antes de o reconfigure assíncrono
            // retirar a conta do engine. Revalida a escolha no limite do
            // dispatch para fechar essa janela de corrida.
            guard task.resolvedBootstrapWhenInactive else { return .paused }
        }
        let outcome = await controller.fire(
            message: task.resolvedCommand,
            origin: .renewal,
            taskName: task.name
        )
        return outcome
    }

    /// Disparo manual imediato de um agendamento (botão "Executar agora" da
    /// tela Horários). Origem `.manual`: nunca pula por janela ativa, sobrepõe
    /// a pausa da conta (ação explícita do usuário sempre executa) e não emite
    /// notificação de falha (o usuário está olhando a tela). Replica o guard de
    /// pasta ausente do `taskScheduler.onFire` — conta explícita cuja pasta
    /// sumiu não dispara (cairia na conta padrão errada).
    func fireNow(_ task: ScheduledTask) async {
        let cmd = task.resolvedCommand
        if cmd.kind != .shell, let path = cmd.configDir, !path.isEmpty,
           state.accountDir(for: task) == nil {
            log.error("fireNow: pasta da conta ausente uid=\(task.uid, privacy: .public)")
            state.recordEvent(state.makeEvent(
                date: Date(), result: .failure(message: state.strings.accountFolderMissingEvent),
                message: cmd, origin: .manual))
            return
        }
        log.info("fireNow: disparo manual uid=\(task.uid, privacy: .public)")
        await controller.fire(message: cmd, origin: .manual, taskName: task.name)
    }

    /// Reconfigura os dois motores a partir da lista unificada: contínuos
    /// alimentam o RenewalEngine (por conta), fixos o TaskScheduler.
    private func reconfigureSchedules() {
        reconfigureGeneration &+= 1
        let generation = reconfigureGeneration
        // TODAS as leituras de `state` ficam DENTRO do Task: o sink de
        // `$tasks` dispara no willSet (@Published publica antes de gravar o
        // valor), então uma leitura síncrona aqui veria a lista ANTIGA e os
        // motores ficariam um passo atrás — tarefa recém-criada nunca armava.
        // Quando o Task roda na MainActor, o setter já completou.
        reconfigureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard generation == self.reconfigureGeneration else { return }
            // Contínuo com pasta ausente não entra no set (nunca arma);
            // registra a falha no histórico, uma vez, para paridade com o
            // caminho fixo.
            self.state.recordMissingFolderContinuous()
            var continuousByAccount: [URL: [ScheduledTask]] = [:]
            for task in self.state.tasks
                where task.enabled && task.repetition == .continuous {
                if let dir = self.state.accountDir(for: task),
                   !self.state.isPaused(dir) {
                    continuousByAccount[dir, default: []].append(task)
                }
            }
            var accounts: Set<URL> = []
            var bootstrapAccounts: Set<URL> = []
            var recoveryStates: [URL: RenewalRecoveryState] = [:]
            var accountRevisions: [URL: String] = [:]
            var accountProviders: [URL: Provider] = [:]
            self.continuousAccountAvailability =
                self.currentContinuousAccountAvailability()
            for (dir, tasks) in continuousByAccount where tasks.count == 1 {
                accounts.insert(dir)
                if let task = tasks.first {
                    accountRevisions[dir] = task.renewalRevision
                    accountProviders[dir] =
                        task.resolvedCommand.kind == .codex
                        ? .codex
                        : .claude
                    if task.resolvedBootstrapWhenInactive {
                        // Este set representa consentimento, não elegibilidade.
                        bootstrapAccounts.insert(dir)
                    }
                    if let recovery =
                        self.state.renewalRecoveryState(for: task) {
                        recoveryStates[dir] = recovery
                    }
                }
            }
            let fixed = self.state.tasks.filter { task in
                guard task.repetition == .fixed else { return false }
                guard let dir = self.state.accountDir(for: task) else {
                    // Shell e pasta explícita ausente continuam no scheduler:
                    // o primeiro executa normalmente; a segunda registra a
                    // falha sem cair na conta padrão.
                    return true
                }
                return !self.state.isPaused(dir)
            }
            self.log.info("reconfigure: fixos=\(fixed.count, privacy: .public) continuos=\(accounts.count, privacy: .public)")
            // A agenda fixa é independente do bootstrap contínuo. Aplicá-la
            // primeiro impede que um dispatch longo atrase remoções/edições;
            // o próprio scheduler protege callbacks em voo por ocorrência.
            await self.taskScheduler.configure(tasks: fixed, paused: false)
            guard generation == self.reconfigureGeneration else { return }
            // O pause agora é por conta e aplicado no FireController; os engines
            // nunca pausam globalmente (o parâmetro fica para os testes).
            await self.renewalEngine.configure(
                accounts: accounts,
                bootstrapAccounts: bootstrapAccounts,
                recoveryStates: recoveryStates,
                accountRevisions: accountRevisions,
                accountProviders: accountProviders,
                paused: false
            )
            guard generation == self.reconfigureGeneration else { return }
            // `refreshWindowEnds` usa o deadline já classificado pelo engine.
            // Fazer a confirmação aqui fecha o launch/edição sem esperar o
            // primeiro tick periódico e sem reler contas inativas.
            await self.refreshWindowEnds()
        }
    }

    /// Tick periódico: re-arma as renovações e a agenda, atualiza a evidência
    /// real de janelas e só então publica o pulso usado pela UI.
    func statusTick() async {
        guard !statusTickInProgress else { return }
        statusTickInProgress = true
        defer { statusTickInProgress = false }

        state.recordAlive()
        reconfigureIfAccountAvailabilityChanged()
        await renewalEngine.rearmAll()
        await taskScheduler.rearmAll()
        await refreshWindowEnds()
        // Publica um pulso mesmo quando `rearmAll` não mutou os snapshots
        // (early-return com timer já armado): sem isso o menu não reconstrói e
        // os horários calculados com `Date()` ficam congelados.
        state.pulseUI()
    }

    /// Confirma como janela ativa apenas deadlines contínuos que o
    /// `RenewalEngine` acabou de detectar. Contas inativas já foram lidas pelo
    /// engine no mesmo ciclo; não as varrer de novo evita duplicar I/O e parse
    /// de transcripts a cada minuto. Fixos e contas pausadas não participam da
    /// saúde da janela contínua.
    func refreshWindowEnds() async {
        guard !windowRefreshInProgress else {
            windowRefreshRequested = true
            return
        }
        windowRefreshInProgress = true
        defer { windowRefreshInProgress = false }

        repeat {
            windowRefreshRequested = false
            let now = Date()
            let accounts = activeContinuousAccounts()
            let accountSet = Set(accounts)
            var result = state.windowEnds.filter {
                accountSet.contains($0.key.standardizedFileURL) && $0.value > now
            }
            for dir in accounts where result[dir] == nil {
                // `nextRenewals` também pode conter retry/cooldown, por isso o
                // detector ainda confirma a evidência antes de preencher o glifo.
                guard let candidate = state.nextRenewals[dir], candidate > now else {
                    continue
                }
                switch await detector.quotaWindowState(
                    account: dir,
                    provider: state.provider(for: dir)
                ) {
                case .active(let end) where end > now:
                    result[dir] = end
                case .active, .inactive, .unavailable:
                    break
                }
            }
            // Uma edição pode ter ocorrido enquanto o detector estava
            // suspenso. Não publica contas antigas; refaz com o snapshot novo.
            if accounts != activeContinuousAccounts() {
                windowRefreshRequested = true
                continue
            }
            state.windowEnds = result
        } while windowRefreshRequested
    }

    /// Contas realmente gerenciadas pelo fluxo contínuo. Mantém a mesma
    /// exclusão de pausas, shell e conflitos usada na reconfiguração do engine.
    private func activeContinuousAccounts() -> [URL] {
        var tasksByAccount: [URL: Int] = [:]
        for task in state.tasks
            where task.enabled
                && task.repetition == .continuous
                && task.resolvedCommand.kind != .shell {
            guard let dir = state.accountDir(for: task), !state.isPaused(dir) else {
                continue
            }
            tasksByAccount[dir.standardizedFileURL, default: 0] += 1
        }
        return tasksByAccount
            .filter { $0.value == 1 }
            .map(\.key)
            .sorted { $0.path < $1.path }
    }

    /// Executa o catch-up agora. Mantido como seam interno para testes
    /// determinísticos; observers e launch o agendam por
    /// `scheduleWakeHandling()`.
    func handleWake() async {
        log.info("wake/clock-change: reconfigurando catch-up")
        reconfigureIfAccountAvailabilityChanged()
        await renewalEngine.handleWake()
        await taskScheduler.handleWake()
    }

    private func reconfigureIfAccountAvailabilityChanged() {
        let current = currentContinuousAccountAvailability()
        if current != continuousAccountAvailability {
            reconfigureSchedules()
        }
    }

    private func currentContinuousAccountAvailability() -> [UUID: Bool] {
        var current: [UUID: Bool] = [:]
        for task in state.tasks
            where task.enabled
                && task.repetition == .continuous
                && task.resolvedCommand.kind != .shell {
            current[task.uid] = state.accountDir(for: task) != nil
        }
        return current
    }

    private func scheduleWakeHandling() {
        wakeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleWake()
            await self.refreshWindowEnds()
        }
    }
}
