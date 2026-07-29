import Foundation
import Darwin

enum RunnerError: Error, Equatable {
    case cliNotFound(Provider)
    case timeout
    case failed(String)

    func userMessage(language: AppLanguage) -> String {
        let strings = L10n(language: language)
        switch self {
        case .cliNotFound(let provider):
            return strings.cliNotFound(provider)
        case .timeout: return strings.commandTimeout
        case .failed(let message): return message
        }
    }
}

protocol CommandRunning {
    func run(_ message: Message) async -> Result<String, RunnerError>
}

/// Acumula os bytes de stderr recebidos via `readabilityHandler`, que roda
/// em uma dispatch queue de fundo — precisa de lock porque `trimmedString()`
/// (chamado pela task async) e `append()` (chamado pela queue de fundo da
/// readability e pelo drain final síncrono) tocam o mesmo `Data`
/// concorrentemente.
final class PipeBuffer: @unchecked Sendable {
    /// Cap de segurança — o histórico trunca bem antes disso; evita reter
    /// respostas gigantes na memória.
    static let maxBytes = 256 * 1024
    static let truncationMarker = "\n[…]\n"
    private static let markerBytes = Data(truncationMarker.utf8).count
    private static let headLimit = (maxBytes - markerBytes) / 2
    private static let tailLimit = maxBytes - markerBytes - headLimit

    /// Até o cap, `head` contém a saída inteira. Ao ultrapassá-lo, fazemos
    /// uma única transição para uma janela de início + cauda rolante. Assim
    /// não descartamos bytes nem exibimos marcador antes dos 256 KiB.
    private var head = Data()
    private var tail = Data()
    private var isTruncated = false
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        if !isTruncated {
            if chunk.count <= Self.maxBytes - head.count {
                head.append(chunk)
                return
            }

            let completePrefix = head
            head = Data(completePrefix.prefix(Self.headLimit))
            if head.count < Self.headLimit {
                head.append(chunk.prefix(Self.headLimit - head.count))
            }

            if chunk.count >= Self.tailLimit {
                tail = Data(chunk.suffix(Self.tailLimit))
            } else {
                tail = Data(completePrefix.suffix(Self.tailLimit - chunk.count))
                tail.append(chunk)
            }
            isTruncated = true
            return
        }

