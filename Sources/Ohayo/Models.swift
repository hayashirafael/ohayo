import Foundation

enum ResponseFileFormat: String, Codable, CaseIterable {
    case markdown
    case plainText

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }
}

enum CodexAccessMode: Hashable, CaseIterable {
    case fullAccess
    case workspaceWrite
    case readOnly

    var persistedFullAccess: Bool? {
        self == .fullAccess ? nil : false
    }

    var persistedTrustWorkingDirectory: Bool? {
        switch self {
        case .fullAccess: return nil
        case .workspaceWrite: return true
        case .readOnly: return false
        }
    }
}

enum FireResult: Codable, Equatable {
    case success
    /// A sessão interativa foi aberta no Terminal; o Ohayo não acompanha o
    /// processo até a conclusão e, portanto, não afirma sucesso.
    case launched
    case skipped(activeUntil: Date)
    case failure(message: String)
    case missed(occurrence: Date)
}

enum FireOrigin: String, Codable { case scheduled, manual, renewal, agenda }

struct FireEvent: Codable, Equatable {
    let date: Date
    let result: FireResult
    var messageText: String? = nil
    var account: String? = nil
    var origin: FireOrigin? = nil
    var response: String? = nil
    var accountPath: String? = nil
    var provider: Provider? = nil
    var modelName: String? = nil
    var aliasSnapshot: String? = nil
    var emailSnapshot: String? = nil
    var responseFileFormat: ResponseFileFormat? = nil
    var responseFilePath: String? = nil
    var responseFileError: String? = nil
}

struct EventIdentity: Equatable {
    let accountName: String?
    let alias: String?
    let email: String?
    let provider: Provider?
    let modelName: String?

    var displayName: String? { alias ?? email ?? accountName }
}

struct Message: Codable, Identifiable {
    enum Kind: String, Codable { case claude, shell, codex }
    enum CodexReasoning: String, Codable, CaseIterable {
        /// `minimal` é mantido para decodificar agendamentos criados por
        /// versões anteriores. O catálogo atual da conta decide se ele aparece.
        case none, minimal, low, medium, high, xhigh, max, ultra
    }
    enum Model: String, Codable, CaseIterable {
        case haiku, sonnet, opus
        var cliValue: String {
            switch self {
            case .haiku: return "claude-haiku-4-5"
            case .sonnet: return "claude-sonnet-5"
            case .opus: return "claude-opus-4-8"
            }
        }
        var label: String {
            switch self {
            case .haiku: return "Haiku 4.5"
            case .sonnet: return "Sonnet 5"
            case .opus: return "Opus 4.8"
            }
        }
    }
    enum Effort: String, Codable, CaseIterable { case low, medium, high, xhigh, max }

    var text: String
    var kind: Kind
    var model: Model? = nil
    var effort: Effort? = nil
    var safeMode: Bool? = nil
    var configDir: String? = nil
    var workingDir: String? = nil
    /// Consentimento para o Ohayo pré-autorizar o trust básico do projeto.
    /// `nil` preserva o comportamento dos agendamentos anteriores, nos quais
    /// escolher a pasta já representava esse consentimento; `false` revoga.
    var trustWorkingDirectory: Bool? = nil
    var uid: UUID? = nil
    var showResponse: Bool? = nil
    var runInTerminal: Bool? = nil
    /// Limite do processo batch, em segundos. nil usa o default seguro do
    /// tipo de comando; Terminal interativo ignora este valor.
    var timeoutSeconds: Int? = nil
    var notifyOnSuccess: Bool? = nil
    var codexModel: String? = nil
    var codexReasoning: CodexReasoning? = nil
    /// Compatibilidade persistida do acesso Codex: `nil` mantém acesso total;
    /// `false` combina com o trust da pasta para representar escrita restrita
    /// ou somente leitura. A UI usa `CodexAccessMode`.
    var codexAllowFullAccess: Bool? = nil
    var responseFileFormat: ResponseFileFormat? = nil
    var responseDirectory: String? = nil
    /// Skill da conta prefixada ao prompt no disparo (`/skill` no Claude,
    /// `$skill` no Codex). nil/vazia = sem skill. Só Claude/Codex.
    var skill: String? = nil

    var id: String { uid?.uuidString ?? contentKey }

