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
    private let renewalEngine: RenewalEngine
    private let taskScheduler: TaskScheduler
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var statusTimer: Timer?
    /// Última reconfiguração agendada — os testes aguardam via `.value`.
    private(set) var reconfigureTask: Task<Void, Never>?
    /// Garante last-write-wins quando uma configuração antiga fica suspensa
    /// em um bootstrap enquanto a pessoa edita/remove tarefas.
    private var reconfigureGeneration: UInt = 0
    /// Último catch-up de wake/clock-change — exposto apenas como seam
    /// determinístico para testes aguardarem a operação real, sem sleeps.
    private(set) var wakeTask: Task<Void, Never>?

    /// Parâmetros injetáveis só para teste (nil = produção).
    /// `probeCLIs: false` pula a sonda de launch (spawna login shell).
    init(state: AppState? = nil,
         taskScheduler: TaskScheduler? = nil,
         detector: SessionDetecting = SessionDetector(),
         terminalLauncher: TerminalLaunching = TerminalLauncher(),
         runner: CommandRunning = CommandRunner.live(),
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
        let controller = FireController(
            state: state,
            detector: detector,
            runner: runner,
            terminalLauncher: terminalLauncher,
            notifier: notifier,
            authenticationChecker: authenticationChecker
        )
        self.controller = controller
        self.renewalEngine = RenewalEngine(
            detector: detector,
            dispatch: { task, trigger in
                guard let account = state.accountDir(for: task),
                      !state.isPaused(account) else {
                    return .paused
                }
                let matches = state.tasks.filter {
                    $0.enabled
                        && $0.repetition == .continuous
                        && state.accountDir(for: $0) == account
                }
                guard matches.count == 1,
                      let current = matches.first,
                      current.uid == task.uid,
                      current.renewalRevision
                        == task.renewalRevision else {
                    return .needsAttention
                }
                if trigger == .bootstrap,
                   !current.resolvedBootstrapWhenInactive {
                    return .paused
                }
                return await controller.fire(.renewal(current))
            },
            persistRecovery: { task, recovery in
                let matches = state.tasks.filter { current in
                    current.uid == task.uid
                        && current.enabled
                        && current.repetition == .continuous
                        && current.renewalRevision == task.renewalRevision
                        && state.intendedAccountDir(for: current)
                            == state.intendedAccountDir(for: task)
                }
                guard matches.count == 1,
                      let current = matches.first else {
                    return
                }
                state.setRenewalRecoveryState(recovery, for: current)
            }
        )
        self.taskScheduler = taskScheduler

        renewalEngine.$snapshot
            .sink { [weak state] snapshot in
                state?.renewalSnapshot = snapshot
            }
            .store(in: &cancellables)

        taskScheduler.onFire = { [weak self] task in
            guard let self else { return false }
            let outcome = await self.controller.fire(.agenda(task))
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

    /// Disparo manual imediato de um agendamento (botão "Executar agora" da
    /// tela Horários). Origem `.manual`: nunca pula por janela ativa, sobrepõe
    /// a pausa da conta (ação explícita do usuário sempre executa) e não emite
    /// notificação de falha (o usuário está olhando a tela). A preparação do
    /// dispatch mantém a Account explícita fail-closed.
    func fireNow(_ task: ScheduledTask) async {
        log.info("fireNow: disparo manual uid=\(task.uid, privacy: .public)")
        await controller.fire(.manual(task))
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
            let continuous = self.continuousScheduleInput()
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
            self.log.info("reconfigure: fixos=\(fixed.count, privacy: .public) continuos=\(continuous.definitions.count, privacy: .public)")
            // A agenda fixa é independente do bootstrap contínuo. Aplicá-la
            // primeiro impede que um dispatch longo atrase remoções/edições;
            // o próprio scheduler protege callbacks em voo por ocorrência.
            await self.taskScheduler.configure(tasks: fixed, paused: false)
            guard generation == self.reconfigureGeneration else { return }
            await self.renewalEngine.synchronize(continuous)
        }
    }

    /// Tick periódico: re-arma as renovações e a agenda (alimenta ícone e "3h12" na barra).
    func statusTick() async {
        state.recordAlive()
        state.recordMissingFolderContinuous()
        await renewalEngine.synchronize(continuousScheduleInput())
        await taskScheduler.rearmAll()
        // Publica um pulso mesmo quando `rearmAll` não mutou os snapshots
        // (early-return com timer já armado): sem isso o menu não reconstrói e
        // os horários calculados com `Date()` ficam congelados.
        state.pulseUI()
    }

    /// Executa o catch-up agora. Mantido como seam interno para testes
    /// determinísticos; observers e launch o agendam por
    /// `scheduleWakeHandling()`.
    func handleWake() async {
        log.info("wake/clock-change: reconfigurando catch-up")
        state.recordMissingFolderContinuous()
        await renewalEngine.synchronize(continuousScheduleInput())
        await taskScheduler.handleWake()
    }

    private func continuousScheduleInput() -> ContinuousScheduleInput {
        ContinuousScheduleInput(
            definitions: state.tasks.compactMap { task in
                guard task.enabled,
                      task.repetition == .continuous else {
                    return nil
                }
                let intended = state.intendedAccountDir(for: task)
                return ContinuousScheduleDefinition(
                    task: task,
                    intendedAccount: intended,
                    availableAccount: state.accountDir(for: task),
                    paused: intended.map(state.isPaused) ?? false,
                    recovery: state.renewalRecoveryState(for: task)
                )
            }
        )
    }

    private func scheduleWakeHandling() {
        wakeTask = Task { @MainActor [weak self] in
            await self?.handleWake()
        }
    }
}
