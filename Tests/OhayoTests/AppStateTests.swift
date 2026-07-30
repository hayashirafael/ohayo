import XCTest
@testable import Ohayo

@MainActor
final class AppStateTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "ohayo-test-\(UUID().uuidString)")!
        // Mantém os testes independentes das contas reais da máquina.
        d.set([String](), forKey: "registeredAccounts")
        return d
    }

    /// Cria uma pasta de conta fake com a assinatura pedida.
    private func makeAccountDir(signature: String? = nil, subdir: String? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("conta-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let signature {
            try "{}".write(to: dir.appendingPathComponent(signature),
                           atomically: true, encoding: .utf8)
        }
        if let subdir {
            try fm.createDirectory(at: dir.appendingPathComponent(subdir),
                                   withIntermediateDirectories: true)
        }
        return dir
    }

    func testFireResultSkippedRoundtripCodable() throws {
        let event = FireEvent(date: Date(timeIntervalSince1970: 1_783_000_000),
                              result: .skipped(activeUntil: Date(timeIntervalSince1970: 1_783_010_000)))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(FireEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testFireResultFailureRoundtripCodable() throws {
        let event = FireEvent(date: Date(timeIntervalSince1970: 1_783_000_000),
                              result: .failure(message: "claude nao encontrado"))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(FireEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testFireResultMissedRoundtripCodable() throws {
        let event = FireEvent(date: Date(timeIntervalSince1970: 1_783_000_000),
                              result: .missed(occurrence: Date(timeIntervalSince1970: 1_782_990_000)))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(FireEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    // MARK: - Heartbeat e ocorrências perdidas com o app fechado

    private var calSP: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }

    private func dateSP(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calSP.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func fixedTask(times: [Int], weekdays: Set<Int> = Set(1...7),
                           enabled: Bool = true,
                           repetition: ScheduledTask.Repetition = .fixed) -> ScheduledTask {
        var t = ScheduledTask(uid: UUID(), repetition: repetition,
                              times: times, weekdays: weekdays)
        t.enabled = enabled
        return t
    }

    func testRecordAlivePersisteHeartbeatParaOProximoLaunch() {
        let d = freshDefaults()
        let s1 = AppState(defaults: d)
        XCTAssertNil(s1.previousAliveAt) // primeiro launch de todos
        let t = dateSP(2026, 7, 9, 10, 0)
        s1.recordAlive(now: t)
        let s2 = AppState(defaults: d)
        XCTAssertEqual(s2.previousAliveAt, t)
    }

    func testPanelUpcomingCountPadrao1PersisteEClampaNaLeitura() {
        let d = freshDefaults()
        let s1 = AppState(defaults: d)
        XCTAssertEqual(s1.panelUpcomingCount, 1) // padrão

        s1.panelUpcomingCount = 3
        let s2 = AppState(defaults: d)
        XCTAssertEqual(s2.panelUpcomingCount, 3) // persistiu

        d.set(99, forKey: "panelUpcomingCount")
        XCTAssertEqual(AppState(defaults: d).panelUpcomingCount, 5) // clamp alto
        d.set(-2, forKey: "panelUpcomingCount")
        XCTAssertEqual(AppState(defaults: d).panelUpcomingCount, 1) // clamp baixo
    }

    func testRecordEventAvancaHeartbeat() {
        let d = freshDefaults()
        let s1 = AppState(defaults: d)
        let when = dateSP(2026, 7, 9, 11, 0)
        s1.recordEvent(FireEvent(date: when, result: .success))
        let s2 = AppState(defaults: d)
        XCTAssertEqual(s2.previousAliveAt, when)
    }

    func testMissedWhileClosedRegistraEventoPerdido() {
        let d = freshDefaults()
        d.set(dateSP(2026, 7, 8, 23, 0), forKey: "lastAliveAt") // app fechado às 23:00 de ontem
        let s = AppState(defaults: d)
        s.tasks = [fixedTask(times: [480])] // 08:00 diário
        s.recordMissedWhileClosed(now: dateSP(2026, 7, 9, 9, 0), calendar: calSP)
        guard case .missed(let occurrence) = s.history.first?.result else {
            return XCTFail("esperava evento .missed, veio \(String(describing: s.history.first))")
        }
        XCTAssertEqual(occurrence, dateSP(2026, 7, 9, 8, 0))
        XCTAssertEqual(s.history.first?.origin, .agenda)
        XCTAssertEqual(s.history.first?.account, ".claude") // conta padrão do provider
    }

    func testMissedWhileClosedPrimeiroLaunchNaoRegistra() {
        let s = AppState(defaults: freshDefaults()) // sem heartbeat semeado
        s.tasks = [fixedTask(times: [480])]
        s.recordMissedWhileClosed(now: dateSP(2026, 7, 9, 9, 0), calendar: calSP)
        XCTAssertTrue(s.history.isEmpty)
    }

    func testMissedWhileClosedSemOcorrenciaNoIntervaloNaoRegistra() {
        let d = freshDefaults()
        d.set(dateSP(2026, 7, 9, 8, 55), forKey: "lastAliveAt") // fechado por 5 min
        let s = AppState(defaults: d)
        s.tasks = [fixedTask(times: [480])] // 08:00 — fora do intervalo
        s.recordMissedWhileClosed(now: dateSP(2026, 7, 9, 9, 0), calendar: calSP)
        XCTAssertTrue(s.history.isEmpty)
    }

    func testMissedWhileClosedNoMaximoUmEventoPorTarefaPorLaunch() {
        let d = freshDefaults()
        d.set(dateSP(2026, 7, 8, 23, 0), forKey: "lastAliveAt")
        let s = AppState(defaults: d)
        s.tasks = [fixedTask(times: [480, 500])] // 08:00 e 08:20 perdidas
        s.recordMissedWhileClosed(now: dateSP(2026, 7, 9, 9, 0), calendar: calSP)
        XCTAssertEqual(s.history.count, 1) // só a mais recente (catch-up único)
        s.recordMissedWhileClosed(now: dateSP(2026, 7, 9, 9, 5), calendar: calSP)
        XCTAssertEqual(s.history.count, 1) // segunda chamada não duplica
    }

    func testMissedWhileClosedIgnoraDesabilitadaEContinua() {
        let d = freshDefaults()
        d.set(dateSP(2026, 7, 8, 23, 0), forKey: "lastAliveAt")
        let s = AppState(defaults: d)
        s.tasks = [fixedTask(times: [480], enabled: false),
                   fixedTask(times: [480], repetition: .continuous)]
        s.recordMissedWhileClosed(now: dateSP(2026, 7, 9, 9, 0), calendar: calSP)
        XCTAssertTrue(s.history.isEmpty)
    }

    func testPrimeiroLaunchDescobreContasExistentesSemInventarClaudeDefault() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-discovery-\(UUID().uuidString)")
        let custom = home.appendingPathComponent(".claude-trabalho")
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: custom.appendingPathComponent("projects"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "{}".write(to: codex.appendingPathComponent("auth.json"),
                       atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = UserDefaults(suiteName: "ohayo-test-\(UUID().uuidString)")!

        let state = AppState(defaults: defaults, home: home)
        let accounts = Set(state.discoverAccounts().map(\.standardizedFileURL))

        XCTAssertTrue(accounts.contains(custom.standardizedFileURL))
        XCTAssertTrue(accounts.contains(codex.standardizedFileURL))
        XCTAssertFalse(accounts.contains(
            home.appendingPathComponent(".claude").standardizedFileURL
        ))
        XCTAssertEqual(state.registeredAccounts, [custom.standardizedFileURL.path])
    }

    func testContaCustomPersistidaContinuaVisivelQuandoPastaSome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-home-vazio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let missing = home.appendingPathComponent(".claude-removida").standardizedFileURL
        let defaults = freshDefaults()
        defaults.set([missing.path], forKey: "registeredAccounts")

        let state = AppState(defaults: defaults, home: home)

        XCTAssertTrue(state.discoverAccounts().contains(missing))
    }

    func testMissingCLIsNaoAlertaClaudeParaUsuarioSomenteCodexEShell() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-codex-only-\(UUID().uuidString)")
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "{}".write(to: codex.appendingPathComponent("auth.json"),
                       atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }
        let state = AppState(defaults: freshDefaults(), home: home)
        state.tasks = [
            ScheduledTask(uid: UUID(), command: Message(text: "1+1", kind: .codex)),
            ScheduledTask(uid: UUID(), command: Message(text: "echo oi", kind: .shell)),
        ]
        state.cliFound = [.claude: false, .codex: false]

        XCTAssertEqual(state.missingCLIs, [.codex])
    }

    func testMessageConfigRoundtripCodable() throws {
        let msg = Message(text: "tarefa", kind: .claude, model: .opus, effort: .high,
                          safeMode: false, configDir: "/tmp/conta", workingDir: "/tmp/proj")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    func testMessageComCamposOpcionaisAusentesUsaDefaultsResolvidos() throws {
        let json = #"{"text":"1+1","kind":"claude"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(msg.model)
        XCTAssertNil(msg.effort)
        XCTAssertNil(msg.safeMode)
        XCTAssertEqual(msg.resolvedModel, .haiku)
        XCTAssertEqual(msg.resolvedEffort, .low)
        XCTAssertTrue(msg.resolvedSafeMode)
    }

    func testTrustDaPastaMantemLegadoEPermiteRevogacaoExplicita() throws {
        let legacyJSON =
            #"{"text":"revise","kind":"codex","workingDir":"/tmp/projeto"}"#
                .data(using: .utf8)!
        let legacy = try JSONDecoder().decode(
            Message.self,
            from: legacyJSON
        )
        let revoked = Message(
            text: "revise",
            kind: .codex,
            workingDir: "/tmp/projeto",
            trustWorkingDirectory: false
        )

        XCTAssertNil(legacy.trustWorkingDirectory)
        XCTAssertTrue(legacy.resolvedTrustWorkingDirectory)
        XCTAssertFalse(revoked.resolvedTrustWorkingDirectory)
        XCTAssertFalse(
            Message(
                text: "echo oi",
                kind: .shell,
                workingDir: "/tmp/projeto",
                trustWorkingDirectory: true
            ).resolvedTrustWorkingDirectory
        )
    }

    func testHomeInjetadoControlaTodosOsDefaultsDeConta() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let state = AppState(defaults: freshDefaults(), home: home)
        let claude = home.appendingPathComponent(".claude").standardizedFileURL
        let codex = home.appendingPathComponent(".codex").standardizedFileURL

        XCTAssertEqual(
            state.accountDir(for: ScheduledTask(
                uid: UUID(), command: Message(text: "x", kind: .claude)
            )),
            claude
        )
        XCTAssertEqual(
            state.makeEvent(
                date: Date(), result: .success,
                message: Message(text: "x", kind: .codex), origin: .manual
            ).accountPath,
            codex.path
        )
    }

    func testDefaultMessageTemUIDFixo() {
        XCTAssertEqual(AppState.defaultMessage.uid,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }

    func testIgualdadeIgnoraUID() {
        var a = Message(text: "x", kind: .claude); a.uid = UUID()
        var b = Message(text: "x", kind: .claude); b.uid = UUID()
        XCTAssertEqual(a, b)
    }

    func testShowResponseAusenteEDefaultFalse() throws {
        let json = #"{"text":"1+1","kind":"claude"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(msg.showResponse)
        XCTAssertFalse(msg.resolvedShowResponse)
    }

    func testNotifyOnSuccessAusenteEDefaultFalse() throws {
        let json = #"{"text":"1+1","kind":"claude"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(msg.notifyOnSuccess)
        XCTAssertFalse(msg.resolvedNotifyOnSuccess)
    }

    func testIgualdadeConsideraNotifyOnSuccess() throws {
        let sem = Message(text: "x", kind: .claude)
        let com = Message(text: "x", kind: .claude, notifyOnSuccess: true)
        XCTAssertNotEqual(sem, com)
        let data = try JSONEncoder().encode(com)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded, com)
    }

    func testRunInTerminalAusenteEDefaultTrueParaClaudeECodex() throws {
        let claudeJSON = #"{"text":"1+1","kind":"claude"}"#.data(using: .utf8)!
        let codexJSON = #"{"text":"1+1","kind":"codex"}"#.data(using: .utf8)!
        let claude = try JSONDecoder().decode(Message.self, from: claudeJSON)
        let codex = try JSONDecoder().decode(Message.self, from: codexJSON)
        XCTAssertNil(claude.runInTerminal)
        XCTAssertNil(codex.runInTerminal)
        XCTAssertTrue(claude.resolvedRunInTerminal)
        XCTAssertTrue(codex.resolvedRunInTerminal)
    }

    func testRunInTerminalIgnoradoParaShell() throws {
        let msg = Message(text: "echo oi", kind: .shell, runInTerminal: true)
        XCTAssertFalse(msg.resolvedRunInTerminal)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded, msg)
        XCTAssertFalse(decoded.resolvedRunInTerminal)
    }

    func testIdiomaPadraoEhIngles() {
        let state = AppState(defaults: freshDefaults())
        XCTAssertEqual(state.language, .english)
        XCTAssertEqual(state.strings.settingsTitle, "Settings")
    }

    func testIdiomaPersiste() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        state.language = .portuguese
        let restored = AppState(defaults: defaults)
        XCTAssertEqual(restored.language, .portuguese)
        XCTAssertEqual(restored.strings.settingsTitle, "Configurações")
    }

    func testIdiomaInvalidoVoltaParaIngles() {
        let defaults = freshDefaults()
        defaults.set("fr", forKey: "language")
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.language, .english)
    }

    func testDetalhesSensiveisDeNotificacaoSaoOptInEPersistem() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        XCTAssertFalse(state.showSensitiveNotificationDetails)

        state.showSensitiveNotificationDetails = true

        XCTAssertTrue(
            AppState(defaults: defaults).showSensitiveNotificationDetails
        )
    }

    func testHistoricoCapEm20MaisRecentePrimeiro() {
        let state = AppState(defaults: freshDefaults())
        for i in 0..<25 {
            state.recordEvent(FireEvent(date: Date(timeIntervalSince1970: Double(i)), result: .success))
        }
        XCTAssertEqual(state.history.count, 20)
        XCTAssertEqual(state.history.first?.date, Date(timeIntervalSince1970: 24))
        XCTAssertEqual(state.lastEvent, state.history.first)
    }

    func testHistoricoPersisteERestaura() {
        let defaults = freshDefaults()
        let a = AppState(defaults: defaults)
        a.recordEvent(FireEvent(date: Date(timeIntervalSince1970: 1), result: .success,
                                messageText: "1+1", account: ".claude", origin: .scheduled))
        let b = AppState(defaults: defaults)
        XCTAssertEqual(b.history, a.history)
    }

    func testLimparHistoricoRemoveEventosPersistidos() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        state.recordEvent(FireEvent(date: Date(), result: .success))

        state.clearHistory()

        XCTAssertTrue(state.history.isEmpty)
        XCTAssertTrue(AppState(defaults: defaults).history.isEmpty)
    }

    func testApelidoPersisteEDefineRotulo() {
        let defaults = freshDefaults()
        let dir = URL(fileURLWithPath: "/tmp/.claude9")
        let a = AppState(defaults: defaults)
        XCTAssertNil(a.alias(for: dir))
        // Sem apelido nem e-mail (dir inexistente) → rótulo cai no nome da pasta.
        XCTAssertEqual(a.label(for: dir), ".claude9")
        a.setAlias(dir, "Trabalho")
        XCTAssertEqual(a.alias(for: dir), "Trabalho")
        XCTAssertEqual(a.label(for: dir), "Trabalho")
        a.setAlias(dir, "   ") // vazio/whitespace limpa
        XCTAssertNil(a.alias(for: dir))
        let b = AppState(defaults: defaults)
        a.setAlias(dir, "Pessoal")
        let c = AppState(defaults: defaults)
        XCTAssertEqual(c.alias(for: dir), "Pessoal")
        _ = b
    }

    func testMensagemCodexSemModeloFicaNilEFazRoundTrip() throws {
        // Sem escolha explícita, modelo/reasoning ficam nil (o Codex herda o
        // default da conta em vez de o app forçar um modelo).
        let msg = Message(text: "oi", kind: .codex)
        XCTAssertNil(msg.codexModel)
        XCTAssertNil(msg.codexReasoning)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    func testHiPadraoPorProvider() {
        XCTAssertEqual(AppState.defaultHi(for: .claude), AppState.defaultMessage)
        XCTAssertEqual(AppState.defaultHi(for: .codex), AppState.defaultCodexMessage)
        XCTAssertEqual(AppState.defaultCodexMessage.kind, .codex)
        XCTAssertEqual(AppState.defaultCodexMessage.uid,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    }

    func testRegisterAccountInfereProviderEPersiste() throws {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        let dir = try makeAccountDir(signature: "auth.json") // nome livre, conteúdo Codex
        XCTAssertEqual(state.registerAccount(dir), .codex)
        XCTAssertTrue(state.registeredAccounts.contains(dir.standardizedFileURL.path))
        XCTAssertTrue(state.discoverAccounts().contains(dir.standardizedFileURL))
        // Duplicata → no-op.
        XCTAssertEqual(state.registerAccount(dir), .codex)
        XCTAssertEqual(state.registeredAccounts.filter { $0 == dir.standardizedFileURL.path }.count, 1)
    }

    func testProviderDaContaCustomPersisteQuandoPastaSome() throws {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        let dir = try makeAccountDir(signature: "auth.json")
        XCTAssertEqual(state.registerAccount(dir), .codex)

        try FileManager.default.removeItem(at: dir)
        let reloaded = AppState(defaults: defaults)

        XCTAssertTrue(reloaded.discoverAccounts().contains(dir.standardizedFileURL))
        XCTAssertEqual(reloaded.provider(for: dir), .codex)
    }

    func testRegisterAccountPastaSemAssinaturaNaoCadastra() throws {
        let state = AppState(defaults: freshDefaults())
        let dir = try makeAccountDir() // sem assinatura de nenhum provider
        XCTAssertNil(state.registerAccount(dir))
        XCTAssertTrue(state.registeredAccounts.isEmpty)
    }

    func testUnregisterLimpaCadastroEApelido() throws {
        let state = AppState(defaults: freshDefaults())
        let dir = try makeAccountDir(subdir: "projects")
        state.registerAccount(dir)
        state.setAlias(dir, "extra")
        state.unregisterAccount(dir)
        XCTAssertTrue(state.registeredAccounts.isEmpty)
        XCTAssertNil(state.alias(for: dir))
    }

    func testUnregisterDesabilitaAgendamentosDaConta() throws {
        let d = freshDefaults()
        let state = AppState(defaults: d)
        let conta = try makeAccountDir(signature: ".claude.json")
        state.registerAccount(conta)
        var cmd = Message(text: "1+1", kind: .claude)
        cmd.configDir = conta.path
        state.tasks = [ScheduledTask(uid: UUID(), command: cmd, repetition: .continuous)]
        state.unregisterAccount(conta)
        XCTAssertFalse(state.tasks[0].enabled)
    }

    func testProviderForFallbackClaudeParaPastaSemAssinatura() {
        let state = AppState(defaults: freshDefaults())
        // ~/.claude recém-instalado pode não ter assinatura ainda → .claude.
        XCTAssertEqual(state.provider(for: URL(fileURLWithPath: "/nao/existe")), .claude)
    }

    /// As contas padrão (~/.claude, ~/.codex) nunca são cadastradas — são
    /// auto-detectadas. `registerAccount` nelas não deve alterar
    /// `registeredAccounts`, mesmo retornando o provider detectado.
    func testRegisterAccountNaPastaPadraoNaoCadastra() {
        let state = AppState(defaults: freshDefaults())
        state.registerAccount(AppState.defaultConfigDir)
        XCTAssertTrue(state.registeredAccounts.isEmpty)

        state.registerAccount(AppState.defaultCodexConfigDir)
        XCTAssertTrue(state.registeredAccounts.isEmpty)
    }

    func testTasksPersistemEDecodificam() throws {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        let task = ScheduledTask(uid: UUID(), name: "bom dia",
                                 command: Message(text: "bom dia", kind: .claude),
                                 times: [8 * 60], weekdays: [2, 3, 4, 5, 6], enabled: true)
        state.tasks = [task]
        let reloaded = AppState(defaults: defaults)
        XCTAssertEqual(reloaded.tasks, [task])
    }

    func testResolvedCommandSemComandoCaiNoDefault() {
        let task = ScheduledTask(uid: UUID(), times: [600], weekdays: [1])
        XCTAssertEqual(task.resolvedCommand, AppState.defaultMessage)
    }

    func testNextTaskEntryEscolheAMenorData() {
        let state = AppState(defaults: freshDefaults())
        let t1 = ScheduledTask(uid: UUID(), name: "a", command: nil,
                               times: [480], weekdays: [2], enabled: true)
        let t2 = ScheduledTask(uid: UUID(), name: "b", command: nil,
                               times: [600], weekdays: [2], enabled: true)
        state.tasks = [t1, t2]
        state.nextTaskFires = [t1.uid: Date().addingTimeInterval(7200),
                               t2.uid: Date().addingTimeInterval(3600)]
        XCTAssertEqual(state.nextTaskEntry?.task.uid, t2.uid)
    }

    // MARK: - accountDir / activeScheduleCount

    func testAccountDirDeShellENil() {
        let state = AppState(defaults: freshDefaults())
        let task = ScheduledTask(uid: UUID(), command: Message(text: "ls", kind: .shell))
        XCTAssertNil(state.accountDir(for: task))
    }

    func testAccountDirComPastaSumidaENil() {
        let state = AppState(defaults: freshDefaults())
        var cmd = Message(text: "1+1", kind: .claude)
        cmd.configDir = "/tmp/nao-existe-\(UUID().uuidString)"
        let task = ScheduledTask(uid: UUID(), command: cmd)
        XCTAssertNil(state.accountDir(for: task))
    }

    func testAccountDirSemConfigDirCaiNoDefaultDoProvider() {
        let state = AppState(defaults: freshDefaults())
        let claude = ScheduledTask(uid: UUID(), command: Message(text: "1+1", kind: .claude))
        XCTAssertEqual(state.accountDir(for: claude),
                       AppState.defaultConfigDir.standardizedFileURL)
        let codex = ScheduledTask(uid: UUID(), command: Message(text: "1+1", kind: .codex))
        XCTAssertEqual(state.accountDir(for: codex),
                       AppState.defaultCodexConfigDir.standardizedFileURL)
    }

    func testActiveScheduleCountContaSoHabilitadosDaConta() throws {
        let state = AppState(defaults: freshDefaults())
        let conta = try makeAccountDir(signature: ".claude.json")
        var cmd = Message(text: "1+1", kind: .claude)
        cmd.configDir = conta.path
        state.tasks = [
            ScheduledTask(uid: UUID(), command: cmd, repetition: .continuous),
            ScheduledTask(uid: UUID(), command: cmd, times: [480], weekdays: Set(1...7)),
            {
                var t = ScheduledTask(uid: UUID(), command: cmd, times: [600], weekdays: [2])
                t.enabled = false
                return t
            }(),
            ScheduledTask(uid: UUID(), command: Message(text: "ls", kind: .shell)),
        ]
        XCTAssertEqual(state.activeScheduleCount(for: conta), 2)
    }

    func testEditorDetectaConflitoDeContinuoPorConta() throws {
        let state = AppState(defaults: freshDefaults())
        let conta = try makeAccountDir(signature: ".claude.json")
        var cmd = Message(text: "1+1", kind: .claude)
        cmd.configDir = conta.path
        let existente = ScheduledTask(uid: UUID(), command: cmd, repetition: .continuous)
        state.tasks = [existente]
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in true }
        )

        var candidato = ScheduledTask(uid: UUID(), command: cmd, repetition: .continuous)
        XCTAssertTrue(
            editor.evaluate(AgendamentoDraft(editing: candidato))
                .issues.contains(
                    .continuousConflict(existing: existente.uid)
                )
        )
        // Editar o próprio agendamento não conflita consigo mesmo.
        candidato.uid = existente.uid
        XCTAssertFalse(
            editor.evaluate(AgendamentoDraft(editing: candidato))
                .issues.contains {
                    if case .continuousConflict = $0 { return true }
                    return false
                }
        )
        // Repetição fixa nunca conflita.
        candidato.uid = UUID()
        candidato.repetition = .fixed
        XCTAssertTrue(
            editor.evaluate(AgendamentoDraft(editing: candidato))
                .issues.isEmpty
        )
        // O contrato é "no máximo um contínuo habilitado"; deve ser possível
        // salvar um duplicado desligado para depois corrigir/remover.
        candidato.repetition = .continuous
        candidato.enabled = false
        XCTAssertTrue(
            editor.evaluate(AgendamentoDraft(editing: candidato))
                .issues.isEmpty
        )
    }

    func testEditorRecusaHabilitarSegundoContinuoNaMesmaConta() throws {
        let state = AppState(defaults: freshDefaults())
        let conta = try makeAccountDir(signature: ".claude.json")
        var cmd = Message(text: "1+1", kind: .claude)
        cmd.configDir = conta.path
        let habilitado = ScheduledTask(uid: UUID(), command: cmd, repetition: .continuous)
        var desabilitado = ScheduledTask(uid: UUID(), command: cmd, repetition: .continuous)
        desabilitado.enabled = false
        let fixo = ScheduledTask(uid: UUID(), command: cmd, times: [480], weekdays: Set(1...7))
        state.tasks = [habilitado, desabilitado, fixo]
        let editor = AgendamentoEditor(state: state)

        // Habilitar um 2º contínuo na mesma conta é recusado; o task fica off.
        XCTAssertEqual(
            editor.apply(
                .setEnabled(id: desabilitado.uid, enabled: true)
            ),
            .failure(.invalid([
                .continuousConflict(existing: habilitado.uid),
            ]))
        )
        XCTAssertFalse(state.tasks.first { $0.uid == desabilitado.uid }!.enabled)
        // Habilitar um fixo na mesma conta é permitido.
        XCTAssertEqual(
            editor.apply(.setEnabled(id: fixo.uid, enabled: true)),
            .success(.enabled(fixo.uid, true))
        )
        // Desabilitar qualquer um é sempre permitido.
        XCTAssertEqual(
            editor.apply(
                .setEnabled(id: habilitado.uid, enabled: false)
            ),
            .success(.enabled(habilitado.uid, false))
        )
        XCTAssertFalse(state.tasks.first { $0.uid == habilitado.uid }!.enabled)
        // Com o 1º já off, o 2º contínuo pode ligar.
        XCTAssertEqual(
            editor.apply(
                .setEnabled(id: desabilitado.uid, enabled: true)
            ),
            .success(.enabled(desabilitado.uid, true))
        )
    }

    func testRecordMissingFolderContinuousGravaUmaVezPorAgendamento() throws {
        let state = AppState(defaults: freshDefaults())
        var cmd = Message(text: "1+1", kind: .claude)
        cmd.configDir = "/tmp/nao-existe-\(UUID().uuidString)"
        state.tasks = [ScheduledTask(uid: UUID(), command: cmd, repetition: .continuous)]

        state.recordMissingFolderContinuous()
        XCTAssertEqual(state.history.count, 1)
        guard case .failure(let msg) = state.history.first?.result else {
            return XCTFail("esperava falha no histórico")
        }
        XCTAssertEqual(msg, state.strings.accountFolderMissingEvent)
        XCTAssertEqual(state.history.first?.origin, .renewal)
        // Idempotente: reconfigure repetido não duplica.
        state.recordMissingFolderContinuous()
        XCTAssertEqual(state.history.count, 1)
    }

    func testRecordMissingFolderContinuousIgnoraPastaExistenteEFixoEShell() throws {
        let state = AppState(defaults: freshDefaults())
        let conta = try makeAccountDir(signature: ".claude.json")
        var claudeOk = Message(text: "1+1", kind: .claude); claudeOk.configDir = conta.path
        var claudeFixo = Message(text: "1+1", kind: .claude)
        claudeFixo.configDir = "/tmp/nao-existe-\(UUID().uuidString)"
        state.tasks = [
            ScheduledTask(uid: UUID(), command: claudeOk, repetition: .continuous),
            ScheduledTask(uid: UUID(), command: claudeFixo, times: [480], weekdays: Set(1...7)),
            ScheduledTask(uid: UUID(), command: Message(text: "ls", kind: .shell), repetition: .continuous),
        ]
        state.recordMissingFolderContinuous()
        XCTAssertTrue(state.history.isEmpty)
    }

    func testEmailCacheAtualizaQuandoCredencialMuda() throws {
        let conta = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-email-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: conta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: conta) }
        let config = conta.appendingPathComponent(".claude.json")
        func writeEmail(_ email: String, modificationDate: Date) throws {
            let json = ["oauthAccount": ["emailAddress": email]]
            try JSONSerialization.data(withJSONObject: json).write(to: config, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate], ofItemAtPath: config.path)
        }

        let state = AppState(defaults: freshDefaults())
        try writeEmail("antes@example.com", modificationDate: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(state.email(for: conta), "antes@example.com")
        try writeEmail("depois@example.com", modificationDate: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(state.email(for: conta), "depois@example.com")
    }

    func testContaClaudeNativaLeIdentidadeDoClaudeJsonNoHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-home-\(UUID().uuidString)")
        let nativeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: nativeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let native = ["oauthAccount": ["emailAddress": "nativa@example.com"]]
        try JSONSerialization.data(withJSONObject: native)
            .write(to: home.appendingPathComponent(".claude.json"))
        let nested = ["oauthAccount": ["emailAddress": "arquivo-errado@example.com"]]
        try JSONSerialization.data(withJSONObject: nested)
            .write(to: nativeDir.appendingPathComponent(".claude.json"))
        let state = AppState(defaults: freshDefaults(), home: home)

        XCTAssertEqual(state.email(for: nativeDir), "nativa@example.com")
    }

    func testEventoClaudeCapturaContaProviderModeloEIdentidade() throws {
        let conta = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-event-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: conta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: conta) }
        let json = ["oauthAccount": ["emailAddress": "antes@example.com"]]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: conta.appendingPathComponent(".claude.json"))
        let state = AppState(defaults: freshDefaults())
        state.setAlias(conta, "Trabalho")
        let message = Message(text: "revise", kind: .claude, model: .opus,
                              configDir: conta.path)

        let event = state.makeEvent(date: Date(timeIntervalSince1970: 1),
                                    result: .success, message: message, origin: .agenda)

        XCTAssertEqual(event.accountPath, conta.standardizedFileURL.path)
        XCTAssertEqual(event.provider, .claude)
        XCTAssertEqual(event.modelName, "Opus 4.8")
        XCTAssertEqual(event.aliasSnapshot, "Trabalho")
        XCTAssertEqual(event.emailSnapshot, "antes@example.com")
    }

    func testIdentidadeDoEventoPrefereDadosAtuaisESnapshotEhFallback() {
        let state = AppState(defaults: freshDefaults())
        let conta = URL(fileURLWithPath: "/tmp/ohayo-removida-\(UUID().uuidString)")
        let event = FireEvent(date: Date(), result: .success, account: conta.lastPathComponent,
                              accountPath: conta.path, provider: .codex,
                              modelName: "gpt-5.3-codex", aliasSnapshot: "Pessoal",
                              emailSnapshot: "snapshot@example.com")

        XCTAssertEqual(state.identity(for: event), EventIdentity(
            accountName: conta.lastPathComponent, alias: "Pessoal",
            email: "snapshot@example.com", provider: .codex,
            modelName: "gpt-5.3-codex"))

        state.setAlias(conta, "Atual")
        XCTAssertEqual(state.identity(for: event).displayName, "Atual")
    }

    func testEventoCodexEShellGuardamSomenteMetadadosAplicaveis() {
        let state = AppState(defaults: freshDefaults())
        let codex = state.makeEvent(date: Date(), result: .success,
                                    message: Message(text: "oi", kind: .codex,
                                                     codexModel: "gpt-5.3-codex"),
                                    origin: .agenda)
        XCTAssertEqual(codex.provider, .codex)
        XCTAssertEqual(codex.modelName, "gpt-5.3-codex")

        let shell = state.makeEvent(date: Date(), result: .success,
                                    message: Message(text: "echo oi", kind: .shell),
                                    origin: .agenda)
        XCTAssertNil(shell.account)
        XCTAssertNil(shell.accountPath)
        XCTAssertNil(shell.provider)
        XCTAssertNil(shell.modelName)
    }

    // MARK: - Pause por conta

    func testSetPausedPersisteEIsPausedLe() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        let dir = AppState.defaultConfigDir
        XCTAssertFalse(state.isPaused(dir))
        state.setPaused(dir, true)
        XCTAssertTrue(state.isPaused(dir))
        // Persistência: um segundo AppState no mesmo suite lê o mesmo valor.
        let reloaded = AppState(defaults: defaults)
        XCTAssertTrue(reloaded.isPaused(dir))
        state.setPaused(dir, false)
        XCTAssertFalse(state.isPaused(dir))
    }

    func testAllScheduledAccountsPaused() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        var task = ScheduledTask(uid: UUID(), command: AppState.defaultMessage)
        task.repetition = .continuous
        state.tasks = [task]
        XCTAssertFalse(state.allScheduledAccountsPaused)
        state.setPaused(AppState.defaultConfigDir, true)
        XCTAssertTrue(state.allScheduledAccountsPaused)
        // Sem nenhuma conta agendada, não conta como "tudo pausado".
        state.tasks = []
        XCTAssertFalse(state.allScheduledAccountsPaused)
    }

    func testAllScheduledAccountsPausedNaoIgnoraContaComPastaAusente() throws {
        let state = AppState(defaults: freshDefaults())
        let available = try makeAccountDir()
        defer { try? FileManager.default.removeItem(at: available) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-missing-\(UUID().uuidString)")
        let availableTask = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "available",
                kind: .claude,
                configDir: available.path
            )
        )
        let missingTask = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "missing",
                kind: .claude,
                configDir: missing.path
            )
        )
        state.tasks = [availableTask, missingTask]
        state.setPaused(available, true)

        XCTAssertFalse(state.allScheduledAccountsPaused)
    }

    func testIdentidadeVisualDoHorarioPreservaContaComPastaAusente() {
        let state = AppState(defaults: freshDefaults())
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-missing-\(UUID().uuidString)")
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "status",
                kind: .claude,
                configDir: missing.path
            )
        )

        XCTAssertEqual(
            HorariosView.accountIdentity(for: task, in: state),
            missing.standardizedFileURL
        )
    }

    // MARK: - Filtro de conta (deep-link do painel)

    func testMatchesFilterPorAccountPath() {
        let state = AppState(defaults: freshDefaults())
        let event = FireEvent(date: Date(), result: .success,
                              accountPath: AppState.defaultConfigDir.standardizedFileURL.path)
        XCTAssertTrue(state.matchesFilter(event)) // sem filtro, tudo passa
        state.accountFilter = AppState.defaultConfigDir
        XCTAssertTrue(state.matchesFilter(event))
        state.accountFilter = AppState.defaultCodexConfigDir
        XCTAssertFalse(state.matchesFilter(event))
    }

    func testTaskMatchesFilter() {
        let state = AppState(defaults: freshDefaults())
        let task = ScheduledTask(uid: UUID(), command: AppState.defaultMessage)
        XCTAssertTrue(state.taskMatchesFilter(task))
        state.accountFilter = AppState.defaultConfigDir
        XCTAssertTrue(state.taskMatchesFilter(task))
        state.accountFilter = AppState.defaultCodexConfigDir
        XCTAssertFalse(state.taskMatchesFilter(task))
    }

    func testInitPreservaHistoricoDecodificavelQuandoUmEventoEstaCorrompido() throws {
        // Como em `tasks`: um evento corrompido no blob de histórico não pode
        // derrubar o array inteiro (que cairia no fallback do `lastEvent` e
        // perderia todo o histórico). Decode lossy: o evento ruim some, os bons
        // sobrevivem.
        let d = freshDefaults()
        let valido = FireEvent(date: Date(timeIntervalSince1970: 1_783_000_000),
                               result: .success, account: ".claude")
        let validoJSON = try String(data: JSONEncoder().encode(valido), encoding: .utf8)
            .map { $0 } ?? ""
        let blob = "[\(validoJSON),{\"lixo\":1}]"
        d.set(Data(blob.utf8), forKey: "history")

        let state = AppState(defaults: d)

        XCTAssertEqual(state.history.count, 1)
        XCTAssertEqual(state.history.first?.account, ".claude")
    }

    func testInitPreservaAgendamentosDecodificaveisQuandoUmItemEstaCorrompido() {
        // Regressão de perda de dados: o decode de [ScheduledTask] é tudo-ou-nada.
        // Um único item com raw value desconhecido (ex.: usuário criou um
        // agendamento numa build futura com um novo case de Repetition e depois
        // voltou para esta build via downgrade) fazia o array inteiro lançar,
        // apagando TODAS as renovações — e a primeira mutação persistia []
        // por cima do blob antigo. O decode deve ser lossy: o item ilegível
        // some, os bons sobrevivem.
        let d = freshDefaults()
        let bom = UUID()
        let blob = """
        [{"uid":"\(bom.uuidString)","repetition":"continuous"},
         {"uid":"\(UUID().uuidString)","repetition":"quinzenal"}]
        """
        d.set(Data(blob.utf8), forKey: "tasks")

        let state = AppState(defaults: d)

        XCTAssertEqual(state.tasks.map(\.uid), [bom])
    }

    func testBootstrapContinuoLegadoLigaAutomaticamenteEFalsePersiste() throws {
        let legado = try JSONDecoder().decode(
            ScheduledTask.self,
            from: Data("""
            {"uid":"\(UUID().uuidString)","repetition":"continuous"}
            """.utf8)
        )
        XCTAssertNil(legado.bootstrapWhenInactive)
        XCTAssertTrue(legado.resolvedBootstrapWhenInactive)

        var optOut = legado
        optOut.bootstrapWhenInactive = false
        let recarregado = try JSONDecoder().decode(
            ScheduledTask.self,
            from: JSONEncoder().encode(optOut)
        )
        XCTAssertEqual(recarregado.bootstrapWhenInactive, false)
        XCTAssertFalse(recarregado.resolvedBootstrapWhenInactive)
    }

    func testCooldownTipadoPersisteEntreInstancias() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        state.tasks = [task]

        let recovery = RenewalRecoveryState.cooldown(
            notBefore: now.addingTimeInterval(
                SessionDetector.blockDuration
            ),
            bootstrapOrigin: true
        )
        state.setRenewalRecoveryState(recovery, for: task)
        XCTAssertEqual(state.renewalRecoveryState(for: task), recovery)

        let reloaded = AppState(defaults: defaults)
        XCTAssertEqual(reloaded.renewalRecoveryState(for: task), recovery)
    }

    func testEditarRevisaoPreservaSomenteLeaseDeCooldown() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        var cooldownTask = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        var retryTask = cooldownTask
        retryTask.uid = UUID()
        var attentionTask = cooldownTask
        attentionTask.uid = UUID()
        cooldownTask.bootstrapWhenInactive = true
        retryTask.bootstrapWhenInactive = true
        attentionTask.bootstrapWhenInactive = true
        state.tasks = [cooldownTask, retryTask, attentionTask]
        let deadline = Date().addingTimeInterval(300)
        let cooldown = RenewalRecoveryState.cooldown(
            notBefore: deadline,
            bootstrapOrigin: true
        )
        state.setRenewalRecoveryState(cooldown, for: cooldownTask)
        state.setRenewalRecoveryState(
            .retry(
                notBefore: deadline,
                attempt: 2,
                bootstrapOrigin: true
            ),
            for: retryTask
        )
        state.setRenewalRecoveryState(
            .needsAttention(bootstrapOrigin: true),
            for: attentionTask
        )

        cooldownTask.command?.text = "editada-cooldown"
        retryTask.command?.text = "editada-retry"
        attentionTask.command?.text = "editada-attention"
        state.tasks = [cooldownTask, retryTask, attentionTask]

        let reloaded = AppState(defaults: defaults)
        XCTAssertEqual(
            reloaded.renewalRecoveryState(for: cooldownTask),
            cooldown
        )
        XCTAssertNil(reloaded.renewalRecoveryState(for: retryTask))
        XCTAssertNil(reloaded.renewalRecoveryState(for: attentionTask))
    }

    func testRecoveryTipadoPersisteRetryENeedsAttention() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)
        var bootstrap = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        bootstrap.bootstrapWhenInactive = true
        let scheduled = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        state.tasks = [bootstrap, scheduled]
        let retryAt = Date().addingTimeInterval(90)
        state.setRenewalRecoveryState(
            .retry(
                notBefore: retryAt,
                attempt: 3,
                bootstrapOrigin: true
            ),
            for: bootstrap
        )
        state.setRenewalRecoveryState(
            .needsAttention(bootstrapOrigin: false),
            for: scheduled
        )

        let reloaded = AppState(defaults: defaults)
        let byUID = Dictionary(
            uniqueKeysWithValues: reloaded.tasks.map { ($0.uid, $0) }
        )
        XCTAssertEqual(
            reloaded.renewalRecoveryState(
                for: try! XCTUnwrap(byUID[bootstrap.uid])
            ),
            .retry(
                notBefore: retryAt,
                attempt: 3,
                bootstrapOrigin: true
            )
        )
        XCTAssertEqual(
            reloaded.renewalRecoveryState(
                for: try! XCTUnwrap(byUID[scheduled.uid])
            ),
            .needsAttention(bootstrapOrigin: false)
        )
    }

    func testRecoveryCorrompidoPreservaEntradaValidaEBloqueiaInvalida() throws {
        let defaults = freshDefaults()
        var validTask = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        validTask.bootstrapWhenInactive = true
        let invalidTask = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        defaults.set(
            try JSONEncoder().encode([validTask, invalidTask]),
            forKey: "tasks"
        )
        let accountPath = ProviderAccountContext.canonicalAccountDirectory(
            AppState.defaultConfigDir
        ).path
        let validKey = "\(validTask.uid.uuidString)|\(accountPath)"
        let invalidKey = "\(invalidTask.uid.uuidString)|\(accountPath)"
        let retry = RenewalRecoveryState.retry(
            notBefore: Date().addingTimeInterval(90),
            attempt: 2,
            bootstrapOrigin: true
        )
        let validObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(retry)
        )
        let blob: [String: Any] = [
            validKey: validObject,
            invalidKey: [
                "futureCase": ["bootstrapOrigin": false]
            ],
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: blob),
            forKey: "renewalRecoveryStates"
        )

        let state = AppState(defaults: defaults)

        XCTAssertEqual(
            state.renewalRecoveryState(for: validTask),
            retry
        )
        XCTAssertEqual(
            state.renewalRecoveryState(for: invalidTask),
            .needsAttention(bootstrapOrigin: false)
        )
    }

    func testRecoveryComBlobTotalmenteCorrompidoFalhaFechado() throws {
        let defaults = freshDefaults()
        let task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        defaults.set(try JSONEncoder().encode([task]), forKey: "tasks")
        defaults.set(
            Data("{not-json".utf8),
            forKey: "renewalRecoveryStates"
        )

        let state = AppState(defaults: defaults)

        XCTAssertEqual(
            state.renewalRecoveryState(for: task),
            .needsAttention(bootstrapOrigin: false)
        )
    }

    func testDowngradePreservaRecoveryDeTaskQueAindaNaoDecodifica() throws {
        let defaults = freshDefaults()
        let known = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        let future = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultCodexMessage,
            repetition: .continuous
        )
        let encodedTasks = try JSONEncoder().encode([known, future])
        var taskObjects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedTasks)
                as? [[String: Any]]
        )
        taskObjects[1]["repetition"] = "future-continuous"
        defaults.set(
            try JSONSerialization.data(withJSONObject: taskObjects),
            forKey: "tasks"
        )
        let recovery = RenewalRecoveryState.cooldown(
            notBefore: Date().addingTimeInterval(300),
            bootstrapOrigin: false
        )
        let futurePath = ProviderAccountContext.canonicalAccountDirectory(
            AppState.defaultCodexConfigDir
        ).path
        let key = "\(future.uid.uuidString)|\(futurePath)"
        defaults.set(
            try JSONEncoder().encode([key: recovery]),
            forKey: "renewalRecoveryStates"
        )

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.tasks.map(\.uid), [known.uid])
        XCTAssertEqual(
            state.renewalRecoveryState(for: future),
            recovery
        )
    }

    func testToggleDeBootstrapPreservaRecoveryDeOrigemAgendada() {
        let state = AppState(defaults: freshDefaults())
        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        state.tasks = [task]
        let recovery = RenewalRecoveryState.cooldown(
            notBefore: Date().addingTimeInterval(300),
            bootstrapOrigin: false
        )
        state.setRenewalRecoveryState(recovery, for: task)

        task.bootstrapWhenInactive = false
        state.tasks = [task]
        XCTAssertEqual(
            state.renewalRecoveryState(for: task),
            recovery
        )

        task.bootstrapWhenInactive = true
        state.tasks = [task]
        XCTAssertEqual(
            state.renewalRecoveryState(for: task),
            recovery
        )
    }

    func testRecoverySobreviveEnquantoContaExplicitaEstaOffline() {
        let defaults = freshDefaults()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-\(UUID().uuidString)")
        var task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "status",
                kind: .claude,
                configDir: missing.path
            ),
            repetition: .continuous
        )
        let state = AppState(defaults: defaults)
        state.tasks = [task]
        let recovery = RenewalRecoveryState.needsAttention(
            bootstrapOrigin: false
        )
        state.setRenewalRecoveryState(recovery, for: task)

        task.name = "renomeada"
        state.tasks = [task]
        let reloaded = AppState(defaults: defaults)

        XCTAssertEqual(
            reloaded.renewalRecoveryState(for: task),
            recovery
        )
    }

    func testUIDContinuoDuplicadoNaoCausaTrapNaLimpezaDeRecovery() {
        let state = AppState(defaults: freshDefaults())
        let uid = UUID()
        let first = ScheduledTask(
            uid: uid,
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        var duplicate = first
        duplicate.name = "duplicado"

        state.tasks = [first, duplicate]
        state.tasks.append(
            ScheduledTask(
                uid: UUID(),
                command: AppState.defaultMessage,
                repetition: .fixed
            )
        )

        XCTAssertEqual(state.tasks.count, 3)
    }

    func testCooldownNaoVazaQuandoTaskMudaDeConta() {
        let state = AppState(defaults: freshDefaults())
        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        state.setRenewalRecoveryState(
            .cooldown(
                notBefore: now.addingTimeInterval(
                    SessionDetector.blockDuration
                ),
                bootstrapOrigin: true
            ),
            for: task
        )

        task.command = AppState.defaultCodexMessage

        XCTAssertNil(state.renewalRecoveryState(for: task))
    }

    func testRevogarEReativarOptInLimpaCooldownAnterior() {
        let state = AppState(defaults: freshDefaults())
        var task = ScheduledTask(
            uid: UUID(),
            command: AppState.defaultMessage,
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        state.tasks = [task]
        state.setRenewalRecoveryState(
            .cooldown(
                notBefore: now.addingTimeInterval(
                    SessionDetector.blockDuration
                ),
                bootstrapOrigin: true
            ),
            for: task
        )
        XCTAssertNotNil(state.renewalRecoveryState(for: task))

        task.bootstrapWhenInactive = false
        state.tasks = [task]
        task.bootstrapWhenInactive = true
        state.tasks = [task]

        XCTAssertNil(state.renewalRecoveryState(for: task))
    }

    func testContaRealESymlinkCompartilhamIdentidadeDeConflito() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-account-alias-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try fm.createDirectory(
            at: real.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? fm.removeItem(at: root) }

        let state = AppState(defaults: freshDefaults())
        let existing = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "A",
                kind: .claude,
                configDir: real.path
            ),
            repetition: .continuous
        )
        let candidate = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "B",
                kind: .claude,
                configDir: alias.path
            ),
            repetition: .continuous
        )
        state.tasks = [existing]

        XCTAssertEqual(
            state.accountDir(for: existing),
            state.accountDir(for: candidate)
        )
        XCTAssertTrue(
            AgendamentoEditor(state: state)
                .evaluate(AgendamentoDraft(editing: candidate))
                .issues.contains(
                    .continuousConflict(existing: existing.uid)
                )
        )
    }

    func testContaOfflineAindaParticipaDeConflitoFiltroEContagem() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-conflict-\(UUID().uuidString)")
        let state = AppState(defaults: freshDefaults())
        let existing = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "A",
                kind: .claude,
                configDir: missing.path
            ),
            repetition: .continuous
        )
        let candidate = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "B",
                kind: .claude,
                configDir: missing.path
            ),
            repetition: .continuous
        )
        state.tasks = [existing]
        state.accountFilter = missing

        XCTAssertNil(state.accountDir(for: existing))
        XCTAssertEqual(state.intendedAccountDir(for: existing), missing)
        XCTAssertTrue(
            AgendamentoEditor(
                state: state,
                isDirectory: { _ in false }
            )
            .evaluate(AgendamentoDraft(editing: candidate))
            .issues.contains(
                .continuousConflict(existing: existing.uid)
            )
        )
        XCTAssertTrue(state.taskMatchesFilter(existing))
        XCTAssertEqual(state.activeScheduleCount(for: missing), 1)
    }

    func testCadastroPorSymlinkNaoDuplicaContaReal() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-account-register-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try fm.createDirectory(
            at: real.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? fm.removeItem(at: root) }
        let state = AppState(defaults: freshDefaults())

        XCTAssertEqual(state.registerAccount(real), .claude)
        XCTAssertEqual(state.registerAccount(alias), .claude)

        XCTAssertEqual(state.registeredAccounts, [real.path])
    }

    func testDefaultSymlinkEhCanonicoENaoViraCadastroDuplicado() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-default-alias-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let real = root.appendingPathComponent("claude-real")
        let alias = home.appendingPathComponent(".claude")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: real.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? fm.removeItem(at: root) }
        let state = AppState(defaults: freshDefaults(), home: home)
        let canonicalReal =
            ProviderAccountContext.canonicalAccountDirectory(real)

        XCTAssertEqual(state.discoverAccounts(), [canonicalReal])
        XCTAssertEqual(state.registerAccount(alias), .claude)
        XCTAssertEqual(state.registeredAccounts, [])
        XCTAssertEqual(state.discoverAccounts(), [canonicalReal])
    }

    func testProviderPersistidoVenceAssinaturaAmbiguaTemporaria() throws {
        let account = try makeAccountDir(
            signature: ".claude.json",
            subdir: "sessions"
        )
        defer { try? FileManager.default.removeItem(at: account) }
        let defaults = freshDefaults()
        defaults.set([account.path], forKey: "registeredAccounts")
        defaults.set(
            [account.path: Provider.codex.rawValue],
            forKey: "registeredAccountProviders"
        )

        let state = AppState(defaults: defaults)

        XCTAssertEqual(Provider.detect(at: account), .claude)
        XCTAssertEqual(state.provider(for: account), .codex)
    }

    func testInitMigraChavesPersistidasDeSymlinkParaContaCanonica() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-account-migrate-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try fm.createDirectory(
            at: real.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? fm.removeItem(at: root) }
        let defaults = freshDefaults()
        defaults.set([alias.path], forKey: "registeredAccounts")
        defaults.set(
            [alias.path: Provider.claude.rawValue],
            forKey: "registeredAccountProviders"
        )
        defaults.set([alias.path: "Conta"], forKey: "aliases")
        defaults.set([alias.path], forKey: "pausedAccounts")

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.registeredAccounts, [real.path])
        XCTAssertEqual(state.provider(for: real), .claude)
        XCTAssertEqual(state.alias(for: real), "Conta")
        XCTAssertTrue(state.isPaused(real))
        XCTAssertEqual(
            defaults.stringArray(forKey: "registeredAccounts"),
            [real.path]
        )
    }

    func testInitMigraCooldownERestauraTaskDeSymlinkSemTrocarConta() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-task-alias-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try fm.createDirectory(
            at: real.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? fm.removeItem(at: root) }

        let defaults = freshDefaults()
        defaults.set([real.path], forKey: "registeredAccounts")
        defaults.set(
            [real.path: Provider.claude.rawValue],
            forKey: "registeredAccountProviders"
        )
        var task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "revisa",
                kind: .claude,
                configDir: alias.path
            ),
            repetition: .continuous
        )
        task.bootstrapWhenInactive = true
        let originalTasksData = try JSONEncoder().encode([task])
        defaults.set(originalTasksData, forKey: "tasks")
        let attemptedAt = Date()
        defaults.set(
            ["\(task.uid.uuidString)|\(alias.path)": attemptedAt],
            forKey: "bootstrapAttempts"
        )

        let state = AppState(defaults: defaults)
        let migrated = try XCTUnwrap(state.tasks.first)
        // O blob original não é re-encodado no launch (preserva campos de uma
        // versão futura em caso de downgrade). A normalização ocorre na borda
        // de identidade e no formulário.
        XCTAssertEqual(migrated.resolvedCommand.configDir, alias.path)
        XCTAssertEqual(
            state.renewalRecoveryState(for: migrated),
            .cooldown(
                notBefore: attemptedAt.addingTimeInterval(
                    SessionDetector.blockDuration
                ),
                bootstrapOrigin: true
            )
        )

        let restored = AgendamentoDraft(editing: migrated)
        XCTAssertEqual(restored.account, real.path)
        XCTAssertEqual(
            restored.normalizedTask().resolvedCommand.configDir,
            real.path
        )

        XCTAssertEqual(defaults.data(forKey: "tasks"), originalTasksData)
    }

    func testPermissionGuideStartsUndismissed() {
        let state = AppState(defaults: freshDefaults())
        XCTAssertFalse(state.hasDismissedPermissionGuide)
    }

    func testPermissionGuideDismissalPersists() {
        let defaults = freshDefaults()
        let state = AppState(defaults: defaults)

        state.dismissPermissionGuide()

        XCTAssertTrue(state.hasDismissedPermissionGuide)
        XCTAssertTrue(AppState(defaults: defaults).hasDismissedPermissionGuide)
    }
}
