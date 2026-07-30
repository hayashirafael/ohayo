import XCTest
@testable import Ohayo

final class MarkdownResponseFormatterTests: XCTestCase {
    func testMarkdownRemoveMarcadoresEAplicaEnfase() {
        let formatted = MarkdownResponseFormatter.attributedString(
            "Resposta com **destaque** e `código`."
        )

        XCTAssertEqual(
            String(formatted.characters),
            "Resposta com destaque e código."
        )
        XCTAssertTrue(formatted.runs.contains {
            $0.inlinePresentationIntent?.contains(
                .stronglyEmphasized
            ) == true
        })
        XCTAssertTrue(formatted.runs.contains {
            $0.inlinePresentationIntent?.contains(.code) == true
        })
    }

    func testMarkdownInvalidoCaiNoTextoOriginal() {
        let source = "texto [sem destino]("

        XCTAssertEqual(
            String(
                MarkdownResponseFormatter
                    .attributedString(source).characters
            ),
            source
        )
    }
}
