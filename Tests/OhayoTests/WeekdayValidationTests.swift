import XCTest
@testable import Ohayo

final class WeekdayValidationTests: XCTestCase {
    func testDecodeDescartaWeekdaysForaDoIntervaloDoCalendario() throws {
        let json = """
        {
          "uid": "11111111-1111-1111-1111-111111111111",
          "repetition": "fixed",
          "times": [540],
          "weekdays": [0, 2, 8]
        }
        """

        let task = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))

        XCTAssertEqual(task.weekdays, [2])
    }

    func testLocalizacaoIgnoraWeekdaysCorrompidosSemIndexarForaDoArray() {
        let english = L10n(language: .english)
        XCTAssertEqual(english.daysSummary([0, 2, 8]), "Mon")
        XCTAssertEqual(english.daysSummary([0, 8]), "no valid days")
        XCTAssertEqual(english.dayName(0), "Invalid day")
        XCTAssertEqual(english.dayName(8), "Invalid day")

        let portuguese = L10n(language: .portuguese)
        XCTAssertEqual(portuguese.daysSummary([0, 2, 8]), "seg")
        XCTAssertEqual(portuguese.daysSummary([0, 8]), "nenhum dia válido")
        XCTAssertEqual(portuguese.dayName(0), "Dia inválido")
        XCTAssertEqual(portuguese.dayName(8), "Dia inválido")
    }
}
