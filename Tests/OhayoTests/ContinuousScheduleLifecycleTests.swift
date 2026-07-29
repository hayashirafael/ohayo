import XCTest
@testable import Ohayo

@MainActor
final class ContinuousScheduleLifecycleTests: XCTestCase {
    private final class CountingDetector: SessionDetecting {
        var state: QuotaWindowState = .inactive
        private(set) var calls: [(URL, Provider)] = []

        func quotaWindowState(
            account: URL,
            provider: Provider
        ) async -> QuotaWindowState {
            calls.append((account, provider))
            return state
        }
    }

    private final class BlockingDetector: SessionDetecting {
        private(set) var calls: [(URL, Provider)] = []
        private var pending:
            [Int: CheckedContinuation<QuotaWindowState, Never>] = [:]
        private var callWaiters:
            [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func quotaWindowState(
            account: URL,
            provider: Provider
        ) async -> QuotaWindowState {
            let call = calls.count
            calls.append((account, provider))
            if call >= 2 {
                return .inactive
            }
            return await withCheckedContinuation { continuation in
                pending[call] = continuation
                let ready = callWaiters.filter { calls.count >= $0.count }
                callWaiters.removeAll { calls.count >= $0.count }
                ready.forEach { $0.continuation.resume() }
            }
        }

        func waitForCalls(_ count: Int) async {
            guard calls.count < count else { return }
            await withCheckedContinuation { continuation in
                callWaiters.append((count, continuation))
            }
        }

        func resolve(
            call: Int,
            with state: QuotaWindowState
        ) {
            pending.removeValue(forKey: call)?.resume(returning: state)
        }
    }

    // O engine usa NSTimer real mesmo com Clock fake. Ancora o cenário um ano
    // à frente para que timers armados pelo teste nunca vençam no RunLoop.
    private let now = Date().addingTimeInterval(365 * 24 * 60 * 60)

    private func task(
        text: String,
        account: URL,
        provider: Provider = .claude,
        bootstrap: Bool = false
    ) -> ScheduledTask {
        var task = ScheduledTask(
            uid: UUID(),
            name: text,
            command: Message(
                text: text,
                kind: provider == .codex ? .codex : .claude,
                configDir: account.path
            ),
            repetition: .continuous
        )
        task.bootstrapWhenInactive = bootstrap
        return task
    }

    func testSnapshotPublicaFaseCoerentePorTask() async {
        let detector = CountingDetector()
        let end = now.addingTimeInterval(3_600)
        detector.state = .active(until: end)
        let account = URL(fileURLWithPath: "/tmp/lifecycle-active")
        let scheduled = task(text: "active", account: account)
        let engine = RenewalEngine(
            detector: detector,
            clock: FakeClock(now: now)
        )

        await engine.synchronize(ContinuousScheduleInput(definitions: [
            ContinuousScheduleDefinition(
                task: scheduled,
                intendedAccount: account,
                availableAccount: account
            ),
        ]))

        XCTAssertEqual(
            engine.snapshot[scheduled.uid]?.phase,
            .scheduled(end)
        )
        XCTAssertEqual(
            engine.snapshot.nextByAccount[
                account.standardizedFileURL
            ],
            end
        )
    }

    func testConflitoPausaEAusenciaFalhamFechadoNoMesmoSnapshot() async {
        let detector = CountingDetector()
        let shared = URL(fileURLWithPath: "/tmp/lifecycle-shared")
        let pausedAccount =
            URL(fileURLWithPath: "/tmp/lifecycle-paused")
        let missingAccount =
            URL(fileURLWithPath: "/tmp/lifecycle-missing")
        let first = task(text: "first", account: shared)
        let second = task(text: "second", account: shared)
        let paused = task(text: "paused", account: pausedAccount)
        let missing = task(text: "missing", account: missingAccount)
        let engine = RenewalEngine(
            detector: detector,
            clock: FakeClock(now: now)
        )

        await engine.synchronize(ContinuousScheduleInput(definitions: [
            ContinuousScheduleDefinition(
                task: first,
                intendedAccount: shared,
                availableAccount: shared
            ),
            ContinuousScheduleDefinition(
                task: second,
                intendedAccount: shared,
                availableAccount: shared
            ),
            ContinuousScheduleDefinition(
                task: paused,
                intendedAccount: pausedAccount,
                availableAccount: pausedAccount,
                paused: true
            ),
            ContinuousScheduleDefinition(
                task: missing,
                intendedAccount: missingAccount,
                availableAccount: nil
            ),
        ]))

        XCTAssertEqual(engine.snapshot[first.uid]?.phase, .conflict)
        XCTAssertEqual(engine.snapshot[second.uid]?.phase, .conflict)
        XCTAssertEqual(engine.snapshot[paused.uid]?.phase, .paused)
        XCTAssertEqual(
            engine.snapshot[missing.uid]?.phase,
            .accountMissing
        )
        XCTAssertTrue(detector.calls.isEmpty)
    }

