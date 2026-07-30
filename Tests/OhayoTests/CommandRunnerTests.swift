import XCTest
import Darwin
@testable import Ohayo

final class CommandRunnerTests: XCTestCase {
    /// Cria um script executável que simula o binário `claude`.
    func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        try! ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func dispatch(_ message: Message) -> PreparedDispatch {
        try! DispatchPreparer(
            isDirectory: { _ in true }
        ).prepare(
            .direct(message, origin: .manual)
        ).get()
    }

    /// O prompt não pode aparecer em argv (visível em `ps`); Claude `-p` lê o
    /// conteúdo de stdin quando o argumento posicional é omitido.
    func testClaudeEnviaPromptPorStdinSemExpoLoNosArgumentos() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-args-\(UUID().uuidString).txt")
        let stdinFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stdin-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s\\n' \"$@\" > '\(argsFile.path)'; "
                    + "cat > '\(stdinFile.path)'; exit 0"
            )
        )

        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .success(""))

        let captured = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(captured,
                       ["-p", "--model", "claude-haiku-4-5", "--effort", "low", "--safe-mode"])
        XCTAssertEqual(try String(contentsOf: stdinFile, encoding: .utf8), "1+1")
    }

    func testRepassaPromptCustomComFlagsFixos() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-args-\(UUID().uuidString).txt")
        let stdinFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stdin-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s\\n' \"$@\" > '\(argsFile.path)'; "
                    + "cat > '\(stdinFile.path)'; exit 0"
            )
        )

        let result = await runner.run(
            dispatch(Message(text: "bom dia", kind: .claude))
        )
        XCTAssertEqual(result, .success(""))

        let captured = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(captured,
                       ["-p", "--model", "claude-haiku-4-5", "--effort", "low", "--safe-mode"])
        XCTAssertEqual(try String(contentsOf: stdinFile, encoding: .utf8), "bom dia")
    }

    /// Config por mensagem: modelo/effort escolhidos entram nos args e
    /// `--safe-mode` é omitido quando `safeMode == false`.
    func testArgsRefletemConfigDaMensagem() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-args-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("printf '%s\\n' \"$@\" > '\(argsFile.path)'; exit 0")
        )
        let msg = Message(text: "tarefa", kind: .claude, model: .opus, effort: .high, safeMode: false)
        let result = await runner.run(dispatch(msg))
        XCTAssertEqual(result, .success(""))

        let captured = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(captured,
                       ["-p", "--model", "claude-opus-4-8", "--effort", "high"])
    }

    /// Diretório de trabalho por mensagem: o subprocesso roda no diretório dado.
    func testWorkingDirDaMensagem() async throws {
        let pwdFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pwd-\(UUID().uuidString).txt")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("pwd -P > '\(pwdFile.path)'; exit 0")
        )
        let msg = Message(text: "1+1", kind: .claude, workingDir: dir.path)
        let result = await runner.run(dispatch(msg))
        XCTAssertEqual(result, .success(""))
        let captured = try String(contentsOf: pwdFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: captured).standardizedFileURL,
                       dir.standardizedFileURL)
    }

    func testProviderSemWorkingDirUsaWorkspaceGerenciadoDoOhayo() async {
        let runtime = CapturingCommandRuntime()
        let workspace = URL(
            fileURLWithPath: "/tmp/ohayo-managed-workspace",
            isDirectory: true
        )
        var createdDirectories: [URL] = []
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: URL(fileURLWithPath: "/tmp/fake-claude"),
            defaultProviderWorkingDirectory: workspace,
            directoryCreator: { createdDirectories.append($0) },
            processRuntime: runtime
        )

        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )

        XCTAssertEqual(result, .success(""))
        XCTAssertEqual(
            runtime.requests.last?.workingDirectory?.standardizedFileURL,
            workspace.standardizedFileURL
        )
        XCTAssertEqual(createdDirectories, [workspace])
    }

    func testShellUsaWorkingDirectoryDoDispatchPreparado() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-wd-\(UUID().uuidString)")
        let preparedDirectory = root.appendingPathComponent("prepared")
        let staleMessageDirectory = root.appendingPathComponent("message")
        try FileManager.default.createDirectory(
            at: preparedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: staleMessageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let message = Message(
            text: "pwd -P",
            kind: .shell,
            workingDir: staleMessageDirectory.path
        )
        let dispatch = PreparedDispatch(
            message: message,
            origin: .manual,
            taskID: nil,
            taskName: nil,
            target: .shell(workingDirectory: preparedDirectory)
        )
        let runner = CommandRunner(
            timeout: 5,
            shellOverride: URL(fileURLWithPath: "/bin/sh")
        )

        let output = try await runner.run(dispatch).get()

        XCTAssertEqual(
            URL(fileURLWithPath: output).standardizedFileURL,
            preparedDirectory.standardizedFileURL
        )
    }

    /// O plano já preparado é a autoridade da conta; o runner não reinfere o
    /// ambiente a partir do `configDir` cru que permanece na mensagem.
    func testContaDoDispatchPreparadoVenceConfigDirCruDaMensagem() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-\(UUID().uuidString).txt")
        let preparedAccount = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-\(UUID().uuidString)")
        let rawMessageAccount = FileManager.default.temporaryDirectory
            .appendingPathComponent("msg-\(UUID().uuidString)")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s' \"$CLAUDE_CONFIG_DIR\" > '\(envFile.path)'; exit 0"
            )
        )
        let message = Message(
            text: "1+1",
            kind: .claude,
            configDir: rawMessageAccount.path
        )
        let account = ProviderAccountContext(
            provider: .claude,
            configDirectory: preparedAccount
        )
        let prepared = PreparedDispatch(
            message: message,
            origin: .manual,
            taskID: nil,
            taskName: nil,
            target: .provider(ProviderDispatchPlan(
                message: message,
                account: account
            ))
        )

        let result = await runner.run(prepared)

        XCTAssertEqual(result, .success(""))
        let captured = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertEqual(captured, preparedAccount.path)
    }

    /// Modo comando cru: sem prefixo do Claude, roda via shell de login
    /// (`-l -c <texto>`) e o executável é o shell injetado, não o `claude`.
    func testComandoCruRodaViaShellSemPrefixoClaude() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-args-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("echo NAO-DEVE-CHAMAR-CLAUDE >&2; exit 42"),
            shellOverride: makeScript("printf '%s\\n' \"$@\" > '\(argsFile.path)'; exit 0")
        )

        let result = await runner.run(
            dispatch(Message(text: "echo oi", kind: .shell))
        )
        XCTAssertEqual(result, .success(""))

        let captured = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(captured, ["-l", "-c", "echo oi"])
    }

    func testShellNaoInjetaAmbienteDeClaudeNemCodex() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-env-\(UUID().uuidString).txt")
        let expectedClaude = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "<unset>"
        let expectedCodex = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "<unset>"
        let runner = CommandRunner(
            timeout: 5,
            shellOverride: makeScript(
                "printf '%s|%s' \"${CLAUDE_CONFIG_DIR-<unset>}\" "
                    + "\"${CODEX_HOME-<unset>}\" > '\(envFile.path)'; exit 0"
            )
        )
        var message = Message(text: "echo oi", kind: .shell)
        message.configDir = "/tmp/tambem-nao-deve-vazar"

        let result = await runner.run(dispatch(message))

        XCTAssertEqual(result, .success(""))
        XCTAssertEqual(
            try String(contentsOf: envFile, encoding: .utf8),
            "\(expectedClaude)|\(expectedCodex)"
        )
    }

    /// O ping deve mirar a conta escolhida via `CLAUDE_CONFIG_DIR`. O fake
    /// script grava o valor visto no ambiente do filho.
    func testFixaClaudeConfigDirDaConta() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-\(UUID().uuidString).txt")
        let conta = FileManager.default.temporaryDirectory
            .appendingPathComponent("conta-\(UUID().uuidString)")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s' \"$CLAUDE_CONFIG_DIR\" > '\(envFile.path)'; exit 0"
            )
        )
        let message = Message(
            text: "1+1",
            kind: .claude,
            configDir: conta.path
        )
        let result = await runner.run(dispatch(message))
        XCTAssertEqual(result, .success(""))
        let captured = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertEqual(captured, conta.path)
    }

    /// A conta Claude nativa não é equivalente a
    /// `CLAUDE_CONFIG_DIR=~/.claude`: o override faria a CLI procurar a
    /// identidade em `~/.claude/.claude.json`, em vez de `~/.claude.json`.
    /// Sem conta custom escolhida, remove qualquer override herdado.
    func testClaudeNativoRemoveConfigDirHerdadoSemExportarDefault() async throws {
        setenv("CLAUDE_CONFIG_DIR", "/tmp/conta-vazada-do-shell", 1)
        defer { unsetenv("CLAUDE_CONFIG_DIR") }
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s' \"${CLAUDE_CONFIG_DIR-<unset>}\" > '\(envFile.path)'; exit 0"
            )
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .success(""))
        let captured = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertEqual(captured, "<unset>")
    }

    func testCapturaStdoutNoSucesso() async {
        let runner = CommandRunner(timeout: 5,
                                  binaryOverride: makeScript("echo 'resposta do claude'; exit 0"))
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .success("resposta do claude"))
    }

    func testSucessoQuandoExitZero() async {
        let runner = CommandRunner(timeout: 5, binaryOverride: makeScript("exit 0"))
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .success(""))
    }

    func testFalhaCapturaStderr() async {
        let runner = CommandRunner(timeout: 5, binaryOverride: makeScript("echo boom >&2; exit 1"))
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .failure(.failed("boom")))
    }

    func testFalhaCapturaStdoutQuandoStderrEstaVazio() async {
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("printf 'Not logged in · Please run /login\\n'; exit 1")
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .failure(.failed("Not logged in · Please run /login")))
    }

    func testFalhaComDoisStreamsPreservaAmbos() async {
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("printf 'stdout erro\\n'; printf 'stderr erro\\n' >&2; exit 1")
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .failure(.failed("stdout:\nstdout erro\n\nstderr:\nstderr erro")))
    }

    func testFalhaSemSaidaMantemCodigoDeSaida() async {
        let runner = CommandRunner(timeout: 5, binaryOverride: makeScript("exit 7"))
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .failure(.failed("exit 7")))
    }

    func testTimeoutMataOProcesso() async {
        let runner = CommandRunner(timeout: 1, binaryOverride: makeScript("sleep 10"))
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .failure(.timeout))
    }

    func testTimeoutDaMensagemControlaExecucaoBatchSemOverrideDoRunner() async {
        let runner = CommandRunner(shellOverride: makeScript("sleep 2; exit 0"))
        let message = Message(
            text: "comando demorado",
            kind: .shell,
            timeoutSeconds: 1
        )
        let start = Date()

        let result = await runner.run(dispatch(message))

        XCTAssertEqual(result, .failure(.timeout))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2,
                          "o timeout persistido da mensagem não foi aplicado")
    }

    func testRunnerBatchAplicaTimeoutMesmoSeMensagemMarcaTerminal() async {
        let runner = CommandRunner(binaryOverride: makeScript("sleep 2; exit 0"))
        let message = Message(
            text: "comando demorado",
            kind: .claude,
            runInTerminal: true,
            timeoutSeconds: 1
        )
        let start = Date()

        let result = await runner.run(dispatch(message))

        XCTAssertEqual(result, .failure(.timeout))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2,
                          "CommandRunner deve tratar todo dispatch recebido como batch")
    }

    func testTimeoutInjetadoNoRunnerTemPrioridadeSobreTimeoutDaMensagem() async {
        let runner = CommandRunner(
            timeout: 0.25,
            shellOverride: makeScript("sleep 2; exit 0")
        )
        let message = Message(
            text: "comando demorado",
            kind: .shell,
            timeoutSeconds: 1_800
        )
        let start = Date()

        let result = await runner.run(dispatch(message))

        XCTAssertEqual(result, .failure(.timeout))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2,
                          "o override injetado deve manter os testes rápidos")
    }

    /// Regressao: se o pipe de stdout nao for drenado enquanto o processo
    /// roda, uma saida maior que o buffer do SO (~64KB) trava o write do
    /// filho, o processo nunca termina e sendHi() reporta .timeout
    /// erroneamente. Este script emite bem mais que 64KB antes de sair 0.
    func testNaoTravaComStdoutMaiorQueBufferDoPipe() async {
        let runner = CommandRunner(
            timeout: 10,
            binaryOverride: makeScript("head -c 200000 /dev/zero | tr '\\0' 'x'; exit 0")
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        if case .success(let output) = result {
            XCTAssertEqual(output.count, 200000, "esperava 200000 chars, obtido \(output.count)")
            XCTAssertTrue(output.allSatisfy { $0 == "x" }, "stdout deveria conter apenas 'x'")
        } else {
            XCTFail("esperava sucesso, obtido \(result)")
        }
    }

    /// Regressao (re-review #1): o readabilityHandler e assincrono/level-
    /// triggered; ao zerar o handler assim que o processo termina, o ultimo
    /// chunk de stderr (escrito logo antes do exit) pode nao ter sido
    /// despachado ainda e se perder, virando "exit N" em vez da mensagem
    /// real. O drain final sincrono garante a captura completa.
    func testCapturaStderrEscritoImediatamenteAntesDoExit() async {
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("printf 'erro fatal na cli\\n' >&2; exit 3")
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .failure(.failed("erro fatal na cli")))
    }

    /// Regressao (re-review #1): stderr grande (acima do buffer do pipe)
    /// deve ser capturado por completo, sem truncar. Usamos uma linha
    /// reconhecivel no fim para provar que a cauda chegou.
    func testCapturaStderrGrandeCompleto() async {
        let runner = CommandRunner(
            timeout: 10,
            binaryOverride: makeScript(
                "head -c 200000 /dev/zero | tr '\\0' 'x' >&2; printf 'FIM-DA-STDERR\\n' >&2; exit 1"
            )
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        if case .failure(.failed(let message)) = result {
            XCTAssertTrue(message.hasSuffix("FIM-DA-STDERR"),
                          "stderr truncado; sufixo real: \(String(message.suffix(40)))")
            XCTAssertGreaterThan(message.count, 200000)
        } else {
            XCTFail("esperava .failure(.failed(...)), obtido \(result)")
        }
    }

    /// Quando a saída excede 256 KiB, o diagnóstico precisa manter tanto o
    /// começo (contexto) quanto a cauda recente (onde CLIs normalmente escrevem
    /// a causa final), deixando explícito que houve truncamento. A repetição de
    /// emoji força os dois cortes internos a caírem no meio de sequências UTF-8.
    func testStdoutMaiorQueCapPreservaInicioECaudaComMarcadorEUTF8Valido() async throws {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-runner-output-\(UUID().uuidString).txt")
        try (String(repeating: "🚀", count: 70_000) + "FIM-DO-LOG\n")
            .write(to: outputFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outputFile) }
        let runner = CommandRunner(
            timeout: 10,
            binaryOverride: makeScript("cat '\(outputFile.path)'; exit 0")
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        if case .success(let output) = result {
            XCTAssertTrue(output.hasPrefix("🚀"), "o início do log deve ser preservado")
            XCTAssertTrue(
                output.contains(CapturedCLIOutput.truncationMarker),
                          "o truncamento deve ficar explícito")
            XCTAssertTrue(output.hasSuffix("FIM-DO-LOG"),
                          "a cauda recente do log deve ser preservada")
            XCTAssertLessThanOrEqual(
                Data(output.utf8).count,
                CommandRunner.maximumCapturedOutputBytes
            )
        } else {
            XCTFail("esperava sucesso, obtido \(result)")
        }
    }

    /// Regressao (re-review #2): terminate() so manda SIGTERM. Um filho que
    /// ignora SIGTERM faria um waitUntilExit() travar para sempre, e
    /// sendHi() nunca retornaria — o mesmo bug que o fix original matou,
    /// so que na branch de timeout. A espera pos-terminate deve ser
    /// limitada (grace + SIGKILL) e retornar .timeout em tempo limitado.
    func testTimeoutLimitadoMesmoComFilhoQueIgnoraSIGTERM() async {
        let runner = CommandRunner(
            timeout: 1,
            binaryOverride: makeScript("trap '' TERM; sleep 30")
        )
        let start = Date()
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, .failure(.timeout))
        XCTAssertLessThan(elapsed, 10, "sendHi() nao retornou em tempo limitado: \(elapsed)s")
    }

    /// Foundation não cria um process group isolado para `Process`. No
    /// timeout, matar apenas o PID raiz deixa subprocessos da CLI órfãos; usar
    /// `kill(-pid, ...)` sem ter criado o grupo poderia atingir o próprio app.
    /// O runner deve encerrar apenas descendentes positivamente identificados.
    func testTimeoutEncerraProcessoFilhoSemMatarGrupoDoApp() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-runner-child-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        let runner = CommandRunner(
            timeout: 0.5,
            binaryOverride: makeScript(
                "trap '' TERM; "
                    + "sh -c 'trap \"\" TERM; while :; do sleep 30; done' & child=$!; "
                    + "printf '%s' \"$child\" > '\(childPIDFile.path)'; wait \"$child\""
            )
        )

        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .claude))
        )
        XCTAssertEqual(result, .failure(.timeout))

        let childPID = try XCTUnwrap(pid_t(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer {
            if Self.processExists(childPID) {
                kill(childPID, SIGKILL)
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while Self.processExists(childPID), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(Self.processExists(childPID),
                       "o subprocesso \(childPID) ficou órfão após o timeout")
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Regressao: o fallback via shell de login (`locateViaShell`) rodava
    /// `waitUntilExit()` sem timeout. Um profile (`~/.zprofile`) que pendura —
    /// pedindo input, esperando rede — travaria a busca para sempre; e como
    /// `locate()` roda dentro de `run()`, o `isRunning` do FireController nunca
    /// seria liberado e todo disparo futuro seria descartado em silencio. A
    /// busca deve desistir em tempo limitado e devolver nil.
    func testLocateViaShellImpoeTimeoutENaoPenduraIndefinidamente() {
        let shellQuePendura = makeScript("sleep 30")
        let start = Date()
        let result = CommandRunner.locateViaShell(shell: shellQuePendura, cliName: "claude", timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 10, "locateViaShell nao respeitou o timeout: \(elapsed)s")
    }

    /// Fechar o sheet ou trocar de conta cancela também a descoberta do
    /// binário. Sem isso, o shell de login continuava vivo até o timeout de
    /// dez segundos mesmo depois de a resposta já não poder atualizar a UI.
    func testLocateViaShellCancelaBuscaEmAndamento() {
        let shellQuePendura = makeScript("sleep 30")
        let cancellation = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            cancellation.signal()
        }

        let start = Date()
        let result = CommandRunner.locateViaShell(
            shell: shellQuePendura,
            cliName: "codex",
            timeout: 10,
            isCancelled: {
                cancellation.wait(timeout: .now()) == .success
            }
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(
            elapsed,
            3,
            "cancelamento não interrompeu a busca: \(elapsed)s"
        )
    }

    /// Regressao: `locateViaShell` nunca lia o pipe de stderr. Um profile que
    /// ecoa mais que o buffer do SO (~64KB) em stderr trava o write do filho, o
    /// `command -v` nunca termina e `waitUntilExit()` pendura para sempre. Este
    /// shell fake despeja 200KB em stderr ANTES de imprimir o caminho no stdout:
    /// so passa se o stderr for drenado concorrentemente.
    func testLocateViaShellNaoTravaComStderrGrande() {
        let alvo = "/tmp/fake-cli-\(UUID().uuidString)/claude"
        let shell = makeScript("head -c 200000 /dev/zero | tr '\\0' 'e' >&2; printf '%s\\n' '\(alvo)'; exit 0")
        let result = CommandRunner.locateViaShell(shell: shell, cliName: "claude", timeout: 5)
        XCTAssertEqual(result?.path, alvo)
    }

    /// Regressao: um `~/.zprofile` ruidoso ecoa no stdout ANTES da saida do
    /// `command -v`. Usar o stdout inteiro como caminho devolve algo invalido;
    /// o caminho verdadeiro esta na ULTIMA linha nao vazia.
    func testLocateViaShellUsaUltimaLinhaDoStdout() {
        let alvo = "/tmp/fake-cli-\(UUID().uuidString)/claude"
        let shell = makeScript("echo 'nvm: using node v20'; printf '%s\\n' '\(alvo)'; exit 0")
        let result = CommandRunner.locateViaShell(shell: shell, cliName: "claude", timeout: 5)
        XCTAssertEqual(result?.path, alvo)
    }

    private func makeExecutable(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Modo Codex: `codex exec` com modelo/reasoning resolvidos da mensagem e
    /// `CODEX_HOME` fixado a partir de `configDir` (mesmo padrão do Claude).
    func testCodexMontaArgsEFixaCodexHome() async throws {
        let script = """
        #!/bin/sh
        echo "ARGS:$@"
        echo "HOME_CODEX:${CODEX_HOME}"
        """
        let bin = try makeExecutable(script)
        var msg = Message(text: "1+1", kind: .codex)
        msg.configDir = "/tmp/conta-codex"
        msg.codexModel = "gpt-5.5"
        msg.codexReasoning = .low
        let runner = CommandRunner(binaryOverride: bin)
        let result = await runner.run(dispatch(msg))
        let output = try result.get()
        XCTAssertTrue(output.contains("exec"))
        XCTAssertTrue(output.contains("--model gpt-5.5"))
        XCTAssertTrue(output.contains("--sandbox workspace-write"))
        XCTAssertTrue(output.contains("--skip-git-repo-check"))
        XCTAssertTrue(output.contains("--color never"))
        XCTAssertTrue(output.contains(#"model_reasoning_effort="low""#))
        XCTAssertFalse(output.contains("1+1"))
        XCTAssertTrue(output.contains("HOME_CODEX:/tmp/conta-codex"))
    }

    func testCodexEnviaPromptPorStdinSemExpoLoNosArgumentos() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-args-\(UUID().uuidString).txt")
        let stdinFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-stdin-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s\\n' \"$@\" > '\(argsFile.path)'; "
                    + "cat > '\(stdinFile.path)'; exit 0"
            )
        )

        let result = await runner.run(
            dispatch(Message(text: "segredo codex", kind: .codex))
        )

        XCTAssertEqual(result, .success(""))
        let args = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(args, ["exec", "--sandbox", "workspace-write",
                              "--skip-git-repo-check", "--color", "never"])
        XCTAssertEqual(try String(contentsOf: stdinFile, encoding: .utf8), "segredo codex")
    }

    func testCodexConfiadoUsaSandboxComEscritaNoWorkspace() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-args-\(UUID().uuidString).txt")
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("projeto-confiado-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s\n' \"$@\" > '\(argsFile.path)'; exit 0"
            )
        )
        let message = Message(
            text: "crie um arquivo",
            kind: .codex,
            workingDir: workingDirectory.path,
            trustWorkingDirectory: true
        )

        let result = await runner.run(dispatch(message))

        XCTAssertEqual(result, .success(""))
        let args = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            args,
            [
                "exec", "--sandbox", "workspace-write",
                "--skip-git-repo-check", "--color", "never",
            ]
        )
    }

    func testCodexComOptOutMantemSandboxSomenteLeitura() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-args-\(UUID().uuidString).txt")
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "projeto-nao-confiado-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s\n' \"$@\" > '\(argsFile.path)'; exit 0"
            )
        )
        let message = Message(
            text: "revise sem alterar",
            kind: .codex,
            workingDir: workingDirectory.path,
            trustWorkingDirectory: false
        )

        let result = await runner.run(dispatch(message))

        XCTAssertEqual(result, .success(""))
        let args = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            args,
            [
                "exec", "--sandbox", "read-only",
                "--skip-git-repo-check", "--color", "never",
            ]
        )
    }

    /// Sem modelo/reasoning explícitos, o Codex omite `--model` e o `-c
    /// model_reasoning_effort` — deixando o default da conta (config.toml)
    /// valer, o único garantidamente aceito pelo plano da conta.
    func testCodexSemModeloOmiteFlagsEUsaDefaultDaConta() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-args-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("printf '%s\\n' \"$@\" > '\(argsFile.path)'; exit 0")
        )
        let result = await runner.run(
            dispatch(Message(text: "1+1", kind: .codex))
        )
        if case .failure(let e) = result { XCTFail("falhou: \(e)") }
        let args = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(args, ["exec", "--sandbox", "workspace-write",
                              "--skip-git-repo-check", "--color", "never"])
    }

    func testCodexComModeloEReasoningExplicitos() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-args-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript("printf '%s\\n' \"$@\" > '\(argsFile.path)'; exit 0")
        )
        var msg = Message(text: "1+1", kind: .codex)
        msg.codexModel = "gpt-5.5"
        msg.codexReasoning = .high
        _ = await runner.run(dispatch(msg))
        let args = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(args, ["exec", "--model", "gpt-5.5", "--sandbox", "workspace-write",
                              "--skip-git-repo-check", "--color", "never",
                              "-c", "model_reasoning_effort=\"high\""])
    }

    /// Sem `configDir` na mensagem, o Codex mira `~/.codex` (paridade com o
    /// default `~/.claude` do modo Claude).
    func testCodexSemConfigDirUsaCodexHomePadrao() async throws {
        let script = "#!/bin/sh\necho \"HOME_CODEX:${CODEX_HOME}\""
        let bin = try makeExecutable(script)
        let runner = CommandRunner(binaryOverride: bin)
        let output = try await runner.run(
            dispatch(Message(text: "1+1", kind: .codex))
        ).get()
        XCTAssertTrue(output.hasSuffix(".codex"))
    }

    /// Skill prefixada no prompt e `--safe-mode` omitido pela guarda —
    /// com safe-mode o CLI pularia a skill.
    func testClaudeComSkillPrefixaPromptEOmiteSafeMode() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-args-\(UUID().uuidString).txt")
        let stdinFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stdin-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s\\n' \"$@\" > '\(argsFile.path)'; "
                    + "cat > '\(stdinFile.path)'; exit 0"
            )
        )
        var msg = Message(text: "1+1", kind: .claude)
        msg.skill = "gmud"
        let result = await runner.run(dispatch(msg))
        XCTAssertEqual(result, .success(""))

        let captured = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(captured,
                       ["-p", "--model", "claude-haiku-4-5", "--effort", "low"])
        XCTAssertEqual(try String(contentsOf: stdinFile, encoding: .utf8), "/gmud 1+1")
    }

    func testCodexComSkillPrefixaPromptComCifrao() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-args-\(UUID().uuidString).txt")
        let stdinFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-stdin-\(UUID().uuidString).txt")
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: makeScript(
                "printf '%s\\n' \"$@\" > '\(argsFile.path)'; "
                    + "cat > '\(stdinFile.path)'; exit 0"
            )
        )
        var msg = Message(text: "oi", kind: .codex)
        msg.skill = "gmud"
        let result = await runner.run(dispatch(msg))
        XCTAssertEqual(result, .success(""))

        let captured = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map(String.init)
        XCTAssertEqual(captured,
                       ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check",
                        "--color", "never"])
        XCTAssertEqual(try String(contentsOf: stdinFile, encoding: .utf8), "$gmud oi")
    }
}

private final class CapturingCommandRuntime: CLIProcessRunning {
    private(set) var requests: [CLIProcessRequest] = []

    func run(_ request: CLIProcessRequest) async -> CLIProcessResult {
        requests.append(request)
        return CLIProcessResult(
            termination: .exited(0),
            stdout: .empty,
            stderr: .empty,
            duration: 0
        )
    }
}

extension Result where Success == String, Failure == RunnerError {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success(let l), .success(let r)): return l == r
        case (.failure(let l), .failure(let r)): return l == r
        default: return false
        }
    }
}

func XCTAssertEqual(_ lhs: Result<String, RunnerError>, _ rhs: Result<String, RunnerError>,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(lhs == rhs, "\(lhs) != \(rhs)", file: file, line: line)
}