        if chunk.count >= Self.tailLimit {
            tail = Data(chunk.suffix(Self.tailLimit))
        } else {
            let overflow = max(0, tail.count + chunk.count - Self.tailLimit)
            if overflow > 0 {
                tail.removeFirst(overflow)
            }
            tail.append(chunk)
        }
    }

    func trimmedString() -> String {
        lock.lock()
        let headSnapshot = head
        let tailSnapshot = tail
        let truncatedSnapshot = isTruncated
        lock.unlock()

        let output: String
        if truncatedSnapshot {
            output = Self.validUTF8Prefix(from: headSnapshot)
                + Self.truncationMarker
                + Self.validUTF8Fragment(from: tailSnapshot, mayStartMidCharacter: true)
        } else {
            output = Self.validUTF8Fragment(
                from: headSnapshot,
                mayStartMidCharacter: false
            )
        }
        return output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// O limite de cada janela pode cair no meio de um caractere UTF-8.
    /// Remove no máximo os três bytes incompletos de cada borda antes de
    /// recorrer ao decoder tolerante (para saída binária/inválida da CLI).
    private static func validUTF8Prefix(from data: Data) -> String {
        validUTF8Fragment(from: data, mayStartMidCharacter: false)
    }

    private static func validUTF8Fragment(
        from data: Data,
        mayStartMidCharacter: Bool
    ) -> String {
        let maximumPrefixDrop = mayStartMidCharacter ? min(3, data.count) : 0
        for prefixDrop in 0...maximumPrefixDrop {
            let remaining = data.count - prefixDrop
            for suffixDrop in 0...min(3, remaining) {
                let start = data.index(data.startIndex, offsetBy: prefixDrop)
                let end = data.index(data.endIndex, offsetBy: -suffixDrop)
                let candidate = data[start..<end]
                if let string = String(data: candidate, encoding: .utf8) {
                    return string
                }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct CommandRunner: CommandRunning {
    /// Override injetável para testes/integrações. Sem ele, cada execução
    /// deriva o limite batch da própria mensagem.
    private let timeoutOverride: TimeInterval?
    var binaryOverride: URL? // testes
    var shellOverride: URL? // testes
    /// Conta a mirar. Fixado no env do provider (`CLAUDE_CONFIG_DIR`/
    /// `CODEX_HOME`) do subprocesso para não herdar silenciosamente o valor
    /// do shell que lançou o app — senão o ping abre a janela de 5h numa
    /// conta diferente da que o usuário observa.
    var configDir: URL?

    init(
        timeout: TimeInterval? = nil,
        binaryOverride: URL? = nil,
        shellOverride: URL? = nil,
        configDir: URL? = nil
    ) {
        timeoutOverride = timeout
        self.binaryOverride = binaryOverride
        self.shellOverride = shellOverride
        self.configDir = configDir
    }

    /// Caminhos comuns de instalação; fallback via shell de login cobre
    /// nvm/asdf e instalações exóticas (importante para open source).
    static func candidatePaths(for provider: Provider) -> [String] {
        switch provider {
        case .claude:
            return ["~/.local/bin/claude", "~/.claude/local/claude",
                    "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]
        }
    }

    static func locate(
        _ provider: Provider,
        isCancelled: () -> Bool = { false }
    ) -> URL? {
        guard !isCancelled() else { return nil }
        let fm = FileManager.default
        for path in candidatePaths(for: provider) {
            guard !isCancelled() else { return nil }
            let expanded = NSString(string: path).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        guard !isCancelled() else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return locateViaShell(
            shell: URL(fileURLWithPath: shell),
            cliName: provider.cliName,
            isCancelled: isCancelled
        )
    }

    /// `Foundation.Process` não expõe uma forma de criar atomicamente um
    /// process group próprio. Portanto nunca usamos `kill(-pid, ...)`: sem
    /// essa garantia, o PID negativo poderia representar o grupo do próprio
    /// Ohayo. No macOS, `proc_listchildpids` permite identificar e sinalizar
    /// apenas PIDs positivos que pertencem à árvore da CLI.
    private static func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        guard rootPID > 1 else { return [] }
        var visited: Set<pid_t> = [rootPID]
        var postorder: [pid_t] = []

        func visit(_ parentPID: pid_t) {
            for childPID in directChildProcessIDs(of: parentPID)
                where childPID > 1 && childPID != getpid()
                    && visited.insert(childPID).inserted {
                visit(childPID)
                postorder.append(childPID)
            }
        }

        visit(rootPID)
        return postorder
    }

    private static func directChildProcessIDs(of parentPID: pid_t) -> [pid_t] {
        let estimate = proc_listchildpids(parentPID, nil, 0)
        guard estimate > 0 else { return [] }
        var capacity = max(16, Int(estimate))

        for attempt in 0..<2 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { bytes -> Int32 in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return proc_listchildpids(parentPID, baseAddress, Int32(bytes.count))
            }
            guard count > 0 else { return [] }
            if Int(count) < capacity || attempt == 1 {
                return Array(pids.prefix(Int(count))).filter { $0 > 1 }
            }
            capacity *= 2
        }
        return []
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func signal(_ signal: Int32, processIDs: [pid_t]) {
        let appPID = getpid()
        var signaled = Set<pid_t>()
        for pid in processIDs
            where pid > 1 && pid != appPID && signaled.insert(pid).inserted {
            kill(pid, signal)
        }
    }

    /// Reconsulta os descendentes ainda rastreáveis antes do SIGKILL. A
    /// enumeração é necessariamente best-effort (há uma corrida inerente sem
    /// `posix_spawn` com POSIX_SPAWN_SETPGROUP), mas mantém o sinal restrito a
    /// PIDs positivos observados na árvore — nunca ao grupo do app.
    private static func forceKillTargets(
        rootPID: pid_t,
        initiallyTracked: [pid_t]
    ) -> [pid_t] {
        var targets: [pid_t] = []
        var seen = Set<pid_t>()
        let roots = initiallyTracked + [rootPID]
        for pid in roots where processExists(pid) {
            for descendant in descendantProcessIDs(of: pid)
                where seen.insert(descendant).inserted {
                targets.append(descendant)
            }
            if seen.insert(pid).inserted {
                targets.append(pid)
            }
        }
        return targets
    }

    /// Fallback: pergunta ao shell de login onde está o binário (cobre nvm/asdf
    /// e instalações exóticas). Roda um subprocesso, então precisa da mesma
    /// blindagem de `run()`: drena os pipes e impõe timeout. Sem isso, um
    /// `~/.zprofile` que ecoa >64KB em stderr trava o write do filho (deadlock
    /// clássico de Process/Pipe) ou um profile que pede input pendura para
    /// sempre — e como `locate()` roda dentro de `run()`, o `isRunning` do
    /// FireController nunca é liberado e TODO disparo futuro é descartado em
    /// silêncio até reiniciar o app.
    static func locateViaShell(
        shell: URL,
        cliName: String,
        timeout: TimeInterval = 10,
        isCancelled: () -> Bool = { false }
    ) -> URL? {
        guard !isCancelled() else { return nil }
        let process = Process()
        process.executableURL = shell
        process.arguments = ["-l", "-c", "command -v \(cliName)"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // stdin fechado: um profile que pede input (ssh-add, prompts) não pendura.
        process.standardInput = FileHandle.nullDevice

        // Drena os dois pipes concorrentemente — senão uma saída maior que o
        // buffer do SO (~64KB) em stdout/stderr trava o write do filho e o
        // processo nunca termina (mesmo deadlock que run() mitiga).
        let outBuffer = PipeBuffer()
        let errBuffer = PipeBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let c = h.availableData; if !c.isEmpty { outBuffer.append(c) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let c = h.availableData; if !c.isEmpty { errBuffer.append(c) }
        }
        func clearHandlers() {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
        guard (try? process.run()) != nil else { clearHandlers(); return nil }

        // Poll com deadline em vez de waitUntilExit() sem timeout: um profile
        // que pendura não pode travar a busca para sempre (o guard isRunning do
        // FireController depende de locate() retornar).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning
            && Date() < deadline
            && !isCancelled() {
            usleep(50_000)
        }
        if process.isRunning {
            let rootPID = process.processIdentifier
            let descendants = descendantProcessIDs(of: rootPID)
            signal(SIGTERM, processIDs: descendants + [rootPID])
            let grace = Date().addingTimeInterval(1)
            while (process.isRunning || descendants.contains(where: processExists))
                    && Date() < grace {
                usleep(50_000)
            }
            signal(
                SIGKILL,
                processIDs: forceKillTargets(
                    rootPID: rootPID,
                    initiallyTracked: descendants
                )
            )
            clearHandlers()
            return nil
        }
        clearHandlers()
        guard !isCancelled() else { return nil }
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            outBuffer.append(rest)
        }
        guard process.terminationStatus == 0 else { return nil }
        // A última linha não vazia: um profile de login ruidoso pode ecoar no
        // stdout antes da saída do `command -v`, e o caminho real vem por último.
        let path = outBuffer.trimmedString()
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func run(_ message: Message) async -> Result<String, RunnerError> {
        let process = Process()
        var providerInput: Data?
        switch message.kind {
        case .claude:
            guard let binary = binaryOverride ?? Self.locate(.claude) else {
                return .failure(.cliNotFound(.claude))
            }
            process.executableURL = binary
            // Args montados a partir da config da mensagem (defaults: Haiku,
            // effort low, --safe-mode — o ping mínimo em tokens que só abre a
            // janela de 5h). --safe-mode pula CLAUDE.md/skills/plugins/hooks/MCP;
            // quando desligado, o Claude carrega esse contexto normalmente.
            var args = ["-p",
                        "--model", message.resolvedModel.cliValue,
                        "--effort", message.resolvedEffort.rawValue]
            if message.resolvedSafeMode { args.append("--safe-mode") }
            process.arguments = args
            providerInput = Data(message.resolvedPromptText.utf8)
        case .shell:
            // Comando cru: shell de login para PATH/aliases/pipes/variáveis
            // funcionarem — dá utilidade ao app fora do Claude.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            process.executableURL = shellOverride ?? URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", message.text]
        case .codex:
            guard let binary = binaryOverride ?? Self.locate(.codex) else {
                return .failure(.cliNotFound(.codex))
            }
            process.executableURL = binary
            // Ping mínimo: sandbox read-only e sem exigir repositório git (o
            // diretório default é o home). Modelo/reasoning só entram quando o
            // usuário escolheu — omitir as flags deixa o Codex usar o default da
            // conta (config.toml), o único valor garantidamente aceito pelo
            // plano da conta. Reasoning via -c (TOML) por não haver flag
            // dedicada no codex exec 0.143.0.
            var args = ["exec"]
            if let model = message.codexModel, !model.isEmpty {
                args += ["--model", model]
            }
            args += ["--sandbox", "read-only", "--skip-git-repo-check", "--color", "never"]
            if let reasoning = message.codexReasoning {
                args += ["-c", "model_reasoning_effort=\"\(reasoning.rawValue)\""]
            }
            process.arguments = args
            providerInput = Data(message.resolvedPromptText.utf8)
        }
        let home = NSHomeDirectory()
        // Diretório de trabalho: override da mensagem (se não vazio) senão o home.
        if let wd = message.workingDir, !wd.trimmingCharacters(in: .whitespaces).isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: wd).expandingTildeInPath)
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
        env["PATH"] = [env["PATH"], extraPath].compactMap { $0 }.joined(separator: ":")
        // Shell cru preserva o ambiente recebido sem ganhar uma conta de
        // provedor artificial. Para Claude/Codex, resolve a conta efetiva e
        // aplica a semântica própria do provider: Claude nativo precisa de
        // `CLAUDE_CONFIG_DIR` ausente; perfis custom e Codex usam override.
        if message.kind != .shell {
            let provider: Provider = message.kind == .codex ? .codex : .claude
            let messageConfigDir = (message.configDir?.isEmpty == false)
                ? URL(fileURLWithPath: message.configDir!) : nil
            // `configDir` é o fallback legado/injetado da conta Claude. Nunca
            // pode vazar para Codex — sem conta explícita, Codex usa ~/.codex.
            let injectedConfigDir = provider == .claude ? configDir : nil
            let account = ProviderAccountContext(
                provider: provider,
                configDirectory: messageConfigDir ?? injectedConfigDir
            )
            env = account.applyingAccountEnvironment(to: env)
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inputPipe = providerInput.map { _ in Pipe() }
        if let inputPipe {
            process.standardInput = inputPipe
        }

        // Drena os pipes concorrentemente enquanto o processo roda: se
        // ninguem ler, uma saida maior que o buffer do SO (~64KB) trava o
        // write do filho e o processo nunca termina (deadlock classico de
        // Process/Pipe), fazendo sendHi() reportar .timeout erroneamente.
        let stdoutBuffer = PipeBuffer()
        let stderrBuffer = PipeBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stdoutBuffer.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrBuffer.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            try? inputPipe?.fileHandleForWriting.close()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.failed(error.localizedDescription))
        }
        if let inputPipe, let providerInput {
            // Escreve fora da task chamadora: uma CLI fake/antiga que não leia
            // stdin não pode bloquear `run()` se o prompt exceder o pipe do SO.
            // Fechar o writer sinaliza EOF às CLIs que consomem o prompt.
            let writer = inputPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: providerInput)
                try? writer.close()
            }
        }

        // Terminal interativo é lançado por `TerminalLauncher` e não passa por
        // este executor. Toda chamada direta a `CommandRunner` é batch, mesmo
        // se receber uma mensagem marcada como Terminal; nesse estado
        // inconsistente, usa o timeout persistido ou o default do provider.
        let messageTimeout = message.resolvedTimeoutSeconds
            ?? message.timeoutSeconds
            ?? Message.defaultTimeoutSeconds(for: message.kind)
        let effectiveTimeout = timeoutOverride ?? TimeInterval(messageTimeout)
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let timedOut = process.isRunning
        if timedOut {
            // `terminate()` só manda SIGTERM; um filho que ignora/trata o
            // sinal faria um `waitUntilExit()` travar para sempre —
            // reintroduzindo o mesmo bug (subprocesso que nunca reporta
            // término) na branch de timeout. Então limitamos a espera: um
            // grace period curto e, se ainda vivo, escalamos para SIGKILL.
            let rootPID = process.processIdentifier
            let descendants = Self.descendantProcessIDs(of: rootPID)
            Self.signal(SIGTERM, processIDs: descendants + [rootPID])
            let graceDeadline = Date().addingTimeInterval(2)
            while (process.isRunning
                   || descendants.contains(where: Self.processExists))
                    && Date() < graceDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            Self.signal(
                SIGKILL,
                processIDs: Self.forceKillTargets(
                    rootPID: rootPID,
                    initiallyTracked: descendants
                )
            )
        }

        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil

        if timedOut {
            return .failure(.timeout)
        }
        // O `readabilityHandler` é assíncrono/level-triggered: ao ver o
        // processo já terminado e zerar o handler, o último chunk (ou o
        // evento de EOF) pode não ter sido despachado ao bloco ainda —
        // zerar cancela a DispatchSourceRead e essa cauda se perderia.
        // Depois de cancelar a source, um `readToEnd()` bloqueante no mesmo
        // fd é seguro e recupera a completude do `readToEnd()` pré-fix.
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            stdoutBuffer.append(rest)
        }
        if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            stderrBuffer.append(rest)
        }
        if process.terminationStatus != 0 {
            return .failure(.failed(Self.failureLog(
                stdout: stdoutBuffer.trimmedString(),
                stderr: stderrBuffer.trimmedString(),
                terminationStatus: process.terminationStatus)))
        }
        return .success(stdoutBuffer.trimmedString())
    }

    /// Preserva a saída real da CLI quando ela falha. Claude Code, por
    /// exemplo, escreve "Not logged in" em stdout e deixa stderr vazio.
    static func failureLog(stdout: String, stderr: String,
                           terminationStatus: Int32) -> String {
        switch (stdout.isEmpty, stderr.isEmpty) {
        case (false, true): return stdout
        case (true, false): return stderr
        case (false, false):
            return "stdout:\n\(stdout)\n\nstderr:\n\(stderr)"
        case (true, true):
            return "exit \(terminationStatus)"
        }
    }
}
