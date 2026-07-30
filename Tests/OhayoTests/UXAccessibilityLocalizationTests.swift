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

    func testAvisoDeNovaAtualizacaoTemVersaoEAcaoNosDoisIdiomas() {
        let english = L10n(language: .english)
        XCTAssertEqual(
            english.updateAvailableTitle(version: "1.3.0"),
            "Ohayo 1.3.0 is available"
        )
        XCTAssertEqual(english.updateNow, "Update Now")

        let portuguese = L10n(language: .portuguese)
        XCTAssertEqual(
            portuguese.updateAvailableTitle(version: "1.3.0"),
            "Ohayo 1.3.0 está disponível"
        )
        XCTAssertEqual(portuguese.updateNow, "Atualizar agora")
    }

    func testDiretorioPadraoDaInterfaceEhOWorkspaceDoOhayo() {
        XCTAssertEqual(
            L10n(language: .english).workingDirectoryDefault,
            "Directory (Ohayo workspace by default)"
        )
        XCTAssertEqual(
            L10n(language: .portuguese).workingDirectoryDefault,
            "Diretório (workspace do Ohayo por padrão)"
        )
    }

    func testPickerEConsentimentoExplicamTrustDaPasta() {
        XCTAssertTrue(
            L10n(language: .english).workingDirectoryTrustNotice.contains(
                "pre-authorize project trust"
            )
        )
        XCTAssertTrue(
            L10n(language: .portuguese).workingDirectoryTrustNotice.contains(
                "pré-autorize o trust do projeto"
            )
        )
        XCTAssertEqual(
            L10n(language: .english).trustWorkingDirectory,
            "Trust this folder for Claude"
        )
        XCTAssertEqual(
            L10n(language: .portuguese).trustWorkingDirectory,
            "Confiar nesta pasta para o Claude"
        )
        XCTAssertTrue(
            L10n(language: .portuguese).trustWorkingDirectoryHelp.contains(
                "ao salvar"
            )
        )
        XCTAssertTrue(
            L10n(language: .portuguese).trustWorkingDirectoryHelp.contains(
                "projeto Claude"
            )
        )
    }

    func testModosDeAcessoCodexTemCopiasLocalizadas() {
        let english = L10n(language: .english)
        XCTAssertEqual(english.codexAccess, "Access")
        XCTAssertEqual(
            CodexAccessMode.allCases.map(english.codexAccessMode),
            ["Full access", "Folder write", "Read-only"]
        )

        let portuguese = L10n(language: .portuguese)
        XCTAssertEqual(portuguese.codexAccess, "Acesso")
        XCTAssertEqual(
            CodexAccessMode.allCases.map(portuguese.codexAccessMode),
            ["Acesso total", "Escrita na pasta", "Somente leitura"]
        )
        XCTAssertTrue(
            portuguese.codexAccessModeHelp(.workspaceWrite).contains(
                "pasta de trabalho confiada"
            )
        )
        XCTAssertTrue(
            portuguese.codexAccessModeHelp(.readOnly).contains(
                "somente leitura"
            )
        )
        XCTAssertTrue(
            english.workingDirectoryAuthorizationDenied(for: .codex)
                .contains("Read-only")
        )
        XCTAssertTrue(
            portuguese.workingDirectoryAuthorizationDenied(for: .codex)
                .contains("Somente leitura")
        )
        XCTAssertTrue(
            english.workingDirectoryAuthorizationDenied(for: .claude)
                .contains("Trust this folder for Claude")
        )
    }

    func testArquivosDeRespostaEModelosFallbackTemCopiasLocalizadas() {
        let english = L10n(language: .english)
        XCTAssertEqual(english.markdownFile, "Markdown (.md)")
        XCTAssertEqual(english.responseFileDefaultName, "response")
        XCTAssertEqual(
            english.showShellResponseDescription,
            "Runs in background and keeps the output in History."
        )
        XCTAssertEqual(
            english.codexFallbackModelDescription("gpt-5.6-sol"),
            "Latest frontier agentic coding model."
        )

        let portuguese = L10n(language: .portuguese)
        XCTAssertEqual(portuguese.markdownFile, "Markdown (.md)")
        XCTAssertEqual(portuguese.responseFileDefaultName, "resposta")
        XCTAssertEqual(
            portuguese.showShellResponseDescription,
            "Executa em segundo plano e mantém a saída no Histórico."
        )
        XCTAssertEqual(
            portuguese.codexFallbackModelDescription("gpt-5.6-sol"),
            "Modelo agente de programação de última geração."
        )
    }
}
