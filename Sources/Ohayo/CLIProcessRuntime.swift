import Darwin
import Foundation

enum CLIProcessOutputPolicy: Equatable {
    enum Overflow: Equatable {
        case truncateHeadAndTail
        case fail
    }

    case capture(maxBytes: Int = 256 * 1024, overflow: Overflow = .truncateHeadAndTail)
    case discard
}

struct CLIProcessRequest {
    let executable: URL
    var arguments: [String] = []
    var environment: [String: String]?
    var account: ProviderAccountContext?
    var workingDirectory: URL?
    var standardInput: Data?
    var timeout: TimeInterval = 10
    var stdout: CLIProcessOutputPolicy = .capture()
    var stderr: CLIProcessOutputPolicy = .capture()

    init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        account: ProviderAccountContext? = nil,
        workingDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval = 10,
        stdout: CLIProcessOutputPolicy = .capture(),
        stderr: CLIProcessOutputPolicy = .capture()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.account = account
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeout = timeout
        self.stdout = stdout
        self.stderr = stderr
    }
}

enum CLIProcessTermination: Equatable {
    case exited(Int32)
    case timedOut
    case cancelled
    case outputLimitExceeded
    case failedToLaunch(String)
}

struct CapturedCLIOutput: Equatable {
    static let truncationMarker = "\n[…]\n"

    let data: Data
    let wasTruncated: Bool
    let text: String

    static let empty = CapturedCLIOutput(
        data: Data(),
        wasTruncated: false,
        text: ""
    )

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CLIProcessResult: Equatable {
    let termination: CLIProcessTermination
    let stdout: CapturedCLIOutput
    let stderr: CapturedCLIOutput
    let duration: TimeInterval
}

protocol CLIProcessRunning {
    func run(_ request: CLIProcessRequest) async -> CLIProcessResult
}

/// Único adapter de `Foundation.Process` do app. Drena os dois streams,
/// limita memória, propaga cancelamento e encerra a árvore observada do
/// processo sem usar PIDs negativos.
struct SystemCLIProcessRuntime: CLIProcessRunning {
    fileprivate enum Event {
        case exited(Int32)
        case timedOut
        case cancelled
        case outputLimitExceeded
    }

    func run(_ request: CLIProcessRequest) async -> CLIProcessResult {
        let startedAt = Date()
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory

        var environment =
            request.environment ?? ProcessInfo.processInfo.environment
        if let account = request.account {
            environment = account.applyingAccountEnvironment(to: environment)
        }
        process.environment = environment

        let race = EventRace()
        let exitWaiter = ProcessExitWaiter()
        let stdout = OutputCapture(
            policy: request.stdout,
            onOverflow: { race.resolve(.outputLimitExceeded) }
        )
        let stderr = OutputCapture(
            policy: request.stderr,
            onOverflow: { race.resolve(.outputLimitExceeded) }
        )
        let stdoutPipe = configureOutput(
            request.stdout,
            process: process,
            isStandardOutput: true,
            capture: stdout
        )
        let stderrPipe = configureOutput(
            request.stderr,
            process: process,
            isStandardOutput: false,
            capture: stderr
        )

        let inputPipe: Pipe?
        if let input = request.standardInput {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
            // A escrita é feita depois do spawn.
            _ = input
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            exitWaiter.finish(status)
            race.resolve(.exited(status))
        }

        if Task.isCancelled {
            return result(
                termination: .cancelled,
                stdout: stdout,
                stderr: stderr,
                startedAt: startedAt
            )
        }

        do {
            try process.run()
        } catch {
            clearHandlers(stdoutPipe, stderrPipe)
            return result(
                termination: .failedToLaunch(error.localizedDescription),
                stdout: stdout,
                stderr: stderr,
                startedAt: startedAt
            )
        }

        if let inputPipe, let input = request.standardInput {
            let writer = inputPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }

        let timeoutWork = DispatchWorkItem {
            race.resolve(.timedOut)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, request.timeout),
            execute: timeoutWork
        )

