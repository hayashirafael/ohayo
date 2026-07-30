import XCTest
@testable import Ohayo

final class PrivacyLocalizationTests: XCTestCase {
    func testHistoricoENotificacoesTemCopiasGenericasEmIngles() {
        let strings = L10n(language: .english)

        XCTAssertEqual(strings.clearHistory, "Clear history")
        XCTAssertEqual(strings.clearHistoryConfirmationTitle, "Clear all history?")
        XCTAssertEqual(
            strings.clearHistoryConfirmationBody,
            "This permanently removes every recorded run."
        )
        XCTAssertEqual(strings.clearHistoryAction, "Clear")
        XCTAssertEqual(
            strings.showSensitiveNotificationDetails,
            "Show sensitive details in notifications"
        )
        XCTAssertEqual(strings.genericNotificationFailureTitle, "Ohayo schedule failed")
        XCTAssertEqual(
            strings.genericNotificationFailureBody,
            "Open History in Ohayo to see the error details."
        )
        XCTAssertEqual(strings.genericNotificationResponseTitle, "Ohayo response ready")
        XCTAssertEqual(
            strings.genericNotificationResponseBody,
            "Open History in Ohayo to read the response."
        )
        XCTAssertEqual(strings.genericNotificationSuccessTitle, "Ohayo schedule completed")
        XCTAssertEqual(
            strings.genericNotificationSuccessBody,
            "Open History in Ohayo to see the run details."
        )
        XCTAssertEqual(strings.timeout, "Timeout")
        XCTAssertEqual(strings.limitDuration, "Limit duration")
        XCTAssertEqual(strings.durationInMinutes, "Duration in minutes")
        XCTAssertEqual(strings.minutesUnit, "minutes")
        XCTAssertEqual(
            strings.saveNeedsPositiveTimeout,
            "Enter a duration greater than zero"
        )
        XCTAssertEqual(
            strings.bootstrapWhenInactive,
            "Try to start when no active window is detected"
        )
        XCTAssertTrue(
            strings.bootstrapWhenInactiveHelp.contains("may require confirmation")
        )
        XCTAssertTrue(
            strings.bootstrapWhenInactiveHelp.contains("can consume provider quota")
        )
        XCTAssertEqual(strings.quotaUnavailable, "quota unavailable")
        XCTAssertEqual(strings.needsAttention, "needs attention")
        XCTAssertEqual(strings.retriesAt("10:00"), "retries 10:00")
        XCTAssertEqual(strings.mayTryAt("10:00"), "may try 10:00")
        XCTAssertEqual(
            strings.quotaUnavailableEvent,
            "Quota could not be verified; no command was sent."
        )
    }

    func testHistoricoENotificacoesTemCopiasGenericasEmPortugues() {
        let strings = L10n(language: .portuguese)

        XCTAssertEqual(strings.clearHistory, "Limpar histórico")
        XCTAssertEqual(strings.clearHistoryConfirmationTitle, "Limpar todo o histórico?")
        XCTAssertEqual(
            strings.clearHistoryConfirmationBody,
            "Isso remove permanentemente todas as execuções registradas."
        )
        XCTAssertEqual(strings.clearHistoryAction, "Limpar")
        XCTAssertEqual(
            strings.showSensitiveNotificationDetails,
            "Mostrar detalhes sensíveis nas notificações"
        )
        XCTAssertEqual(strings.genericNotificationFailureTitle, "Agendamento do Ohayo falhou")
        XCTAssertEqual(
            strings.genericNotificationFailureBody,
            "Abra o Histórico no Ohayo para ver os detalhes do erro."
        )
        XCTAssertEqual(strings.genericNotificationResponseTitle, "Resposta do Ohayo pronta")
        XCTAssertEqual(
            strings.genericNotificationResponseBody,
            "Abra o Histórico no Ohayo para ler a resposta."
        )
        XCTAssertEqual(
            strings.genericNotificationSuccessTitle,
            "Agendamento do Ohayo concluído"
        )
        XCTAssertEqual(
            strings.genericNotificationSuccessBody,
            "Abra o Histórico no Ohayo para ver os detalhes da execução."
        )
        XCTAssertEqual(strings.timeout, "Tempo limite")
        XCTAssertEqual(strings.limitDuration, "Limitar duração")
        XCTAssertEqual(strings.durationInMinutes, "Duração em minutos")
        XCTAssertEqual(strings.minutesUnit, "minutos")
        XCTAssertEqual(
            strings.saveNeedsPositiveTimeout,
            "Informe uma duração maior que zero"
        )
        XCTAssertEqual(
            strings.bootstrapWhenInactive,
            "Tentar iniciar quando não houver janela ativa"
        )
        XCTAssertTrue(
            strings.bootstrapWhenInactiveHelp.contains("podem exigir confirmação")
        )
        XCTAssertTrue(
            strings.bootstrapWhenInactiveHelp.contains("pode consumir cota")
        )
        XCTAssertEqual(strings.quotaUnavailable, "cota indisponível")
        XCTAssertEqual(strings.needsAttention, "requer atenção")
        XCTAssertEqual(strings.retriesAt("10:00"), "tenta novamente 10:00")
        XCTAssertEqual(strings.mayTryAt("10:00"), "pode tentar 10:00")
        XCTAssertEqual(
            strings.quotaUnavailableEvent,
            "Não foi possível verificar a cota; nenhum comando foi enviado."
        )
    }
}