    private var contentKey: String {
        let modelValue = model?.rawValue ?? ""
        let effortValue = effort?.rawValue ?? ""
        let safeModeValue = safeMode.map(String.init) ?? ""
        let showResponseValue = showResponse.map(String.init) ?? ""
        let runInTerminalValue = runInTerminal.map(String.init) ?? ""
        let trustWorkingDirectoryValue =
            trustWorkingDirectory.map(String.init) ?? ""
        let timeoutValue = timeoutSeconds.map(String.init) ?? ""
        let notifyOnSuccessValue = notifyOnSuccess.map(String.init) ?? ""
        let reasoningValue = codexReasoning?.rawValue ?? ""
        let fullAccessValue = codexAllowFullAccess.map(String.init) ?? ""
        let responseFormatValue = responseFileFormat?.rawValue ?? ""
        let values = [
            kind.rawValue, text, modelValue, effortValue, safeModeValue,
            configDir ?? "", workingDir ?? "", showResponseValue,
            runInTerminalValue, trustWorkingDirectoryValue, timeoutValue,
            notifyOnSuccessValue,
            codexModel ?? "", reasoningValue, fullAccessValue,
            responseFormatValue, responseDirectory ?? "", skill ?? ""
        ]
        return values.joined(separator: "\u{1}")
    }
}

extension Message: Equatable {
    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.text == rhs.text && lhs.kind == rhs.kind && lhs.model == rhs.model
            && lhs.effort == rhs.effort && lhs.safeMode == rhs.safeMode
            && lhs.configDir == rhs.configDir && lhs.workingDir == rhs.workingDir
            && lhs.trustWorkingDirectory == rhs.trustWorkingDirectory
            && lhs.showResponse == rhs.showResponse
            && lhs.runInTerminal == rhs.runInTerminal
            && lhs.timeoutSeconds == rhs.timeoutSeconds
            && lhs.notifyOnSuccess == rhs.notifyOnSuccess
            && lhs.codexModel == rhs.codexModel && lhs.codexReasoning == rhs.codexReasoning
            && lhs.codexAllowFullAccess == rhs.codexAllowFullAccess
            && lhs.responseFileFormat == rhs.responseFileFormat
            && lhs.responseDirectory == rhs.responseDirectory
            && lhs.skill == rhs.skill
    }
}

extension Message {
    static let defaultModel: Model = .haiku
    static let defaultEffort: Effort = .low
    static let defaultSafeMode = true
    var resolvedModel: Model { model ?? Self.defaultModel }
    var resolvedEffort: Effort { effort ?? Self.defaultEffort }
    /// Skill efetiva: nil e string vazia contam como "sem skill".
    var hasSkill: Bool { skill?.isEmpty == false && kind != .shell }
    var resolvedSafeMode: Bool {
        // Skill exige safe-mode desligado: `--safe-mode` faz o CLI pular
        // skills — um estado contraditório persistido não pode gerar disparo
        // que ignora a skill em silêncio.
        hasSkill ? false : (safeMode ?? Self.defaultSafeMode)
    }
    /// Prompt final enviado ao CLI: skill prefixada na sintaxe nativa do
    /// provider (`/skill` no Claude, `$skill` no Codex); shell ignora skill.
    var resolvedPromptText: String {
        guard hasSkill, let skill else { return text }
        return kind == .codex ? "$\(skill) \(text)" : "/\(skill) \(text)"
    }
    var resolvedShowResponse: Bool { showResponse ?? false }
    var resolvedNotifyOnSuccess: Bool { notifyOnSuccess ?? false }
    var resolvedCodexAccessMode: CodexAccessMode {
        if codexAllowFullAccess == false {
            return trustWorkingDirectory == true
                ? .workspaceWrite
                : .readOnly
        }
        return trustWorkingDirectory == false ? .readOnly : .fullAccess
    }
    var resolvedCodexAllowFullAccess: Bool {
        resolvedCodexAccessMode == .fullAccess
    }
    var resolvedResponseFileFormat: ResponseFileFormat {
        responseFileFormat ?? .markdown
    }
    var resolvedRunInTerminal: Bool {
        switch kind {
        case .claude, .codex: return runInTerminal ?? true
        case .shell: return false
        }
    }
    /// O workspace interno pertence ao Ohayo. Em pasta explícita, `false`
    /// revoga a autorização antecipada. Para Codex, o modo somente leitura
    /// também mantém o trust desativado mesmo no workspace interno.
    var resolvedTrustWorkingDirectory: Bool {
        guard kind != .shell else { return false }
        if kind == .codex, resolvedCodexAccessMode == .readOnly {
            return false
        }
        let hasExplicitDirectory =
            workingDir?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        return !hasExplicitDirectory || trustWorkingDirectory ?? true
    }
    /// Terminal interativo não tem processo filho monitorado pelo Ohayo, então
    /// não existe timeout aplicável nesse modo.
    var resolvedTimeoutSeconds: Int? {
        guard !resolvedRunInTerminal else { return nil }
        guard let timeoutSeconds, timeoutSeconds > 0 else { return nil }
        return timeoutSeconds
    }
}

