import Foundation
import os

/// Dispara tarefas da agenda em horários fixos × dias da semana. Espelho do
/// padrão do RenewalEngine: timers reais só no app; catch-up de sleep testado
/// com relógio fake. O skip por sessão ativa acontece no FireController.
@MainActor
final class TaskScheduler {
    /// Retorna `true` quando o outcome consumiu a ocorrência e `false` quando
    /// uma falha transitória deve preservar a ocorrência para retry.
    var onFire: ((ScheduledTask) async -> Bool)?
    /// Snapshot de `nextFires` a cada mudança — vira "próxima qua 08:00" na UI.
    var onStatus: (([UUID: Date]) -> Void)?

    private(set) var nextFires: [UUID: Date] = [:] {
        didSet { onStatus?(nextFires) }
    }

    /// Logger de observabilidade: só decisões e mudanças de estado, nunca o
    /// caminho quente de um tick periódico.
    private let log = Logger(subsystem: "io.github.hayashirafael.Ohayo", category: "agenda")

    private let clock: Clock
    private let calendar: Calendar
    private let retryBaseDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval = 15 * 60
    private var tasks: [UUID: ScheduledTask] = [:]
    private var paused = false
    private var timers: [UUID: Timer] = [:]
    /// Última OCORRÊNCIA da agenda que de fato disparou. Dedupe por identidade
    /// de ocorrência — nunca por janela de tempo: uma janela wall-clock maior
    /// que a granularidade de minuto engolia a ocorrência do minuto seguinte a
    /// um disparo real.
    private var lastFiredOccurrence: [UUID: Date] = [:]
    /// Piso do catch-up avançado pela EDIÇÃO da tarefa — nunca alimenta o
    /// dedupe (editar não é disparar).
    private var catchUpFloor: [UUID: Date] = [:]
    /// Falhas transitórias, com a ocorrência a re-tentar na próxima chamada
    /// depois do backoff.
    private var pendingRetry: [UUID: Date] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var retryNotBefore: [UUID: Date] = [:]
    /// A ocorrência é reservada antes do callback suspensível. Isso fecha a
    /// corrida timer + wake/statusTick enquanto um batch ainda está rodando;
    /// o FireController pode enfileirar, mas o scheduler não cria um segundo
    /// job para a mesma ocorrência.
    private var inFlightOccurrences: [UUID: Date] = [:]
    /// Launch não dispara catch-up: só ocorrências perdidas depois disso contam.
    private let startedAt: Date

    init(
        clock: Clock = SystemClock(),
        calendar: Calendar = .current,
        retryBaseDelay: TimeInterval = 60
    ) {
        self.clock = clock
        self.calendar = calendar
        self.retryBaseDelay = retryBaseDelay
        self.startedAt = clock.now
    }

    func configure(tasks list: [ScheduledTask], paused: Bool) async {
        let previousTasks = tasks
        var normalized: [UUID: ScheduledTask] = [:]
        for task in list where task.enabled { normalized[task.uid] = task }
        self.tasks = normalized
        self.paused = paused
        for uid in Array(timers.keys) where paused || normalized[uid] == nil {
            timers[uid]?.invalidate()
            timers[uid] = nil
        }
        if paused {
            nextFires = [:]
            pendingRetry.removeAll()
            retryAttempts.removeAll()
            retryNotBefore.removeAll()
        } else {
            for uid in Array(nextFires.keys) where normalized[uid] == nil {
                nextFires[uid] = nil
            }
            pendingRetry = pendingRetry.filter { normalized[$0.key] != nil }
            retryAttempts = retryAttempts.filter { normalized[$0.key] != nil }
            retryNotBefore = retryNotBefore.filter { normalized[$0.key] != nil }
            // Uid novo ou com conteúdo diferente (ex.: horário editado): o
            // timer armado aponta para o horário ANTIGO. Sem isso, `rearm` vê
            // `armed > now` com timer vivo e devolve cedo — a tarefa
            // dispararia no horário que o usuário removeu. Invalida só os
            // uids realmente novos/editados (não todo mundo a cada publish de
            // `$tasks`, o que re-armaria timers não relacionados).
            for (uid, newTask) in normalized {
                if previousTasks[uid] == newTask { continue }
                timers[uid]?.invalidate()
                timers[uid] = nil
                nextFires[uid] = nil
                clearRetry(for: uid)
                // Avança o piso do catch-up para o INÍCIO do minuto corrente
                // (−1s): sem isso, o rearm poderia achar uma ocorrência do
                // horário recém-criado/editado já perdida e disparar na hora
                // algo que o usuário acabou de configurar (catch-up retroativo
                // indesejado — criar/editar não é disparar). O piso não é
                // `clock.now` cheio porque isso esconderia a ocorrência do
                // MINUTO corrente: criar às 12:44:20 um agendamento de 12:44
                // deve disparar 12:44:00 (fluxo de quem testa "agendo pra
                // agora"). Início-do-minuto−1s pega só o minuto atual, nunca o
                // anterior. Vai em `catchUpFloor`, nunca em
                // `lastFiredOccurrence`: o dedupe olha só ocorrências que
                // dispararam de verdade (e o `max` com ele preserva o
                // não-refire de uma ocorrência já disparada neste minuto).
                let floor = (calendar.dateInterval(of: .minute, for: clock.now)?.start
                    ?? clock.now).addingTimeInterval(-1)
                catchUpFloor[uid] = floor
                log.info("configure: uid \(uid.uuidString, privacy: .public) novo/editado, catchUpFloor=\(floor, privacy: .public)")
            }
        }
        await rearmAll()
    }