        let event = await withTaskCancellationHandler {
            if Task.isCancelled {
                race.resolve(.cancelled)
            }
            return await race.wait()
        } onCancel: {
            race.resolve(.cancelled)
        }
        timeoutWork.cancel()

        let termination: CLIProcessTermination
        switch event {
        case .exited(let status):
            termination = .exited(status)
        case .timedOut:
            await terminate(process)
            _ = await exitWaiter.wait()
            termination = .timedOut
        case .cancelled:
            await terminate(process, allowsGracePeriod: false)
            _ = await exitWaiter.wait()
            termination = .cancelled
        case .outputLimitExceeded:
            await terminate(process)
            _ = await exitWaiter.wait()
            termination = .outputLimitExceeded
        }

        clearHandlers(stdoutPipe, stderrPipe)
        drain(stdoutPipe, into: stdout)
        drain(stderrPipe, into: stderr)
        let finalTermination: CLIProcessTermination
        if case .exited = termination,
           stdout.didExceedLimit || stderr.didExceedLimit {
            finalTermination = .outputLimitExceeded
        } else {
            finalTermination = termination
        }
        return result(
            termination: finalTermination,
            stdout: stdout,
            stderr: stderr,
            startedAt: startedAt
        )
    }

    private func configureOutput(
        _ policy: CLIProcessOutputPolicy,
        process: Process,
        isStandardOutput: Bool,
        capture: OutputCapture
    ) -> Pipe? {
        switch policy {
        case .discard:
            if isStandardOutput {
                process.standardOutput = FileHandle.nullDevice
            } else {
                process.standardError = FileHandle.nullDevice
            }
            return nil
        case .capture:
            let pipe = Pipe()
            if isStandardOutput {
                process.standardOutput = pipe
            } else {
                process.standardError = pipe
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                capture.append(handle.availableData)
            }
            return pipe
        }
    }

    private func clearHandlers(_ stdout: Pipe?, _ stderr: Pipe?) {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
    }

