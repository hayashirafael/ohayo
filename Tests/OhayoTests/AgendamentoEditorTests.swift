import XCTest
@testable import Ohayo

@MainActor
final class AgendamentoEditorTests: XCTestCase {
    private func makeState() -> AppState {
        let defaults = UserDefaults(
            suiteName: "ohayo-editor-test-\(UUID().uuidString)"
        )!
        defaults.set([String](), forKey: "registeredAccounts")
        return AppState(
            defaults: defaults,
            home: URL(fileURLWithPath: "/tmp/ohayo-editor-home")
        )
    }

    func testRestauraENormalizaPayloadSemPerderSemantica() throws {
        let original = ScheduledTask(
            uid: UUID(),
            name: "Revisão",
            command: Message(
                text: " revise ",
                kind: .codex,
                configDir: "/tmp/conta-codex",
                workingDir: "/tmp/projeto",
                showResponse: true,
                runInTerminal: false,
                timeoutSeconds: 1_800,
                notifyOnSuccess: true,
                codexModel: "gpt-5",
                codexReasoning: .high,
                skill: "review"
            ),
            repetition: .fixed,
            times: [780, 540],
            weekdays: [2, 3, 4, 5, 6],
            enabled: true
        )
        let editor = AgendamentoEditor(
            state: makeState(),
            isDirectory: { _ in true }
        )

        let evaluation = editor.evaluate(
            AgendamentoDraft(editing: original)
        )

        XCTAssertEqual(evaluation.issues, [])
        XCTAssertEqual(evaluation.normalized.uid, original.uid)
        XCTAssertEqual(evaluation.normalized.name, original.name)
        XCTAssertEqual(evaluation.normalized.resolvedCommand.text, "revise")
        XCTAssertEqual(
            evaluation.normalized.resolvedCommand.kind,
            original.resolvedCommand.kind
        )
        XCTAssertEqual(
            evaluation.normalized.resolvedCommand.configDir,
            "/tmp/conta-codex"
        )
        XCTAssertEqual(evaluation.normalized.times, [540, 780])
        XCTAssertEqual(
            evaluation.normalized.weekdays,
            original.weekdays
        )
    }

    func testTrocaDeProviderLimpaEstadoIncompativelEShellForcaFixo() {
        var draft = AgendamentoDraft(
            editing: ScheduledTask(
                uid: UUID(),
                command: Message(
                    text: "revisar",
                    kind: .claude,
                    configDir: "/tmp/claude",
                    runInTerminal: true,
                    skill: "review"
                ),
                repetition: .continuous
            )
        )

        draft.changeKind(to: .shell)

        XCTAssertEqual(draft.kind, .shell)
        XCTAssertNil(draft.account)
        XCTAssertNil(draft.skill)
        XCTAssertEqual(draft.outputMode, .none)
        XCTAssertEqual(draft.repetition, .fixed)
    }

    func testSelecionarSkillDesligaSafeModeSemReligarAoLimpar() {
        var draft = AgendamentoDraft(editing: nil)

        draft.selectSkill("review")
        draft.selectSkill(nil)

        XCTAssertFalse(draft.safeMode)
        XCTAssertNil(draft.skill)
    }

