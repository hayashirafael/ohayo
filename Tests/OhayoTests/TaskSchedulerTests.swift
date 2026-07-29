import XCTest
@testable import Ohayo

@MainActor
final class TaskSchedulerTests: XCTestCase {
    // FakeClock mutável, no padrão dos testes existentes (FireControllerTests).
    private final class MutableClock: Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func task(times: [Int], weekdays: Set<Int> = Set(1...7),
                      enabled: Bool = true) -> ScheduledTask {
        ScheduledTask(uid: UUID(), name: nil, command: nil,
                      times: times, weekdays: weekdays, enabled: enabled)
    }

    func testConfigureArmaProximaOcorrenciaSemDispararNoLaunch() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let t = task(times: [480]) // 08:00
        await scheduler.configure(tasks: [t], paused: false)
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 9, 8, 0))
        XCTAssertTrue(fired.isEmpty) // launch não dispara retroativo
    }

    func testWakeAposHorarioPerdidoDispara() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let t = task(times: [480])
        await scheduler.configure(tasks: [t], paused: false)
        clock.now = date(2026, 7, 9, 9, 0) // dormiu através das 08:00
        await scheduler.handleWake()
        XCTAssertEqual(fired, [t.uid])
        // encadeia: próxima é amanhã 08:00
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 10, 8, 0))
    }

    func testDedupeNaoDisparaDuasVezesEmSeguida() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var count = 0
        scheduler.onFire = { _ in count += 1; return true }
        let t = task(times: [480])
        await scheduler.configure(tasks: [t], paused: false)
        clock.now = date(2026, 7, 9, 8, 1)
        await scheduler.handleWake()
        await scheduler.handleWake() // segundo wake 0s depois → dedupe
        XCTAssertEqual(count, 1)
    }

    func testWakeDuranteDisparoNaoDuplicaMesmaOcorrencia() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var count = 0
        var entered = false
        var enteredWaiter: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        scheduler.onFire = { _ in
            count += 1
            guard count == 1 else { return true }
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { release = $0 }
            return true
        }
        let scheduled = task(times: [480])
        await scheduler.configure(tasks: [scheduled], paused: false)
        clock.now = date(2026, 7, 9, 8, 1)

        let first = Task { @MainActor in
            await scheduler.handleWake()
        }
        if !entered {
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        await scheduler.rearmAll()
        XCTAssertEqual(count, 1)

        release?.resume()
        release = nil
        await first.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(
            scheduler.nextFires[scheduled.uid],
            date(2026, 7, 10, 8, 0)
        )
    }

    func testPausaLimpaTimersEStatus() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        let t = task(times: [480])
        await scheduler.configure(tasks: [t], paused: false)
        await scheduler.configure(tasks: [t], paused: true)
        XCTAssertTrue(scheduler.nextFires.isEmpty)
    }

    func testTarefaDesabilitadaNaoArma() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        let t = task(times: [480], enabled: false)
        await scheduler.configure(tasks: [t], paused: false)
        XCTAssertNil(scheduler.nextFires[t.uid])
    }

    func testEditarTarefaArmadaReArmaParaNovoHorario() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let uid = UUID()
        let original = ScheduledTask(uid: uid, name: nil, command: nil,
                                     times: [480], weekdays: Set(1...7), enabled: true) // 08:00
        await scheduler.configure(tasks: [original], paused: false)
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 9, 8, 0))

        // Usuário edita para 09:00 enquanto ainda armado para 08:00.
        let edited = ScheduledTask(uid: uid, name: nil, command: nil,
                                   times: [540], weekdays: Set(1...7), enabled: true) // 09:00
        await scheduler.configure(tasks: [edited], paused: false)
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 9, 9, 0))

        clock.now = date(2026, 7, 9, 8, 0) // horário antigo, removido pela edição
        await scheduler.handleWake()
        XCTAssertTrue(fired.isEmpty)

        clock.now = date(2026, 7, 9, 9, 0)
        await scheduler.handleWake()
        XCTAssertEqual(fired, [uid])
    }

    func testEdicaoNaoDisparaCatchUpRetroativoDoNovoHorario() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let uid = UUID()
        let original = ScheduledTask(uid: uid, name: nil, command: nil,
                                     times: [1320], weekdays: Set(1...7), enabled: true) // 22:00
        await scheduler.configure(tasks: [original], paused: false)

        clock.now = date(2026, 7, 9, 7, 31)
        // Edita para 07:15 — já ficou "no passado" no exato momento da edição.
        let edited = ScheduledTask(uid: uid, name: nil, command: nil,
                                   times: [435], weekdays: Set(1...7), enabled: true) // 07:15
        await scheduler.configure(tasks: [edited], paused: false)
        XCTAssertTrue(fired.isEmpty) // edição não é catch-up retroativo

        clock.now = date(2026, 7, 10, 7, 15) // ocorrência real de amanhã
        await scheduler.handleWake()
        XCTAssertEqual(fired, [uid])
    }

    func testEdicaoNaoEngoleDisparoAgendadoLogoDepois() async {
        // Bug real: editar a tarefa avançava lastFireAt, e o dedupe de 120s do
        // fire() (que deve olhar só disparos REAIS) engolia o disparo agendado
        // para 1-2 min depois da edição — silenciosamente, sem histórico.
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let uid = UUID()
        let original = ScheduledTask(uid: uid, name: nil, command: nil,
                                     times: [480], weekdays: Set(1...7), enabled: true) // 08:00
        await scheduler.configure(tasks: [original], paused: false)

        // Usuário edita às 07:00 para disparar 07:01 (60s no futuro).
        let edited = ScheduledTask(uid: uid, name: nil, command: nil,
                                   times: [421], weekdays: Set(1...7), enabled: true) // 07:01
        await scheduler.configure(tasks: [edited], paused: false)
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 9, 7, 1))

        clock.now = date(2026, 7, 9, 7, 1)
        await scheduler.handleWake()
        XCTAssertEqual(fired, [uid]) // dispara no horário; edição não é disparo
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 10, 7, 1))
    }

    func testCatchUpUsaMaiorEntreUltimoDisparoRealEEdicao() async {
        // O piso do catch-up é o MAIOR entre o último disparo real e a edição:
        // esquecer o piso da edição faria o novo horário (já no passado)
        // disparar retroativamente na hora da edição.
        let clock = MutableClock(date(2026, 7, 9, 5, 59))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let uid = UUID()
        let original = ScheduledTask(uid: uid, name: nil, command: nil,
                                     times: [360], weekdays: Set(1...7), enabled: true) // 06:00
        await scheduler.configure(tasks: [original], paused: false)

        clock.now = date(2026, 7, 9, 6, 0)
        await scheduler.handleWake()
        XCTAssertEqual(fired, [uid]) // disparo real às 06:00

        clock.now = date(2026, 7, 9, 7, 0)
        // Edita para 06:30 — horário entre o último disparo real e agora.
        let edited = ScheduledTask(uid: uid, name: nil, command: nil,
                                   times: [390], weekdays: Set(1...7), enabled: true) // 06:30
        await scheduler.configure(tasks: [edited], paused: false)
        XCTAssertEqual(fired, [uid]) // sem catch-up retroativo do 06:30
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 10, 6, 30))
    }

    func testOcorrenciasEmMinutosAdjacentesDisparamAmbas() async {
        // Bug real (12:07/12:08): o dedupe antigo era uma janela wall-clock de
        // 120s — maior que a granularidade de minuto da agenda — e engolia a
        // ocorrência do minuto seguinte a um disparo real. O dedupe correto é
        // por identidade de ocorrência: ocorrências distintas sempre disparam.
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var count = 0
        scheduler.onFire = { _ in count += 1; return true }
        let t = task(times: [727, 728]) // 12:07 e 12:08
        await scheduler.configure(tasks: [t], paused: false)

        clock.now = date(2026, 7, 9, 12, 7)
        await scheduler.handleWake() // dispara 12:07; encadeia para 12:08
        XCTAssertEqual(count, 1)

        clock.now = date(2026, 7, 9, 12, 8) // 60s depois do disparo anterior
        await scheduler.handleWake()
        XCTAssertEqual(count, 2) // ocorrência distinta → dispara também
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 10, 12, 7))
    }

    func testCriarTarefaComHorarioJaPassadoNaoDisparaNaCriacao() async {
        // "Criar não é disparar": tarefa nova com horário que já passou desde
        // o launch não faz catch-up retroativo na hora do save — só dispara
        // ocorrências futuras (mesma filosofia do launch e da edição).
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        await scheduler.configure(tasks: [], paused: false)

        clock.now = date(2026, 7, 9, 12, 10)
        let t = task(times: [725]) // 12:05 — já passou no momento da criação
        await scheduler.configure(tasks: [t], paused: false)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 10, 12, 5))
    }

    func testFalhaTransitoriaEntraEmRetryComBackoff() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var results: [Bool] = [false, true]
        var count = 0
        scheduler.onFire = { _ in count += 1; return results.removeFirst() }
        let t = task(times: [480])
        await scheduler.configure(tasks: [t], paused: false)
        clock.now = date(2026, 7, 9, 8, 1)
        await scheduler.handleWake()
        await scheduler.rearmAll()
        XCTAssertEqual(count, 1, "não pode repetir antes do backoff")
        clock.now = date(2026, 7, 9, 8, 2)
        await scheduler.rearmAll()
        XCTAssertEqual(count, 2)
    }

    // MARK: - Piso = início do minuto corrente − 1s (agendar "para agora")

    func testCriarTarefaNoMinutoDoHorarioDisparaImediatamente() async {
        // Fluxo natural de quem testa: criar às 12:44:20 um agendamento de 12:44
        // deve disparar a ocorrência 12:44:00 do minuto corrente, não armar
        // silenciosamente para amanhã.
        let clock = MutableClock(date(2026, 7, 9, 7, 0)) // launch 07:00
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        await scheduler.configure(tasks: [], paused: false)

        clock.now = date(2026, 7, 9, 12, 44, 20) // cria 20s dentro do minuto
        let t = task(times: [764]) // 12:44
        await scheduler.configure(tasks: [t], paused: false)

        XCTAssertEqual(fired, [t.uid])
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 10, 12, 44))
    }

    func testCriarTarefaNoMinutoDoHorarioNoLaunchNaoDispara() async {
        // Launch dentro do minuto do horário: startedAt (12:44:10) prevalece
        // sobre o piso do minuto — launch nunca faz catch-up retroativo.
        let clock = MutableClock(date(2026, 7, 9, 12, 44, 10))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let t = task(times: [764]) // 12:44
        await scheduler.configure(tasks: [t], paused: false)

        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 10, 12, 44))
    }

    func testEditarTarefaParaMinutoCorrenteDispara() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let uid = UUID()
        let original = ScheduledTask(uid: uid, name: nil, command: nil,
                                     times: [480], weekdays: Set(1...7), enabled: true) // 08:00
        await scheduler.configure(tasks: [original], paused: false)

        clock.now = date(2026, 7, 9, 12, 44, 20)
        let edited = ScheduledTask(uid: uid, name: nil, command: nil,
                                   times: [764], weekdays: Set(1...7), enabled: true) // 12:44
        await scheduler.configure(tasks: [edited], paused: false)

        XCTAssertEqual(fired, [uid])
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 10, 12, 44))
    }

    func testReabilitarTarefaNoMinutoCorrenteDispara() async {
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        let uid = UUID()
        let disabled = ScheduledTask(uid: uid, name: nil, command: nil,
                                     times: [764], weekdays: Set(1...7), enabled: false) // 12:44
        await scheduler.configure(tasks: [disabled], paused: false)

        clock.now = date(2026, 7, 9, 12, 44, 20)
        let enabled = ScheduledTask(uid: uid, name: nil, command: nil,
                                    times: [764], weekdays: Set(1...7), enabled: true)
        await scheduler.configure(tasks: [enabled], paused: false)

        XCTAssertEqual(fired, [uid])
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 10, 12, 44))
    }

    func testReabilitarAposDisparoRealNoMesmoMinutoNaoRedispara() async {
        // lastFiredOccurrence vence no max do piso: reconfigurar/reabilitar no
        // mesmo minuto de um disparo REAL não re-dispara a mesma ocorrência.
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var count = 0
        scheduler.onFire = { _ in count += 1; return true }
        let uid = UUID()
        let t = ScheduledTask(uid: uid, name: nil, command: nil,
                              times: [764], weekdays: Set(1...7), enabled: true) // 12:44
        await scheduler.configure(tasks: [t], paused: false)

        clock.now = date(2026, 7, 9, 12, 44, 5)
        await scheduler.handleWake() // disparo real 12:44:00
        XCTAssertEqual(count, 1)

        // Desabilita e reabilita ainda dentro do minuto 12:44.
        let disabled = ScheduledTask(uid: uid, name: nil, command: nil,
                                     times: [764], weekdays: Set(1...7), enabled: false)
        await scheduler.configure(tasks: [disabled], paused: false)
        clock.now = date(2026, 7, 9, 12, 44, 30)
        await scheduler.configure(tasks: [t], paused: false)

        XCTAssertEqual(count, 1) // não redispara a ocorrência já disparada
        XCTAssertEqual(scheduler.nextFires[uid], date(2026, 7, 10, 12, 44))
    }

    func testCriarTarefaComMinutoAnteriorNaoDispara() async {
        // O piso é o início do minuto corrente − 1s: pega só a ocorrência do
        // minuto atual, nunca a do minuto anterior. Criar 12:45:10 um [12:44]
        // não dispara.
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var fired: [UUID] = []
        scheduler.onFire = { fired.append($0.uid); return true }
        await scheduler.configure(tasks: [], paused: false)

        clock.now = date(2026, 7, 9, 12, 45, 10)
        let t = task(times: [764]) // 12:44 — minuto anterior
        await scheduler.configure(tasks: [t], paused: false)

        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 10, 12, 44))
    }

    func testRetryPendenteReDisparaAposBackoffESemRefireDepois() async {
        // Uma falha transitória preserva a MESMA ocorrência. Após o backoff,
        // dispara — e depois disso a ocorrência não re-dispara.
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var permite = false
        var count = 0
        scheduler.onFire = { _ in count += 1; return permite }
        let t = task(times: [480]) // 08:00
        await scheduler.configure(tasks: [t], paused: false)

        clock.now = date(2026, 7, 9, 9, 0)   // dormiu através das 08:00
        await scheduler.handleWake()
        XCTAssertEqual(count, 1)

        permite = true
        await scheduler.handleWake()
        XCTAssertEqual(count, 1)
        clock.now = date(2026, 7, 9, 9, 1)
        await scheduler.handleWake()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(scheduler.nextFires[t.uid], date(2026, 7, 10, 8, 0)) // encadeou

        await scheduler.handleWake()          // 08:00 já disparado → sem refire
        XCTAssertEqual(count, 2)
    }

    func testDesabilitarTarefaEstancaRetryPendente() async {
        // Retry pendente + tarefa desabilitada: o disparo fantasma da ocorrência
        // que o usuário desabilitou não pode acontecer, mesmo com o guard já
        // liberado.
        let clock = MutableClock(date(2026, 7, 9, 7, 0))
        let scheduler = TaskScheduler(clock: clock, calendar: cal)
        var permite = false
        var count = 0
        scheduler.onFire = { _ in count += 1; return permite }
        let t = task(times: [480])
        await scheduler.configure(tasks: [t], paused: false)
        clock.now = date(2026, 7, 9, 9, 0)
        await scheduler.handleWake()          // pendingRetry setado (guard negou)
        XCTAssertEqual(count, 1)

        permite = true
        let desabilitada = ScheduledTask(uid: t.uid, times: [480], weekdays: Set(1...7), enabled: false)
        await scheduler.configure(tasks: [desabilitada], paused: false)
        await scheduler.handleWake()
        XCTAssertEqual(count, 1, "tarefa desabilitada não pode disparar o retry pendente")
    }
}
