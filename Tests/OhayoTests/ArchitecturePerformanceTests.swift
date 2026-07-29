import XCTest
@testable import Ohayo

/// Benchmarks comparáveis usados para validar os refactors de arquitetura.
///
/// Eles não impõem um limite absoluto, porque máquinas e carga variam. O
/// relatório da mudança compara a mediana da mesma carga antes e depois.
@MainActor
final class ArchitecturePerformanceTests: XCTestCase {
    private final class InactiveDetector: SessionDetecting {
        func quotaWindowState(
            account: URL,
            provider: Provider
        ) async -> QuotaWindowState {
            .inactive
        }
    }

    private func elapsedMilliseconds(
        _ operation: () throws -> Void
    ) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    private func elapsedMilliseconds(
        _ operation: () async throws -> Void
    ) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    private func report(
        _ name: String,
        iterations: Int,
        milliseconds: Double
    ) {
        let perIteration = milliseconds / Double(iterations)
        print(
            "ARCH_BENCH name=\(name) iterations=\(iterations) "
                + "total_ms=\(String(format: "%.3f", milliseconds)) "
                + "per_iteration_ms=\(String(format: "%.6f", perIteration))"
        )
    }

    func testPreparacaoDeDispatchPorConta() throws {
        let iterations = 20_000
        let binary = URL(fileURLWithPath: "/usr/bin/true")
        let messages = [
            Message(text: "status", kind: .claude),
            Message(
                text: "review",
                kind: .claude,
                model: .opus,
                effort: .high,
                safeMode: false,
                configDir: "/tmp/ohayo-benchmark-claude",
                workingDir: "/tmp/project"
            ),
            Message(
                text: "review",
                kind: .codex,
                configDir: "/tmp/ohayo-benchmark-codex",
                workingDir: "/tmp/project",
                codexModel: "gpt-5",
                codexReasoning: .high
            ),
        ]
        var checksum = 0
        let preparer = DispatchPreparer(isDirectory: { _ in true })

        let elapsed = try elapsedMilliseconds {
            for index in 0..<iterations {
                let message = messages[index % messages.count]
                let dispatch = try preparer.prepare(.direct(
                    message,
                    origin: .manual
                )).get()
                guard case .provider(let plan) = dispatch.target else {
                    return XCTFail("benchmark requer target de provider")
                }
                let spec = try XCTUnwrap(
                    TerminalLauncher.spec(
                        for: dispatch.message,
                        claudeBinary: binary,
                        codexBinary: binary,
                        defaultWorkspace: URL(
                            fileURLWithPath: "/tmp/ohayo-benchmark-workspace"
                        ),
                        preparedPlan: plan
                    )
                )
                checksum &+= spec.terminalScript.utf8.count
            }
        }

        XCTAssertGreaterThan(checksum, 0)
        report(
            "account_dispatch_preparation",
            iterations: iterations,
            milliseconds: elapsed
        )
    }

    func testExecucaoDeProcessoCLICurto() async {
        let iterations = 8
        let runner = CommandRunner(
            timeout: 5,
            binaryOverride: URL(fileURLWithPath: "/usr/bin/true")
        )
        let message = Message(
            text: "1+1",
            kind: .claude,
            runInTerminal: false
        )
        let dispatch = try! DispatchPreparer().prepare(
            .direct(message, origin: .manual)
        ).get()

        let elapsed = await elapsedMilliseconds {
            for _ in 0..<iterations {
                XCTAssertEqual(await runner.run(dispatch), .success(""))
            }
        }

        report(
            "short_cli_process",
            iterations: iterations,
            milliseconds: elapsed
        )
    }

    func testRestauracaoDoEditorDeAgendamento() {
        let iterations = 100_000
        let task = ScheduledTask(
            uid: UUID(),
            name: "Revisão",
            command: Message(
                text: "revise",
                kind: .codex,
                configDir: "/tmp/ohayo-benchmark-codex",
                workingDir: "/tmp/project",
                showResponse: true,
                runInTerminal: false,
                timeoutSeconds: 300,
                notifyOnSuccess: true,
                codexModel: "gpt-5",
                codexReasoning: .high,
                skill: "review"
            ),
            repetition: .fixed,
            times: [540, 780],
            weekdays: [2, 3, 4, 5, 6],
            enabled: true
        )
        var checksum = 0

        let elapsed = elapsedMilliseconds {
            for _ in 0..<iterations {
                let restored = AgendamentoDraft(editing: task)
                checksum &+= restored.text.utf8.count
                checksum &+= restored.times.count
                checksum &+= restored.weekdays.count
            }
        }

        XCTAssertGreaterThan(checksum, 0)
        report(
            "schedule_editor_restore",
            iterations: iterations,
            milliseconds: elapsed
        )
    }

    func testSincronizacaoDoLifecycleContinuo() async {
        let accounts = (0..<40).map {
            URL(fileURLWithPath: "/tmp/ohayo-benchmark-account-\($0)")
        }
        let definitions = accounts.enumerated().map { index, account in
            let provider: Provider =
                index.isMultiple(of: 2) ? .claude : .codex
            var task = ScheduledTask(
                uid: UUID(),
                command: Message(
                    text: "revision-\(index)",
                    kind: provider == .claude ? .claude : .codex,
                    configDir: account.path
                ),
                repetition: .continuous
            )
            task.bootstrapWhenInactive = index.isMultiple(of: 2)
            return ContinuousScheduleDefinition(
                task: task,
                intendedAccount: account,
                availableAccount: account
            )
        }
        let input = ContinuousScheduleInput(definitions: definitions)
        let iterations = 25
        let engine = RenewalEngine(detector: InactiveDetector())

        let elapsed = await elapsedMilliseconds {
            for _ in 0..<iterations {
                await engine.synchronize(input)
            }
        }

        XCTAssertEqual(engine.snapshot.byTask.count, accounts.count)
        XCTAssertEqual(
            engine.snapshot.nextByAccount.count,
            accounts.count / 2
        )
        report(
            "continuous_lifecycle_sync",
            iterations: iterations,
            milliseconds: elapsed
        )
    }
}