    /// Chamar ao acordar do sleep — e após cada disparo.
    func handleWake() async { await rearmAll() }

    func rearmAll() async {
        guard !paused else { return }
        for uid in Array(tasks.keys) { await rearm(uid) }
    }

    private func rearm(_ uid: UUID) async {
        guard let task = tasks[uid] else { return }
        guard inFlightOccurrences[uid] == nil else { return }
        if let retry = pendingRetry[uid] {
            if let notBefore = retryNotBefore[uid], notBefore > clock.now {
                nextFires[uid] = notBefore
                return
            }
            pendingRetry[uid] = nil
            retryNotBefore[uid] = nil
            await fire(task, occurrence: retry)
            return
        }
        if let armed = nextFires[uid], armed > clock.now, timers[uid] != nil { return }
        // Armado que passou (sleep engoliu o timer) → dispara já; o skip por
        // sessão ativa fica a cargo do FireController.
        if let armed = nextFires[uid], armed <= clock.now {
            log.info("rearm: armado vencido \(armed, privacy: .public) dispara ja uid \(uid.uuidString, privacy: .public)")
            timers[uid]?.invalidate(); timers[uid] = nil
            nextFires[uid] = nil
            await fire(task, occurrence: armed)
            return
        }
        // Sem armado: ocorrência perdida desde a última disparada (nunca antes
        // do launch) → catch-up único.
        let since = max(lastFiredOccurrence[uid] ?? startedAt, catchUpFloor[uid] ?? startedAt)
        if let missed = AgendaMath.lastMissedOccurrence(times: task.times, weekdays: task.weekdays,
                                                        between: since, and: clock.now,
                                                        calendar: calendar) {
            log.info("rearm: catch-up ocorrencia perdida \(missed, privacy: .public) uid \(uid.uuidString, privacy: .public)")
            await fire(task, occurrence: missed)
            return
        }
        guard let next = AgendaMath.nextOccurrence(times: task.times, weekdays: task.weekdays,
                                                   after: clock.now, calendar: calendar)
        else {
            log.info("rearm: sem ocorrencia futura uid \(uid.uuidString, privacy: .public)")
            return
        }
        log.info("rearm: arma proxima \(next, privacy: .public) uid \(uid.uuidString, privacy: .public)")
        armTimer(uid, at: next)
    }

    private func armTimer(_ uid: UUID, at date: Date) {
        nextFires[uid] = date
        timers[uid]?.invalidate()
        let t = Timer(fire: date.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timers[uid] = nil
                if let task = self.tasks[uid] { await self.fire(task, occurrence: date) }
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timers[uid] = t
    }

    private func fire(_ task: ScheduledTask, occurrence: Date) async {
        guard !paused, tasks[task.uid] != nil else {
            clearRetry(for: task.uid)
            return
        }
        // Dedupe por identidade: a mesma ocorrência nunca dispara duas vezes.
        // O caminho normal já é protegido pelo `since` do catch-up e pelo
        // encadeamento do rearm; isto guarda só corridas assíncronas (timer +
        // wake + statusTick intercalados na mesma ocorrência).
        if let last = lastFiredOccurrence[task.uid], occurrence <= last {
            log.debug("fire: dedupe ocorrencia \(occurrence, privacy: .public) ja disparada uid \(task.uid.uuidString, privacy: .public)")
            return
        }
        guard inFlightOccurrences[task.uid] == nil else {
            log.debug("fire: ocorrencia em andamento uid \(task.uid.uuidString, privacy: .public)")
            return
        }
        inFlightOccurrences[task.uid] = occurrence
        nextFires[task.uid] = nil
        let advancesSchedule = await onFire?(task) ?? true
        inFlightOccurrences[task.uid] = nil
        // Remoção/edição durante o callback já instalou seu próprio piso de
        // catch-up. Não aplica retry/outcome da versão antiga à tarefa atual.
        guard !paused, let currentTask = tasks[task.uid] else {
            clearRetry(for: task.uid)
            return
        }
        guard currentTask == task else {
            clearRetry(for: task.uid)
            await rearm(task.uid)
            return
        }
        guard advancesSchedule else {
            log.info("fire: falha transitoria, em retry, uid \(task.uid.uuidString, privacy: .public)")
            let attempt = (retryAttempts[task.uid] ?? 0) + 1
            retryAttempts[task.uid] = attempt
            let exponent = min(attempt - 1, 10)
            let delay = min(
                maximumRetryDelay,
                retryBaseDelay * pow(2, Double(exponent))
            )
            pendingRetry[task.uid] = occurrence
            let retryAt = clock.now.addingTimeInterval(delay)
            retryNotBefore[task.uid] = retryAt
            nextFires[task.uid] = retryAt
            return
        }
        clearRetry(for: task.uid)
        lastFiredOccurrence[task.uid] = occurrence
        log.info("fire: disparou ocorrencia \(occurrence, privacy: .public) uid \(task.uid.uuidString, privacy: .public)")
        await rearm(task.uid) // encadeia a próxima ocorrência
    }

    private func clearRetry(for uid: UUID) {
        pendingRetry[uid] = nil
        retryAttempts[uid] = nil
        retryNotBefore[uid] = nil
    }
}
