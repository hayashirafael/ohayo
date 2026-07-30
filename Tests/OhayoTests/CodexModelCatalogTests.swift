import XCTest
@testable import Ohayo

final class CodexModelCatalogTests: XCTestCase {
    func testTrocaDeModeloNormalizaEffortIncompativelParaPadrao() {
        let models = [
            CodexModelOption(
                slug: "modelo-a",
                displayName: "Modelo A",
                description: "",
                supportedReasoning: [.low, .ultra],
                defaultReasoning: .low
            ),
            CodexModelOption(
                slug: "modelo-b",
                displayName: "Modelo B",
                description: "",
                supportedReasoning: [.medium, .high],
                defaultReasoning: .medium
            ),
        ]

        XCTAssertEqual(
            CodexModelCatalog.normalizedReasoning(
                .ultra,
                for: "modelo-b",
                in: models
            ),
            .medium
        )
        XCTAssertEqual(
            CodexModelCatalog.normalizedReasoning(
                .high,
                for: "modelo-b",
                in: models
            ),
            .high
        )
        XCTAssertEqual(
            CodexModelCatalog.normalizedReasoning(
                .ultra,
                for: "",
                in: models
            ),
            .ultra
        )
    }

    func testDecodificaSomenteModelosVisiveisComEffortsDaConta() throws {
        let data = """
        {
          "models": [
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6-Sol",
              "description": "Latest frontier agentic coding model.",
              "visibility": "list",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "low", "description": "Fast"},
                {"effort": "medium", "description": "Balanced"},
                {"effort": "ultra", "description": "Delegates"}
              ]
            },
            {
              "slug": "codex-auto-review",
              "display_name": "Auto review",
              "visibility": "hide",
              "default_reasoning_level": "medium",
              "supported_reasoning_levels": [
                {"effort": "medium", "description": "Balanced"}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let models = CodexModelCatalog.models(from: data)

        XCTAssertEqual(models, [
            CodexModelOption(
                slug: "gpt-5.6-sol",
                displayName: "GPT-5.6-Sol",
                description: "Latest frontier agentic coding model.",
                supportedReasoning: [.low, .medium, .ultra],
                defaultReasoning: .medium
            ),
        ])
    }

    func testCacheAusenteUsaFamiliaRecomendadaAtual() {
        XCTAssertEqual(
            CodexModelCatalog.models(from: Data("inválido".utf8)),
            CodexModelCatalog.fallbackModels
        )
        XCTAssertEqual(
            CodexModelCatalog.fallbackModels.map(\.slug),
            ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        )
        XCTAssertEqual(
            CodexModelCatalog.fallbackModels[0].supportedReasoning,
            [.low, .medium, .high, .xhigh, .max, .ultra]
        )
        XCTAssertEqual(
            CodexModelCatalog.fallbackModels[2].supportedReasoning,
            [.low, .medium, .high, .xhigh, .max]
        )
    }
}
