import XCTest
@testable import Ohayo

@MainActor
final class UXAccessibilityLocalizationTests: XCTestCase {
    func testNotificacaoDeSucessoNaoPersisteNoTerminalInterativo() {
        XCTAssertFalse(
            AgendamentoDraft.effectiveNotifyOnSuccess(
                true,
                outputMode: .terminal
            )
        )
        XCTAssertTrue(
            AgendamentoDraft.effectiveNotifyOnSuccess(
                true,
                outputMode: .none
            )
        )
        XCTAssertTrue(
            AgendamentoDraft.effectiveNotifyOnSuccess(
                true,
                outputMode: .response
            )
        )
    }

    func testRestauracaoLimpaNotificacaoInaplicavelDoTerminal() {
        let task = ScheduledTask(
            uid: UUID(),
            command: Message(
                text: "x",
                kind: .claude,
                runInTerminal: true,
                notifyOnSuccess: true
            )
        )

        let restored = AgendamentoDraft(editing: task)

        XCTAssertEqual(restored.outputMode, .terminal)
        XCTAssertFalse(restored.notifyOnSuccess)
    }

    func testCopiasCanonicasNaoExpoemRenovacaoComoConceitoDeUI() throws {
        for language in AppLanguage.allCases {
            let strings = L10n(language: language)
            let copies = [
                strings.remainingInMenuBarFooter,
                strings.scheduleListFooter,
                strings.fixedContinuousDescription,
                strings.renewalFallbackName,
                strings.renewsAt("10:00"),
                try XCTUnwrap(strings.origin(.renewal)),
            ]
            let normalized = copies.joined(separator: "\n").lowercased()

            XCTAssertFalse(normalized.contains("renewal"))
            XCTAssertFalse(normalized.contains("renovação"))
            XCTAssertFalse(normalized.contains("renova "))
        }
    }

    func testCopiasAcessiveisDiferenciamEditarESalvarAlias() {
        let english = L10n(language: .english)
        XCTAssertEqual(english.editAccountAlias("Work"), "Edit alias for Work")
        XCTAssertEqual(english.saveAccountAlias("Work"), "Save alias for Work")

        let portuguese = L10n(language: .portuguese)
        XCTAssertEqual(
            portuguese.editAccountAlias("Trabalho"),
            "Editar apelido de Trabalho"
        )
        XCTAssertEqual(
            portuguese.saveAccountAlias("Trabalho"),
            "Salvar apelido de Trabalho"
        )
    }

    func testTerminalExplicaPorQueNotificacaoDeSucessoEstaIndisponivel() {
        let english = L10n(language: .english)
        XCTAssertTrue(
            english.notifyOnSuccessUnavailableInTerminal.contains(
                "cannot observe their completion"
            )
        )

        let portuguese = L10n(language: .portuguese)
        XCTAssertTrue(
            portuguese.notifyOnSuccessUnavailableInTerminal.contains(
                "não acompanha sua conclusão"
            )
        )
    }

    func testAtualizacaoTemAcaoLocalizadaNosDoisIdiomas() {
        XCTAssertEqual(
            L10n(language: .english).checkForUpdates,
            "Check for Updates…"
        )
        XCTAssertEqual(
            L10n(language: .portuguese).checkForUpdates,
            "Buscar atualizações…"
        )
    }
}
