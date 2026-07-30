import XCTest
@testable import Ohayo

final class ResponseFileWriterTests: XCTestCase {
    func testSalvaMarkdownComNomeLegivelEConteudoIntegral() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-response-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SystemResponseFileWriter()
        let response = "# Resultado\n\n- item"

        let file = try await writer.write(
            response: response,
            format: .markdown,
            directory: directory,
            taskName: "Revisão final",
            fallbackName: "resposta",
            date: Date(timeIntervalSince1970: 0)
        ).get()

        XCTAssertEqual(file.pathExtension, "md")
        XCTAssertTrue(file.lastPathComponent.contains("revisao-final"))
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            response
        )
    }

    func testTxtUsaExtensaoCorretaENaoSobrescreveOutroDisparo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-response-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SystemResponseFileWriter()
        let date = Date(timeIntervalSince1970: 0)

        let first = try await writer.write(
            response: "primeira",
            format: .plainText,
            directory: directory,
            taskName: nil,
            fallbackName: "resposta",
            date: date
        ).get()
        let second = try await writer.write(
            response: "segunda",
            format: .plainText,
            directory: directory,
            taskName: nil,
            fallbackName: "resposta",
            date: date
        ).get()

        XCTAssertEqual(first.pathExtension, "txt")
        XCTAssertTrue(first.lastPathComponent.contains("resposta"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            try String(contentsOf: first, encoding: .utf8),
            "primeira"
        )
        XCTAssertEqual(
            try String(contentsOf: second, encoding: .utf8),
            "segunda"
        )
    }
}