    func testContaExplicitaAusenteBloqueiaSaveSemVirarDefault() {
        let state = makeState()
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in false }
        )
        var draft = AgendamentoDraft(editing: nil)
        draft.text = "revisar"
        draft.account = "/Volumes/offline/claude"

        let evaluation = editor.evaluate(draft)
        let result = editor.apply(.save(draft))

        XCTAssertEqual(
            evaluation.normalized.resolvedCommand.configDir,
            "/Volumes/offline/claude"
        )
        XCTAssertEqual(
            evaluation.issues,
            [.accountUnavailable(
                URL(fileURLWithPath: "/Volumes/offline/claude")
            )]
        )
        XCTAssertEqual(result, .failure(.invalid(evaluation.issues)))
        XCTAssertTrue(state.tasks.isEmpty)
    }

    func testSnapshotDoFormularioAvaliaContaUmaUnicaVez() {
        let state = makeState()
        let account = "/Volumes/offline/claude"
        let existing = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "primeiro",
                kind: .claude,
                configDir: account
            ),
            repetition: .continuous
        )
        state.tasks = [existing]
        var directoryChecks = 0
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in
                directoryChecks += 1
                return false
            }
        )
        var draft = AgendamentoDraft(editing: nil)
        draft.text = "segundo"
        draft.account = account
        draft.repetition = .continuous

        let snapshot = editor.formSnapshot(for: draft)

        XCTAssertFalse(snapshot.canSave)
        XCTAssertTrue(snapshot.hasAccountUnavailableIssue)
        XCTAssertTrue(snapshot.hasContinuousConflict)
        XCTAssertEqual(
            snapshot.firstIssue,
            .accountUnavailable(URL(fileURLWithPath: account))
        )
        XCTAssertEqual(directoryChecks, 1)
    }

    func testSaveRevalidaConflitoContinuoAtomicamente() {
        let state = makeState()
        let account = "/tmp/conta-compartilhada"
        let existing = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "primeiro",
                kind: .claude,
                configDir: account
            ),
            repetition: .continuous
        )
        state.tasks = [existing]
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in true }
        )
        var draft = AgendamentoDraft(editing: nil)
        draft.text = "segundo"
        draft.account = account
        draft.repetition = .continuous

        let result = editor.apply(.save(draft))

        XCTAssertEqual(
            result,
            .failure(.invalid([
                .continuousConflict(existing: existing.uid),
            ]))
        )
        XCTAssertEqual(state.tasks, [existing])
    }

    func testEdicaoObsoletaNaoSobrescreveMudancaExterna() {
        let state = makeState()
        let original = ScheduledTask(
            uid: UUID(),
            name: "original",
            command: Message(text: "revisar", kind: .claude),
            times: [540],
            weekdays: Set(1...7)
        )
        state.tasks = [original]
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in true }
        )
        var draft = AgendamentoDraft(editing: original)
        draft.name = "form"
        state.tasks[0].name = "mudança externa"

        let result = editor.apply(.save(draft))

        XCTAssertEqual(result, .failure(.stale(original.uid)))
        XCTAssertEqual(state.tasks[0].name, "mudança externa")
    }

    func testEdicaoRemovidaNaoRessuscitaTask() {
        let state = makeState()
        let original = ScheduledTask(
            uid: UUID(),
            command: Message(text: "revisar", kind: .claude),
            times: [540],
            weekdays: Set(1...7)
        )
        state.tasks = [original]
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in true }
        )
        let draft = AgendamentoDraft(editing: original)
        state.tasks = []

        let result = editor.apply(.save(draft))

        XCTAssertEqual(result, .failure(.notFound(original.uid)))
        XCTAssertTrue(state.tasks.isEmpty)
    }

    func testDeleteEToggleTambemPassamPelaMesmaSeam() {
        let state = makeState()
        var task = ScheduledTask(
            uid: UUID(),
            command: Message(text: "revisar", kind: .claude),
            times: [540],
            weekdays: Set(1...7)
        )
        task.enabled = false
        state.tasks = [task]
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in true }
        )

        XCTAssertEqual(
            editor.apply(.setEnabled(id: task.uid, enabled: true)),
            .success(.enabled(task.uid, true))
        )
        XCTAssertTrue(state.tasks[0].enabled)
        XCTAssertEqual(
            editor.apply(.delete(id: task.uid)),
            .success(.deleted(task.uid))
        )
        XCTAssertTrue(state.tasks.isEmpty)
    }

    func testDesabilitarContaEhUmaUnicaMudancaDeColecao() {
        let state = makeState()
        let account = URL(fileURLWithPath: "/tmp/conta-removida")
        let matching = (0..<2).map { index in
            ScheduledTask(
                uid: UUID(),
                name: "matching-\(index)",
                command: Message(
                    text: "revisar",
                    kind: .claude,
                    configDir: account.path
                ),
                times: [540],
                weekdays: Set(1...7)
            )
        }
        let untouched = ScheduledTask(
            uid: UUID(),
            name: "outra",
            command: Message(
                text: "revisar",
                kind: .claude,
                configDir: "/tmp/outra-conta"
            ),
            times: [540],
            weekdays: Set(1...7)
        )
        state.tasks = matching + [untouched]
        let editor = AgendamentoEditor(
            state: state,
            isDirectory: { _ in true }
        )

        XCTAssertEqual(
            editor.apply(.disableAccount(account)),
            .success(.disabledAccount(
                account,
                matching.map(\.uid)
            ))
        )
        XCTAssertTrue(
            state.tasks
                .filter { matching.map(\.uid).contains($0.uid) }
                .allSatisfy { !$0.enabled }
        )
        XCTAssertTrue(
            state.tasks.first { $0.uid == untouched.uid }?.enabled == true
        )
    }
}