    func testContaDisponivelDiferenteDaPretendidaFalhaFechado() async {
        let detector = CountingDetector()
        let intended =
            URL(fileURLWithPath: "/tmp/lifecycle-intended")
        let other =
            URL(fileURLWithPath: "/tmp/lifecycle-other")
        let scheduled = task(text: "mismatch", account: intended)
        var dispatched = false
        let engine = RenewalEngine(
            detector: detector,
            clock: FakeClock(now: now),
            dispatch: { _, _ in
                dispatched = true
                return .completed
            }
        )

        await engine.synchronize(ContinuousScheduleInput(definitions: [
            ContinuousScheduleDefinition(
                task: scheduled,
                intendedAccount: intended,
                availableAccount: other
            ),
        ]))

        XCTAssertEqual(
            engine.snapshot[scheduled.uid]?.phase,
            .invalidConfiguration
        )
        XCTAssertTrue(detector.calls.isEmpty)
        XCTAssertFalse(dispatched)
    }

    func testDispatchRecebeTaskExataEPersisteRecoveryPelaMesmaIdentidade() async {
        let detector = CountingDetector()
        let account =
            URL(fileURLWithPath: "/tmp/lifecycle-bootstrap")
        let scheduled = task(
            text: "bootstrap",
            account: account,
            provider: .codex,
            bootstrap: true
        )
        var dispatched: [(ScheduledTask, RenewalEngine.Trigger)] = []
        var recoveries: [(UUID, RenewalRecoveryState?)] = []
        let engine = RenewalEngine(
            detector: detector,
            clock: FakeClock(now: now),
            dispatch: { task, trigger in
                dispatched.append((task, trigger))
                return .launched
            },
            persistRecovery: { task, recovery in
                recoveries.append((task.uid, recovery))
            }
        )

        await engine.synchronize(ContinuousScheduleInput(definitions: [
            ContinuousScheduleDefinition(
                task: scheduled,
                intendedAccount: account,
                availableAccount: account
            ),
        ]))

        XCTAssertEqual(dispatched.map(\.0), [scheduled])
        XCTAssertEqual(dispatched.map(\.1), [.bootstrap])
        XCTAssertEqual(recoveries.last?.0, scheduled.uid)
        XCTAssertEqual(
            engine.snapshot[scheduled.uid]?.phase,
            .cooldown(
                now.addingTimeInterval(SessionDetector.blockDuration),
                bootstrapOrigin: true
            )
        )
        XCTAssertEqual(detector.calls.last?.1, .codex)
    }

    func testQuotaIndisponivelTemUmaFaseSemInventarDeadline() async {
        let detector = CountingDetector()
        detector.state = .unavailable(reason: "schema changed")
        let account =
            URL(fileURLWithPath: "/tmp/lifecycle-unavailable")
        let scheduled = task(
            text: "unavailable",
            account: account,
            bootstrap: true
        )
        let engine = RenewalEngine(
            detector: detector,
            clock: FakeClock(now: now)
        )

        await engine.synchronize(ContinuousScheduleInput(definitions: [
            ContinuousScheduleDefinition(
                task: scheduled,
                intendedAccount: account,
                availableAccount: account
            ),
        ]))

        XCTAssertEqual(
            engine.snapshot[scheduled.uid]?.phase,
            .quotaUnavailable("schema changed")
        )
        XCTAssertTrue(engine.snapshot.nextByAccount.isEmpty)
    }

    func testResultadoObsoletoDoDetectorNaoDisparaTaskEditada() async {
        let detector = BlockingDetector()
        let account =
            URL(fileURLWithPath: "/tmp/lifecycle-stale-detector")
        let original = task(text: "original", account: account)
        var edited = original
        edited.command = Message(
            text: "edited",
            kind: .codex,
            configDir: account.path
        )
        var dispatched: [ScheduledTask] = []
        let engine = RenewalEngine(
            detector: detector,
            clock: FakeClock(now: now),
            dispatch: { task, _ in
                dispatched.append(task)
                return .completed
            }
        )
        let expiredRetry = RenewalRecoveryState.retry(
            notBefore: now.addingTimeInterval(-1),
            attempt: 1,
            bootstrapOrigin: false
        )

        let originalSynchronization = Task { @MainActor in
            await engine.synchronize(ContinuousScheduleInput(definitions: [
                ContinuousScheduleDefinition(
                    task: original,
                    intendedAccount: account,
                    availableAccount: account,
                    recovery: expiredRetry
                ),
            ]))
        }
        await detector.waitForCalls(1)

        let editedSynchronization = Task { @MainActor in
            await engine.synchronize(ContinuousScheduleInput(definitions: [
                ContinuousScheduleDefinition(
                    task: edited,
                    intendedAccount: account,
                    availableAccount: account
                ),
            ]))
        }
        await detector.waitForCalls(2)
        detector.resolve(call: 1, with: .inactive)
        await editedSynchronization.value

        detector.resolve(call: 0, with: .inactive)
        await originalSynchronization.value

        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertTrue(engine.snapshot.nextByAccount.isEmpty)
        XCTAssertEqual(
            engine.snapshot[edited.uid]?.phase,
            .waitingForWindow
        )
    }
}