struct ScheduledTask: Identifiable, Equatable {
    enum Repetition: String, Codable { case continuous, fixed }

    var uid: UUID
    var name: String? = nil
    var command: Message? = nil
    var repetition: Repetition = .fixed
    var times: [Int] = []
    var weekdays: Set<Int> = []
    /// `nil` identifica agendamentos anteriores ao auto-início explícito.
    /// Contínuos legados passam a iniciar a primeira janela automaticamente;
    /// um `false` persistido continua sendo a revogação explícita.
    var bootstrapWhenInactive: Bool? = nil
    var enabled: Bool = true

    var id: UUID { uid }
    var resolvedCommand: Message { command ?? AppState.defaultMessage }
    var resolvedBootstrapWhenInactive: Bool {
        bootstrapWhenInactive ?? (repetition == .continuous)
    }

    /// Identidade do payload executável usada para invalidar outcomes que
    /// voltam depois de a pessoa editar uma tarefa em andamento. Nome e
    /// horários, enabled e consentimento de bootstrap não alteram o comando
    /// já entregue; conta/modelo/prompt/modo sim.
    var renewalRevision: String {
        let message = resolvedCommand
        var values: [String] = []
        values.append(uid.uuidString)
        values.append(message.kind.rawValue)
        values.append(message.text)
        values.append(message.model?.rawValue ?? "")
        values.append(message.effort?.rawValue ?? "")
        values.append(message.safeMode.map(String.init) ?? "")
        values.append(message.configDir ?? "")
        values.append(message.workingDir ?? "")
        values.append(message.trustWorkingDirectory.map(String.init) ?? "")
        values.append(message.showResponse.map(String.init) ?? "")
        values.append(message.runInTerminal.map(String.init) ?? "")
        values.append(message.timeoutSeconds.map(String.init) ?? "")
        values.append(message.notifyOnSuccess.map(String.init) ?? "")
        values.append(message.codexModel ?? "")
        values.append(message.codexReasoning?.rawValue ?? "")
        values.append(message.codexAllowFullAccess.map(String.init) ?? "")
        values.append(message.responseFileFormat?.rawValue ?? "")
        values.append(message.responseDirectory ?? "")
        values.append(message.skill ?? "")
        return values.joined(separator: "\u{1}")
    }
}

/// Decodificação lossy de arrays: um elemento ilegível vira `nil` em vez de
/// derrubar o array inteiro. Protege o blob persistido de `tasks`/`history`
/// contra um único item com raw value desconhecido (downgrade para uma build
/// mais antiga) que apagaria toda a lista.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension ScheduledTask: Codable {
    private enum CodingKeys: String, CodingKey {
        case uid, name, command, repetition, times, weekdays
        case bootstrapWhenInactive, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(UUID.self, forKey: .uid)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        command = try c.decodeIfPresent(Message.self, forKey: .command)
        repetition = try c.decodeIfPresent(Repetition.self, forKey: .repetition) ?? .fixed
        times = try c.decodeIfPresent([Int].self, forKey: .times) ?? []
        let persistedWeekdays = try c.decodeIfPresent(
            Set<Int>.self,
            forKey: .weekdays
        ) ?? []
        weekdays = persistedWeekdays.filter { (1...7).contains($0) }
        bootstrapWhenInactive = try c.decodeIfPresent(
            Bool.self,
            forKey: .bootstrapWhenInactive
        )
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
