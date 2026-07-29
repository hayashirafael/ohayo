import Darwin
import XCTest
@testable import Ohayo

final class CLIProcessRuntimeTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func waitUntil(
        timeout: TimeInterval,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private func processExists(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func testCapturaOsDoisStreamsERetornaExitStatus() async {
        let runtime = SystemCLIProcessRuntime()
        let result = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: [
                "-c",
                "printf 'saida'; printf 'erro' >&2; exit 7",
            ],
            timeout: 2
        ))

        XCTAssertEqual(result.termination, .exited(7))
        XCTAssertEqual(result.stdout.text, "saida")
        XCTAssertEqual(result.stderr.text, "erro")
    }

    func testOverflowFailEncerraCapturaEstrutural() async {
        let runtime = SystemCLIProcessRuntime()
        let result = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: ["-c", "yes x | head -c 4096"],
            timeout: 2,
            stdout: .capture(maxBytes: 128, overflow: .fail),
            stderr: .discard
        ))

        XCTAssertEqual(result.termination, .outputLimitExceeded)
        XCTAssertLessThanOrEqual(result.stdout.data.count, 128)
    }

    func testOverflowFailVenceExitMesmoQuandoSaidaEhDrenadaDepois() async {
        let executable = URL(fileURLWithPath: "/usr/bin/printf")

        let results = await withTaskGroup(
            of: CLIProcessResult.self,
            returning: [CLIProcessResult].self
        ) { group in
            for _ in 0..<64 {
                group.addTask {
                    await SystemCLIProcessRuntime().run(CLIProcessRequest(
                        executable: executable,
                        arguments: ["x"],
                        timeout: 2,
                        stdout: .capture(maxBytes: 0, overflow: .fail),
                        stderr: .discard
                    ))
                }
            }
            var results: [CLIProcessResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertTrue(
            results.allSatisfy {
                $0.termination == .outputLimitExceeded
            },
            "overflow .fail não pode virar exit bem-sucedido"
        )
    }

    func testTruncagemPreservaInicioEFimUTF8DentroDoLimite() async {
        let runtime = SystemCLIProcessRuntime()
        let result = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: [
                "-c",
                "printf 'INICIO🙂'; yes 'miolo🙂' | head -c 4096; printf 'FIM🙂'",
            ],
            timeout: 2,
            stdout: .capture(
                maxBytes: 128,
                overflow: .truncateHeadAndTail
            ),
            stderr: .discard
        ))

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertTrue(result.stdout.wasTruncated)
        XCTAssertTrue(result.stdout.text.hasPrefix("INICIO🙂"))
        XCTAssertTrue(result.stdout.text.hasSuffix("FIM🙂"))
        XCTAssertTrue(
            result.stdout.text.contains(CapturedCLIOutput.truncationMarker)
        )
        XCTAssertLessThanOrEqual(result.stdout.data.count, 128)
        XCTAssertNotNil(
            String(data: result.stdout.data, encoding: .utf8),
            "a saída truncada deve continuar sendo UTF-8 válido"
        )
    }

    func testForneceStdinEFechaQuandoNaoHaEntrada() async {
        let runtime = SystemCLIProcessRuntime()
        let supplied = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: ["-c", "cat"],
            standardInput: Data("segredo".utf8),
            timeout: 2
        ))
        let closed = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: ["-c", "cat; printf 'fechado'"],
            timeout: 2
        ))

        XCTAssertEqual(supplied.termination, .exited(0))
        XCTAssertEqual(supplied.stdout.text, "segredo")
        XCTAssertEqual(closed.termination, .exited(0))
        XCTAssertEqual(closed.stdout.text, "fechado")
    }

    func testTimeoutEncerraProcessoSemEsperarIndefinidamente() async {
        let runtime = SystemCLIProcessRuntime()
        let start = Date()
        let result = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: ["-c", "sleep 5"],
            timeout: 0.1
        ))

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTimeoutSemCancelamentoPreservaGraceParaCleanup() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ohayo-runtime-cleanup-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: marker) }
        let runtime = SystemCLIProcessRuntime()

        let result = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: [
                "-c",
                "trap 'sleep 0.15; printf cleanup > \"\(marker.path)\"; "
                    + "exit 0' TERM; while :; do sleep 30; done",
            ],
            timeout: 0.1
        ))

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertEqual(
            try? String(contentsOf: marker, encoding: .utf8),
            "cleanup",
            "sem cancelamento, SIGTERM ainda deve ter grace para cleanup"
        )
    }

    func testSaidaDoProcessoRaizNaoEsperaDescendenteComPipeHerdado() async {
        let runtime = SystemCLIProcessRuntime()
        let start = Date()
        let result = await runtime.run(CLIProcessRequest(
            executable: shell,
            arguments: ["-c", "sleep 2 &"],
            timeout: 0.1
        ))

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            1,
            "a drenagem não pode aguardar EOF de um descendente órfão"
        )
    }

    func testCancelamentoDaTaskChegaAoProcesso() async {
        let runtime = SystemCLIProcessRuntime()
        let task = Task {
            await runtime.run(CLIProcessRequest(
                executable: shell,
                arguments: ["-c", "sleep 5"],
                timeout: 10
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.termination, .cancelled)
    }

    func testCancelamentoNaoEsperaGracePeriodDeTaskJaCancelada() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ohayo-runtime-pids-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: marker) }
        let runtime = SystemCLIProcessRuntime()
        let task = Task {
            await runtime.run(CLIProcessRequest(
                executable: shell,
                arguments: [
                    "-c",
                    "trap '' TERM; sleep 30 & child=$!; "
                        + "printf '%d %d' \"$$\" \"$child\" > '\(marker.path)'; "
                        + "wait \"$child\"; while :; do :; done",
                ],
                timeout: 10
            ))
        }
        let didStart = await waitUntil(timeout: 1) {
            FileManager.default.fileExists(atPath: marker.path)
        }
        XCTAssertTrue(didStart)
        let processIDs = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: " ")
            .compactMap { pid_t($0) }
        XCTAssertEqual(processIDs.count, 2)

        let start = Date()
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.termination, .cancelled)
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "cancelar deve escalar imediatamente, sem spin de um segundo"
        )
        let didTerminateTree = await waitUntil(timeout: 2) {
            processIDs.allSatisfy { !processExists($0) }
        }
        XCTAssertTrue(didTerminateTree)
    }

    func testCancelamentoAposTimeoutInterrompeGraceSemSpin() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ohayo-runtime-term-\(UUID().uuidString)"
            )
        let started = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ohayo-runtime-started-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: started)
        }
        let runtime = SystemCLIProcessRuntime()
        let task = Task {
            await runtime.run(CLIProcessRequest(
                executable: shell,
                arguments: [
                    "-c",
                    "trap 'printf term > \"\(marker.path)\"' TERM; "
                        + "printf started > '\(started.path)'; "
                        + "while :; do sleep 30; done",
                ],
                timeout: 0.2
            ))
        }
        let didStart = await waitUntil(timeout: 1) {
            FileManager.default.fileExists(atPath: started.path)
        }
        XCTAssertTrue(didStart)
        let timeoutWon = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: marker.path)
        }
        XCTAssertTrue(timeoutWon)

        let cancellationStartedAt = Date()
        task.cancel()
        let result = await task.value

        XCTAssertEqual(
            result.termination,
            .timedOut,
            "o primeiro evento continua sendo a autoridade do outcome"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStartedAt),
            0.5,
            "cancelar durante o grace deve escalar imediatamente"
        )
    }
}
