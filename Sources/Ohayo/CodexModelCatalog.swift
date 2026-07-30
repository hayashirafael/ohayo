import Foundation

struct CodexModelOption: Equatable, Identifiable {
    let slug: String
    let displayName: String
    let description: String
    let supportedReasoning: [Message.CodexReasoning]
    let defaultReasoning: Message.CodexReasoning?

    var id: String { slug }
}

struct CodexModelSelection: Equatable {
    let modelSlug: String
    let reasoning: Message.CodexReasoning?
}

enum CodexModelCatalog {
    /// Fallback publicado pelo produto Codex. O cache de cada conta continua
    /// sendo a fonte preferida porque disponibilidade e efforts podem variar.
    static var fallbackModels: [CodexModelOption] {
        localizedFallbackModels(strings: L10n(language: .english))
    }

    static func load(
        from configDirectory: URL,
        strings: L10n = L10n(language: .english)
    ) -> [CodexModelOption] {
        let cache = configDirectory.appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: cache) else {
            return localizedFallbackModels(strings: strings)
        }
        return models(from: data, strings: strings)
    }

    static func models(
        from data: Data,
        strings: L10n = L10n(language: .english)
    ) -> [CodexModelOption] {
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return localizedFallbackModels(strings: strings)
        }
        let visible = cache.models.compactMap { model -> CodexModelOption? in
            guard model.visibility == "list",
                  !model.slug.isEmpty else {
                return nil
            }
            return CodexModelOption(
                slug: model.slug,
                displayName: model.displayName?.isEmpty == false
                    ? model.displayName! : model.slug,
                description: model.description ?? "",
                supportedReasoning: model.supportedReasoningLevels.compactMap {
                    Message.CodexReasoning(rawValue: $0.effort)
                },
                defaultReasoning: model.defaultReasoningLevel.flatMap(
                    Message.CodexReasoning.init(rawValue:)
                )
            )
        }
        return visible.isEmpty
            ? localizedFallbackModels(strings: strings)
            : visible
    }

    static func normalizedReasoning(
        _ reasoning: Message.CodexReasoning?,
        for modelSlug: String,
        in models: [CodexModelOption]
    ) -> Message.CodexReasoning? {
        guard let reasoning,
              !modelSlug.isEmpty,
              let model = models.first(where: { $0.slug == modelSlug }),
              !model.supportedReasoning.contains(reasoning) else {
            return reasoning
        }
        guard let defaultReasoning = model.defaultReasoning,
              model.supportedReasoning.contains(defaultReasoning) else {
            return nil
        }
        return defaultReasoning
    }

    static func normalizedSelection(
        modelSlug: String,
        reasoning: Message.CodexReasoning?,
        in models: [CodexModelOption],
        preservesUnknownModel: Bool
    ) -> CodexModelSelection {
        let hasKnownModel = modelSlug.isEmpty
            || models.contains(where: { $0.slug == modelSlug })
        guard hasKnownModel else {
            return preservesUnknownModel
                ? CodexModelSelection(
                    modelSlug: modelSlug,
                    reasoning: reasoning
                )
                : CodexModelSelection(modelSlug: "", reasoning: nil)
        }
        return CodexModelSelection(
            modelSlug: modelSlug,
            reasoning: normalizedReasoning(
                reasoning,
                for: modelSlug,
                in: models
            )
        )
    }

    private static func localizedFallbackModels(
        strings: L10n
    ) -> [CodexModelOption] {
        [
            CodexModelOption(
                slug: "gpt-5.6-sol",
                displayName: "GPT-5.6 Sol",
                description: strings.codexFallbackModelDescription("gpt-5.6-sol"),
                supportedReasoning: [.low, .medium, .high, .xhigh, .max, .ultra],
                defaultReasoning: .medium
            ),
            CodexModelOption(
                slug: "gpt-5.6-terra",
                displayName: "GPT-5.6 Terra",
                description: strings.codexFallbackModelDescription("gpt-5.6-terra"),
                supportedReasoning: [.low, .medium, .high, .xhigh, .max, .ultra],
                defaultReasoning: .medium
            ),
            CodexModelOption(
                slug: "gpt-5.6-luna",
                displayName: "GPT-5.6 Luna",
                description: strings.codexFallbackModelDescription("gpt-5.6-luna"),
                supportedReasoning: [.low, .medium, .high, .xhigh, .max],
                defaultReasoning: .medium
            ),
        ]
    }

    private struct Cache: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {
        let slug: String
        let displayName: String?
        let description: String?
        let visibility: String?
        let defaultReasoningLevel: String?
        let supportedReasoningLevels: [ReasoningLevel]

        private enum CodingKeys: String, CodingKey {
            case slug, description, visibility
            case displayName = "display_name"
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
        }
    }

    private struct ReasoningLevel: Decodable {
        let effort: String
    }
}
