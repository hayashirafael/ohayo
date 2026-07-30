import XCTest
@testable import Ohayo

final class SessionDetectorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_783_000_000)

    func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

    func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func claudeUsageLine(timestamp: String) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"claude-sonnet","usage":{"input_tokens":1,"output_tokens":1}}}
        """
    }

    func codexUsageLine(timestamp: String) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"last_token_usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}}
        """
    }

    // Algoritmo puro de blocos

    func testSemMensagensNaoHaJanela() {
        XCTAssertNil(SessionDetector.activeBlockEnd(timestamps: [], now: now))
    }

    func testMensagemRecenteAbreJanelaDe5h() {
        let msg = hoursAgo(1)
        let end = SessionDetector.activeBlockEnd(timestamps: [msg], now: now)
        XCTAssertEqual(end, msg.addingTimeInterval(5 * 3600))
    }

    func testAlgoritmoAceitaDuracaoEspecificaDoProvider() {
        let msg = hoursAgo(1)
        let duration: TimeInterval = 3 * 3600
        let end = SessionDetector.activeBlockEnd(
            timestamps: [msg],
            now: now,
            duration: duration
        )
        XCTAssertEqual(end, msg.addingTimeInterval(duration))
    }

    func testMensagemAntigaNaoConta() {
        XCTAssertNil(SessionDetector.activeBlockEnd(timestamps: [hoursAgo(6)], now: now))
    }

    func testBlocosEncadeadosUsamOInicioDoBlocoCorrente() {
        // Atividade contínua: bloco 1 começa há ~9h e expira; bloco 2 começa
        // na primeira mensagem após o fim do bloco 1.
        let b1first = hoursAgo(9)
        let b1end = b1first.addingTimeInterval(5 * 3600)
        let b2first = b1end.addingTimeInterval(600) // 10min após o fim do bloco 1
        let end = SessionDetector.activeBlockEnd(timestamps: [b1first, hoursAgo(7), b2first, hoursAgo(1)], now: now)
        XCTAssertEqual(end, b2first.addingTimeInterval(5 * 3600))
    }

    // Parsing de linha JSONL

    func testParseTimestampComFracao() {
        let line = #"{"type":"user","timestamp":"2026-07-07T10:00:00.123Z","message":{}}"#
        XCTAssertNotNil(SessionDetector.timestamp(fromLine: line))
    }

    func testParseTimestampSemFracao() {
        let line = #"{"type":"user","timestamp":"2026-07-07T10:00:00Z"}"#
        XCTAssertNotNil(SessionDetector.timestamp(fromLine: line))
    }

    func testLinhaSemTimestampRetornaNil() {
        XCTAssertNil(SessionDetector.timestamp(fromLine: "{\"type\":\"summary\"}"))
        XCTAssertNil(SessionDetector.timestamp(fromLine: "lixo não-json"))
    }

    // Integração: varredura de diretório com fixtures

    func testEvidenciaClaudeValidaRetornaJanelaAtivaTipada() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let projetos = conta.appendingPathComponent("projects/projeto")
        try fm.createDirectory(at: projetos, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }
        let inicio = hoursAgo(1)
        try claudeUsageLine(timestamp: ISO8601DateFormatter().string(from: inicio))
            .write(
                to: projetos.appendingPathComponent("sessao.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let state = await SessionDetector(clock: FakeClock(now: now))
            .quotaWindowState(account: conta)

        XCTAssertEqual(
            state,
            .active(until: inicio.addingTimeInterval(5 * 3600))
        )
    }

    func testVarreduraDetectaJanelaAtivaEIgnoraArquivoAntigo() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory.appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let proj = conta.appendingPathComponent("projects/proj-a")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: Date().addingTimeInterval(-1800))
        try "\(claudeUsageLine(timestamp: recent))\n"
            .write(to: proj.appendingPathComponent("sessao.jsonl"), atomically: true, encoding: .utf8)

        // Arquivo com mtime antigo deve ser ignorado sem ser lido
        let oldFile = proj.appendingPathComponent("antiga.jsonl")
        try "\(claudeUsageLine(timestamp: recent))\n"
            .write(to: oldFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 3600)], ofItemAtPath: oldFile.path)

        let detector = SessionDetector(clock: SystemClock())
        let end = await detector.activeWindowEnd(account: conta)
        XCTAssertNotNil(end)
        XCTAssertGreaterThan(end!, Date())
    }

    func testDiretorioInexistenteRetornaNil() async {
        let detector = SessionDetector(clock: SystemClock())
        let end = await detector.activeWindowEnd(
            account: URL(fileURLWithPath: "/nao/existe/\(UUID().uuidString)"))
        XCTAssertNil(end)
    }

    func testClaudeErroSinteticoEUsoZeroNaoAbremJanela() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory.appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let proj = conta.appendingPathComponent("projects/proj-a")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }

        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let transcript = """
        {"type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":"ping"}}
        {"type":"assistant","timestamp":"\(timestamp)","isApiErrorMessage":true,"message":{"model":"claude-sonnet","usage":{"input_tokens":10,"output_tokens":1}}}
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"<synthetic>","usage":{"input_tokens":10,"output_tokens":1}}}
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"claude-sonnet","usage":{"input_tokens":0,"output_tokens":0}}}
        """
        try transcript.write(
            to: proj.appendingPathComponent("erro.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let state = await SessionDetector().quotaWindowState(account: conta)
        XCTAssertEqual(state, .inactive)
    }

    func testSchemaDeUsageClaudeDesconhecidoFicaIndisponivel() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let projetos = conta.appendingPathComponent("projects/projeto")
        try fm.createDirectory(at: projetos, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"claude-sonnet","usage":{"input":1,"output":1}}}
        """.write(
            to: projetos.appendingPathComponent("schema-novo.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let state = await SessionDetector().quotaWindowState(account: conta)

        XCTAssertEqual(
            state,
            .unavailable(reason: "unsupported Claude usage schema")
        )
    }

    func testEnvelopeAssistantClaudeDesconhecidoFicaIndisponivel() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let projetos = conta.appendingPathComponent("projects/projeto")
        try fm.createDirectory(at: projetos, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try """
        {"type":"assistant","timestamp":"\(timestamp)","message_v2":{"model":"claude-sonnet","usage":{"input_tokens":1}}}
        """.write(
            to: projetos.appendingPathComponent("envelope-novo.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let state = await SessionDetector().quotaWindowState(
            account: conta,
            provider: .claude
        )

        XCTAssertEqual(
            state,
            .unavailable(reason: "unsupported Claude assistant schema")
        )
    }

    func testCaminhoDaContaQueNaoEhDiretorioFicaIndisponivel() async throws {
        let conta = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-account-file-\(UUID().uuidString)")
        try "not a directory".write(
            to: conta,
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: conta) }

        let state = await SessionDetector().quotaWindowState(
            account: conta,
            provider: .claude
        )

        XCTAssertEqual(
            state,
            .unavailable(reason: "account path is not a directory")
        )
    }

    func testClaudeUsaTimestampRaizDaEvidenciaDeConsumo() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory.appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let proj = conta.appendingPathComponent("projects/proj-a")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }

        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let transcript = """
        {"type":"assistant","message":{"model":"claude-sonnet","content":[{"timestamp":"2020-01-01T00:00:00Z"}],"usage":{"input_tokens":10,"output_tokens":1}},"timestamp":"\(recent)"}
        """
        try transcript.write(
            to: proj.appendingPathComponent("consumo.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let end = await SessionDetector().activeWindowEnd(account: conta)
        XCTAssertNotNil(end)
    }

    func testCadeiaContinuaTruncadaPelaJanelaDeVarredura() async throws {
        // Cadeia contínua (10 em 10 min) das últimas 30h: a varredura fixa de
        // 24h truncaria no meio de um bloco. O detector deve ampliar a
        // varredura e devolver o mesmo fim de bloco do histórico completo.
        let fm = FileManager.default
        let conta = fm.temporaryDirectory.appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let proj = conta.appendingPathComponent("projects/proj-a")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)

        // Sem fração de segundo: o formatter abaixo grava/lê só a resolução do
        // segundo (trunca ao escrever), e a regra exata agora compara
        // timestamps sem a tolerância da hora cheia — sem este truncamento
        // aqui, "agora" (com fração) nunca bateria com o valor lido do disco.
        let agora = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let iso = ISO8601DateFormatter()
        var todas: [Date] = []
        var linhas = ""
        var t = agora.addingTimeInterval(-30 * 3600)
        while t <= agora {
            todas.append(t)
            linhas += "\(claudeUsageLine(timestamp: iso.string(from: t)))\n"
            t = t.addingTimeInterval(600)
        }
        try linhas.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let detector = SessionDetector(clock: SystemClock())
        let end = await detector.activeWindowEnd(account: conta)
        XCTAssertNotNil(end)
        XCTAssertEqual(end, SessionDetector.activeBlockEnd(timestamps: todas, now: agora))
    }

    func testCadeiaAlemDe7DiasParaNoTetoDeLookback() async throws {
        // Cadeia contínua (10 em 10 min) das últimas ~8 dias, sem gap de 5h: o
        // loop de ampliação do lookback dobra 24h→48h→…, mas nunca acha o gap
        // de 5h à esquerda, então deve PARAR no teto (maxLookback = 7 dias) em
        // vez de crescer para sempre — e ainda devolver a janela ativa.
        let fm = FileManager.default
        let conta = fm.temporaryDirectory.appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let proj = conta.appendingPathComponent("projects/proj-a")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)

        let agora = Date()
        let iso = ISO8601DateFormatter()
        var linhas = ""
        var t = agora.addingTimeInterval(-8 * 24 * 3600) // 8 dias atrás
        while t <= agora {
            linhas += "\(claudeUsageLine(timestamp: iso.string(from: t)))\n"
            t = t.addingTimeInterval(600)
        }
        try linhas.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let detector = SessionDetector(clock: SystemClock())
        let end = await detector.activeWindowEnd(account: conta)
        // Atividade contínua até agora → janela ativa (o teto não impede a
        // detecção; só limita o quanto se olha para trás).
        XCTAssertNotNil(end)
        XCTAssertGreaterThan(end!, agora)
    }

    func testTranscriptIlegivelTornaDeteccaoIndisponivel() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory.appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let proj = conta.appendingPathComponent("projects/proj-a")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }

        // "Transcript" ilegível: um diretório com extensão .jsonl.
        try fm.createDirectory(at: proj.appendingPathComponent("quebrado.jsonl"),
                               withIntermediateDirectories: true)

        let state = await SessionDetector(clock: SystemClock())
            .quotaWindowState(account: conta)

        XCTAssertEqual(
            state,
            .unavailable(reason: "transcript file is not readable")
        )
    }

    func testCaminhoDeTranscriptsQueNaoEhDiretorioFicaIndisponivel() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        try fm.createDirectory(at: conta, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }
        try "not-a-directory".write(
            to: conta.appendingPathComponent("projects"),
            atomically: true,
            encoding: .utf8
        )

        let state = await SessionDetector().quotaWindowState(account: conta)

        XCTAssertEqual(
            state,
            .unavailable(reason: "transcript path is not a directory")
        )
    }

    func testDiretorioDeTranscriptsIlegivelFicaIndisponivel() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let projetos = conta.appendingPathComponent("projects")
        try fm.createDirectory(at: projetos, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: projetos.path
            )
            try? fm.removeItem(at: conta)
        }
        try fm.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: projetos.path
        )

        let state = await SessionDetector().quotaWindowState(account: conta)

        XCTAssertEqual(
            state,
            .unavailable(reason: "transcript directory is not readable")
        )
    }

    func testVarreduraParseiaTimestampsComRuidoESemNewlineFinal() async throws {
        // Guard do reader mapeado: linhas sem timestamp intercaladas, uma linha
        // em branco, e a última linha SEM '\n' final — todas devem ser tratadas
        // e o timestamp recente detectado.
        let fm = FileManager.default
        let conta = fm.temporaryDirectory.appendingPathComponent("ohayo-test-\(UUID().uuidString)")
        let proj = conta.appendingPathComponent("projects/proj-a")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1800))
        let conteudo = """
        {"type":"summary"}

        \(claudeUsageLine(timestamp: iso))
        """ // sem '\n' no fim
        try conteudo.write(to: proj.appendingPathComponent("s.jsonl"),
                           atomically: true, encoding: .utf8)
        let detector = SessionDetector(clock: SystemClock())
        let end = await detector.activeWindowEnd(account: conta)
        XCTAssertNotNil(end)
    }

    func testJanelaComecaNaPrimeiraMensagemExata() {
        // Caso real (2026-07-12, conta claude2): primeira mensagem 19:57:15Z →
        // a janela reseta exatamente 5h depois (00:57:15Z). A heurística antiga
        // (hora cheia, técnica ccusage) daria 00:00Z — dessincronizado do /usage.
        let t = date("2026-07-12T19:57:15Z")
        let now = date("2026-07-12T20:01:00Z")
        let end = SessionDetector.activeBlockEnd(timestamps: [t], now: now)
        XCTAssertEqual(end, date("2026-07-13T00:57:15Z"))
    }

    func testContaCodexLeSessionsJsonl() async throws {
        // Conta fake .codex-teste com sessions/2026/07/09/rollout-x.jsonl
        let conta = FileManager.default.temporaryDirectory
            .appendingPathComponent(".codex-teste-\(UUID().uuidString)")
        let sessions = conta.appendingPathComponent("sessions/2026/07/09")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: conta) }
        let agora = Date()
        let iso = ISO8601DateFormatter().string(from: agora.addingTimeInterval(-60))
        try codexUsageLine(timestamp: iso)
            .write(to: sessions.appendingPathComponent("rollout-1.jsonl"),
                   atomically: true, encoding: .utf8)
        let detector = SessionDetector()
        let end = await detector.activeWindowEnd(account: conta)
        XCTAssertNotNil(end) // mensagem de 1 min atrás → janela ativa
    }

    func testProviderExplicitoVenceAssinaturaAmbiguaDaPasta() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent("ambigua-\(UUID().uuidString)")
        let projects = conta.appendingPathComponent("projects")
        let sessions = conta.appendingPathComponent("sessions/2026/07/28")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }
        XCTAssertEqual(Provider.detect(at: conta), .claude)

        let consumedAt = now.addingTimeInterval(-60)
        try codexUsageLine(
            timestamp: ISO8601DateFormatter().string(from: consumedAt)
        ).write(
            to: sessions.appendingPathComponent("rollout.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let state = await SessionDetector(clock: FakeClock(now: now))
            .quotaWindowState(account: conta, provider: .codex)

        XCTAssertEqual(
            state,
            .active(
                until: consumedAt.addingTimeInterval(
                    SessionDetector.blockDuration
                )
            )
        )
    }

    func testCodexTokenCountComInfoNuloEhEvidenciaConhecidaSemConsumo() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent(".codex-teste-\(UUID().uuidString)")
        let sessions = conta.appendingPathComponent("sessions/2026/07/28")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":null}}
        """.write(
            to: sessions.appendingPathComponent("sem-consumo.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let state = await SessionDetector().quotaWindowState(account: conta)

        XCTAssertEqual(state, .inactive)
    }

    func testCodexFalhaDeAutenticacaoSemConsumoNaoAbreJanela() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent(".codex-teste-\(UUID().uuidString)")
        let sessions = conta.appendingPathComponent("sessions/2026/07/28")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }

        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let transcript = """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"fake"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11},"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0}}}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Not logged in"}}
        """
        try transcript.write(
            to: sessions.appendingPathComponent("rollout-falha.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let end = await SessionDetector().activeWindowEnd(account: conta)
        XCTAssertNil(end)
    }

    func testSchemaDeUsageCodexDesconhecidoFicaIndisponivel() async throws {
        let fm = FileManager.default
        let conta = fm.temporaryDirectory
            .appendingPathComponent(".codex-teste-\(UUID().uuidString)")
        let sessions = conta.appendingPathComponent("sessions/2026/07/28")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: conta) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input":1,"output":1}}}}
        """.write(
            to: sessions.appendingPathComponent("schema-novo.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let state = await SessionDetector().quotaWindowState(account: conta)

        XCTAssertEqual(
            state,
            .unavailable(reason: "unsupported Codex usage schema")
        )
    }
}