    private func drain(_ pipe: Pipe?, into capture: OutputCapture) {
        guard let pipe else { return }
        let handle = pipe.fileHandleForReading
        defer { try? handle.close() }

        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if count > 0 {
                capture.append(Data(buffer.prefix(count)))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                // EOF ou EAGAIN: tudo que estava disponível foi capturado.
                return
            }
        }
    }

    private func result(
        termination: CLIProcessTermination,
        stdout: OutputCapture,
        stderr: OutputCapture,
        startedAt: Date
    ) -> CLIProcessResult {
        CLIProcessResult(
            termination: termination,
            stdout: stdout.snapshot(),
            stderr: stderr.snapshot(),
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func terminate(
        _ process: Process,
        allowsGracePeriod: Bool = true
    ) async {
        guard process.isRunning else { return }
        let rootPID = process.processIdentifier
        let descendants = Self.descendantProcessIDs(of: rootPID)
        Self.signal(SIGTERM, processIDs: descendants + [rootPID])
        if allowsGracePeriod {
            let deadline = Date().addingTimeInterval(1)
            while (process.isRunning
                   || descendants.contains(where: Self.processExists))
                    && Date() < deadline {
                guard !Task.isCancelled else { break }
                do {
                    try await Task.sleep(nanoseconds: 25_000_000)
                } catch {
                    break
                }
            }
        }
        Self.signal(
            SIGKILL,
            processIDs: Self.forceKillTargets(
                rootPID: rootPID,
                initiallyTracked: descendants
            )
        )
    }

    private static func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        guard rootPID > 1 else { return [] }
        var visited: Set<pid_t> = [rootPID]
        var postorder: [pid_t] = []

        func visit(_ parentPID: pid_t) {
            for childPID in directChildProcessIDs(of: parentPID)
                where childPID > 1
                    && childPID != getpid()
                    && visited.insert(childPID).inserted {
                visit(childPID)
                postorder.append(childPID)
            }
        }

        visit(rootPID)
        return postorder
    }

    private static func directChildProcessIDs(
        of parentPID: pid_t
    ) -> [pid_t] {
        let estimate = proc_listchildpids(parentPID, nil, 0)
        guard estimate > 0 else { return [] }
        var capacity = max(16, Int(estimate))

        for attempt in 0..<2 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { bytes -> Int32 in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return proc_listchildpids(
                    parentPID,
                    baseAddress,
                    Int32(bytes.count)
                )
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

    private static func signal(
        _ signal: Int32,
        processIDs: [pid_t]
    ) {
        let appPID = getpid()
        var signaled = Set<pid_t>()
        for pid in processIDs
            where pid > 1
                && pid != appPID
                && signaled.insert(pid).inserted {
            kill(pid, signal)
        }
    }

    private static func forceKillTargets(
        rootPID: pid_t,
        initiallyTracked: [pid_t]
    ) -> [pid_t] {
        var targets: [pid_t] = []
        var seen = Set<pid_t>()
        for pid in initiallyTracked + [rootPID] where processExists(pid) {
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
}

private final class EventRace: @unchecked Sendable {
    private let lock = NSLock()
    private var event: SystemCLIProcessRuntime.Event?
    private var continuation:
        CheckedContinuation<SystemCLIProcessRuntime.Event, Never>?

    func resolve(_ newEvent: SystemCLIProcessRuntime.Event) {
        let waiter:
            CheckedContinuation<SystemCLIProcessRuntime.Event, Never>?
        lock.lock()
        if event != nil {
            lock.unlock()
            return
        }
        event = newEvent
        waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(returning: newEvent)
    }

    func wait() async -> SystemCLIProcessRuntime.Event {
        await withCheckedContinuation { waiter in
            lock.lock()
            if let event {
                lock.unlock()
                waiter.resume(returning: event)
            } else {
                continuation = waiter
                lock.unlock()
            }
        }
    }
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        let waiter: CheckedContinuation<Int32, Never>?
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { waiter in
            lock.lock()
            if let status {
                lock.unlock()
                waiter.resume(returning: status)
            } else {
                continuation = waiter
                lock.unlock()
            }
        }
    }
}

private final class OutputCapture: @unchecked Sendable {
    private static let marker = Data(
        CapturedCLIOutput.truncationMarker.utf8
    )

    private let policy: CLIProcessOutputPolicy
    private let onOverflow: () -> Void
    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var truncated = false
    private var overflowReported = false

    init(
        policy: CLIProcessOutputPolicy,
        onOverflow: @escaping () -> Void
    ) {
        self.policy = policy
        self.onOverflow = onOverflow
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var reportOverflow = false
        lock.lock()
        switch policy {
        case .discard:
            break
        case .capture(let requestedLimit, let overflow):
            let limit = max(0, requestedLimit)
            switch overflow {
            case .fail:
                let available = max(0, limit - head.count)
                if available > 0 {
                    head.append(chunk.prefix(available))
                }
                if chunk.count > available {
                    truncated = true
                    if !overflowReported {
                        overflowReported = true
                        reportOverflow = true
                    }
                }
            case .truncateHeadAndTail:
                appendTruncating(chunk, limit: limit)
            }
        }
        lock.unlock()
        if reportOverflow { onOverflow() }
    }

    func snapshot() -> CapturedCLIOutput {
        lock.lock()
        let head = self.head
        let tail = self.tail
        let truncated = self.truncated
        let limit: Int?
        switch policy {
        case .discard:
            limit = nil
        case .capture(let requestedLimit, _):
            limit = max(0, requestedLimit)
        }
        lock.unlock()

        let text: String
        var representationWasTruncated = truncated
        if truncated, !tail.isEmpty, let limit {
            let marker = String(decoding: Self.marker, as: UTF8.self)
            let available = max(0, limit - Self.marker.count)
            let headLimit = available / 2
            let tailLimit = available - headLimit
            text = Self.boundedUTF8Prefix(
                Self.validUTF8Prefix(from: head),
                maxBytes: headLimit
            )
                + marker
                + Self.boundedUTF8Suffix(
                    Self.validUTF8Fragment(
                        from: tail,
                        mayStartMidCharacter: true
                    ),
                    maxBytes: tailLimit
                )
        } else {
            let decoded = Self.validUTF8Fragment(
                from: head,
                mayStartMidCharacter: false
            )
            if let limit, Data(decoded.utf8).count > limit {
                text = Self.boundedUTF8Prefix(
                    decoded,
                    maxBytes: limit
                )
                representationWasTruncated = true
            } else {
                text = decoded
            }
        }
        return CapturedCLIOutput(
            data: Data(text.utf8),
            wasTruncated: representationWasTruncated,
            text: text
        )
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowReported
    }

    private func appendTruncating(_ chunk: Data, limit: Int) {
        guard limit > 0 else {
            truncated = true
            return
        }
        if !truncated, chunk.count <= limit - head.count {
            head.append(chunk)
            return
        }

        let markerCount = min(Self.marker.count, limit)
        let available = limit - markerCount
        let headLimit = available / 2
        let tailLimit = available - headLimit
        if !truncated {
            let previous = head
            head = Data(previous.prefix(headLimit))
            if head.count < headLimit {
                head.append(chunk.prefix(headLimit - head.count))
            }
            if tailLimit > 0 {
                if chunk.count >= tailLimit {
                    tail = Data(chunk.suffix(tailLimit))
                } else {
                    tail = Data(
                        previous.suffix(tailLimit - chunk.count)
                    )
                    tail.append(chunk)
                }
            }
            truncated = true
            return
        }
        guard tailLimit > 0 else { return }
        if chunk.count >= tailLimit {
            tail = Data(chunk.suffix(tailLimit))
        } else {
            let overflow = max(
                0,
                tail.count + chunk.count - tailLimit
            )
            if overflow > 0 {
                tail.removeFirst(overflow)
            }
            tail.append(chunk)
        }
    }

    private static func validUTF8Prefix(from data: Data) -> String {
        for suffixDrop in 0...min(3, data.count) {
            let end = data.index(data.endIndex, offsetBy: -suffixDrop)
            if let string = String(
                data: data[..<end],
                encoding: .utf8
            ) {
                return string
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func validUTF8Fragment(
        from data: Data,
        mayStartMidCharacter: Bool
    ) -> String {
        let maximumPrefixDrop =
            mayStartMidCharacter ? min(3, data.count) : 0
        for prefixDrop in 0...maximumPrefixDrop {
            let remaining = data.count - prefixDrop
            for suffixDrop in 0...min(3, remaining) {
                let start = data.index(
                    data.startIndex,
                    offsetBy: prefixDrop
                )
                let end = data.index(
                    data.endIndex,
                    offsetBy: -suffixDrop
                )
                if let string = String(
                    data: data[start..<end],
                    encoding: .utf8
                ) {
                    return string
                }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func boundedUTF8Prefix(
        _ string: String,
        maxBytes: Int
    ) -> String {
        guard maxBytes > 0 else { return "" }
        let bytes = Data(string.utf8)
        guard bytes.count > maxBytes else { return string }
        return validUTF8Prefix(from: Data(bytes.prefix(maxBytes)))
    }

    private static func boundedUTF8Suffix(
        _ string: String,
        maxBytes: Int
    ) -> String {
        guard maxBytes > 0 else { return "" }
        let bytes = Data(string.utf8)
        guard bytes.count > maxBytes else { return string }
        return validUTF8Fragment(
            from: Data(bytes.suffix(maxBytes)),
            mayStartMidCharacter: true
        )
    }
}
