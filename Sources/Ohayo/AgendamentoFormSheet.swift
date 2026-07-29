import SwiftUI

/// Formulário único de agendamento: tipo (Claude/Codex/Comando), prompt com
/// personalização por tipo, e repetição (contínua ou horários fixos).
struct AgendamentoFormSheet: View {
    static let initialCommandText = ""

    enum OutputMode: Hashable {
        case none
        case terminal
        case response
    }

    static let initialOutputMode: OutputMode = .terminal

    static func outputMode(for message: Message) -> OutputMode {
        if message.kind != .shell && message.resolvedRunInTerminal { return .terminal }
        if message.resolvedShowResponse { return .response }
        return .none
    }

    static func showsTimeout(for outputMode: OutputMode) -> Bool {
        outputMode != .terminal
    }

    static func effectiveNotifyOnSuccess(
        _ requested: Bool,
        outputMode: OutputMode
    ) -> Bool {
        requested && outputMode != .terminal
    }

    static func canonicalAccountPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return ProviderAccountContext.canonicalAccountDirectory(
            URL(fileURLWithPath: path)
        ).path
    }

    /// Normaliza tanto a seleção restaurada quanto a lista atual. Assim uma
    /// task legada que persistiu um symlink continua mirando a mesma conta ao
    /// ser aberta e salva, em vez de cair silenciosamente no default.
    static func effectiveAccountPath(
        selection: String?,
        accounts: [URL]
    ) -> String? {
        guard let selected = canonicalAccountPath(selection) else {
            return nil
        }
        let available = Set(accounts.map {
            ProviderAccountContext.canonicalAccountDirectory($0).path
        })
        return available.contains(selected) ? selected : nil
    }

    @ObservedObject var state: AppState
    /// Agendamento em edição; nil = modo "adicionar".
    let editing: ScheduledTask?
    let onDone: () -> Void

    @State private var name = ""
    @State private var text = Self.initialCommandText
    @State private var kind: Message.Kind = .claude
    @State private var model: Message.Model = Message.defaultModel
    @State private var effort: Message.Effort = Message.defaultEffort
    @State private var safeMode = Message.defaultSafeMode
    @State private var codexModel = ""
    @State private var codexReasoning: Message.CodexReasoning? = nil
    @State private var outputMode: OutputMode = Self.initialOutputMode
    @State private var timeoutSeconds: Int?
    @State private var notifyOnSuccess = false
    @State private var account: String? = nil
    @State private var skill: String? = nil
    @State private var availableSkills: [SkillRef] = []
    @State private var skillRefreshGeneration: UInt = 0
    @State private var skillRefreshTask: Task<Void, Never>? = nil
    @State private var codexPluginInventories: [String: Data] = [:]
    @State private var workingDir = ""
    @State private var repetition: ScheduledTask.Repetition = .fixed
    @State private var times: [Int] = [9 * 60]
    @State private var weekdays: Set<Int> = Set(1...7)
    @State private var bootstrapWhenInactive = false
    @State private var enabled = true
    @State private var showingAdvancedOptions = false

    /// Todo o estado restaurável de um agendamento existente (ou os defaults
    /// de "novo agendamento"). Extraído como struct pura para o `init` poder
    /// semear os `@State` de uma vez só — ver comentário no `init` sobre por
    /// que isso é essencial para não disparar `onChange(of: kind)` à toa.
    struct RestoredState {
        var name = ""
        var text = AgendamentoFormSheet.initialCommandText
        var kind: Message.Kind = .claude
        var model = Message.defaultModel
        var effort = Message.defaultEffort
        var safeMode = Message.defaultSafeMode
        var codexModel = ""
        var codexReasoning: Message.CodexReasoning?
        var outputMode = AgendamentoFormSheet.initialOutputMode
        var timeoutSeconds: Int?
        var notifyOnSuccess = false
        var account: String?
        var skill: String?
        var workingDir = ""
        var repetition: ScheduledTask.Repetition = .fixed
        var times: [Int] = [9 * 60]
        var weekdays: Set<Int> = Set(1...7)
        var bootstrapWhenInactive = false
        var enabled = true
    }

    /// Resolve o estado inicial do formulário a partir da task em edição
    /// (nil = "adicionar", usa os defaults). Função pura, testável sem
    /// instanciar a view.
    static func restoredState(for task: ScheduledTask?) -> RestoredState {
        var restored = RestoredState()
        guard let t = task else { return restored }
        restored.name = t.name ?? ""
        restored.repetition = t.repetition
        restored.times = AgendaMath.normalized(t.times.isEmpty ? [9 * 60] : t.times)
        restored.weekdays = t.weekdays.isEmpty ? Set(1...7) : t.weekdays
        restored.bootstrapWhenInactive = t.resolvedBootstrapWhenInactive
        restored.enabled = t.enabled
        let msg = t.resolvedCommand
        restored.text = msg.text
        restored.kind = msg.kind
        restored.model = msg.resolvedModel
        restored.effort = msg.resolvedEffort
        restored.safeMode = msg.resolvedSafeMode
        restored.codexModel = msg.codexModel ?? ""
        restored.codexReasoning = msg.codexReasoning
        restored.outputMode = outputMode(for: msg)
        restored.timeoutSeconds = msg.timeoutSeconds
        restored.notifyOnSuccess = effectiveNotifyOnSuccess(
            msg.notifyOnSuccess ?? false,
            outputMode: restored.outputMode
        )
        restored.account = canonicalAccountPath(msg.configDir)
        restored.skill = msg.skill
        restored.workingDir = msg.workingDir ?? ""
        return restored
    }

    init(state: AppState, editing: ScheduledTask?, onDone: @escaping () -> Void) {
        self._state = ObservedObject(wrappedValue: state)
        self.editing = editing
        self.onDone = onDone
        // Semeia os @State diretamente a partir da task em edição (em vez de
        // nascer com os defaults e corrigir depois em `onAppear`/`load()`).
        // Isso é o que evita o bug crítico de perda de dado: se `kind`
        // nascesse `.claude` e só virasse `.codex` depois de montada a view,
        // o `.onChange(of: kind)` disparava na renderização seguinte — mesmo
        // sem o usuário ter trocado o tipo — e sua lógica de "troca de tipo"
        // zerava a `skill` da task carregada. Inicializando aqui, `kind` já
        // nasce `.codex` (quando for o caso) e o `onChange` nunca vê uma
        // transição: não há disparo espúrio para suprimir.
        let restored = Self.restoredState(for: editing)
        _name = State(initialValue: restored.name)
        _text = State(initialValue: restored.text)
        _kind = State(initialValue: restored.kind)
        _model = State(initialValue: restored.model)
        _effort = State(initialValue: restored.effort)
        _safeMode = State(initialValue: restored.safeMode)
        _codexModel = State(initialValue: restored.codexModel)
        _codexReasoning = State(initialValue: restored.codexReasoning)
        _outputMode = State(initialValue: restored.outputMode)
        _timeoutSeconds = State(initialValue: restored.timeoutSeconds)
        _notifyOnSuccess = State(initialValue: restored.notifyOnSuccess)
        _account = State(initialValue: restored.account)
        _skill = State(initialValue: restored.skill)
        _workingDir = State(initialValue: restored.workingDir)
        _repetition = State(initialValue: restored.repetition)
        _times = State(initialValue: restored.times)
        _weekdays = State(initialValue: restored.weekdays)
        _bootstrapWhenInactive = State(
            initialValue: restored.bootstrapWhenInactive
        )
        _enabled = State(initialValue: restored.enabled)
        _showingAdvancedOptions = State(
            initialValue: Self.hasAdvancedConfiguration(restored)
        )
    }

    private var strings: L10n { state.strings }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(editing == nil ? strings.newSchedule : strings.editSchedule)
                        .font(.title2.bold())

                    commandConfiguration

                    Divider()

                    scheduleConfiguration

                    Divider()

                    executionConfiguration
                    advancedConfiguration
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            actionBar
        }
        .frame(
            minWidth: 520,
            idealWidth: 560,
            maxWidth: 640,
            minHeight: 560,
            idealHeight: 680,
            maxHeight: 820
        )
        .onAppear {
            // O estado (kind/account/skill/…) já nasceu correto no `init`;
            // aqui só o efeito colateral de revarrer o disco é necessário.
            refreshSkills()
        }
        // Conta é por provider; trocar o Tipo sem limpar conta incompatível
        // persistiria um configDir do provider errado. Shell não mira conta e
        // não pode ser contínuo.
        .onChange(of: kind) { newKind in
            // A troca explícita de provider invalida o namespace da skill.
            // Trocar só de conta mantém a seleção e mostra aviso caso a
            // consulta autoritativa não a encontre.
            skill = nil
            defer { refreshSkills() }
            if newKind == .shell {
                account = nil
                if outputMode == .terminal { outputMode = .none }
                if repetition == .continuous { repetition = .fixed }
                return
            }
            guard let current = account else { return }
            let valid: Bool
            switch newKind {
            case .claude: valid = state.accounts(for: .claude).contains { $0.path == current }
            case .codex: valid = state.accounts(for: .codex).contains { $0.path == current }
            case .shell: valid = false
            }
            if !valid { account = nil }
        }
        .onChange(of: account) { _ in refreshSkills() }
        .onChange(of: outputMode) { newMode in
            if newMode == .terminal {
                notifyOnSuccess = false
            }
        }
        .onChange(of: workingDir) { _ in
            // Plugins pertencem à conta, não ao cwd. Recalcula apenas os
            // scopes do projeto e reaproveita o inventário já carregado,
            // sem iniciar um subprocesso a cada caractere digitado.
            refreshSkills(reloadCodexPlugins: false)
        }
        .onChange(of: skill) { newSkill in
            // Skill exige safe-mode desligado; limpar a skill não religa
            // sozinho (o usuário reabilita o toggle se quiser).
            if newSkill?.isEmpty == false { safeMode = false }
        }
        .onDisappear {
            // A consulta do CLI pode terminar depois de o sheet fechar.
            // Invalida a geração para uma resposta tardia não alterar state.
            skillRefreshGeneration &+= 1
            skillRefreshTask?.cancel()
            skillRefreshTask = nil
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var commandConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(strings.messageSection)
            KindSelector(kind: $kind, strings: strings)
            TextField(strings.nameOptional, text: $name)
            accountConfiguration
            commandEditor
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(strings.saveNeedsMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
            if text.isEmpty {
                Text(strings.messageOrCommand)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 96, idealHeight: 116)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator, lineWidth: 1)
        }
        .accessibilityLabel(strings.messageOrCommand)
    }

    @ViewBuilder
    private var accountConfiguration: some View {
        if kind != .shell {
            Grid(alignment: .leading, horizontalSpacing: 10) {
                GridRow {
                    ConfigRowLabel(strings.account)
                    Picker("", selection: $account) {
                        if kind == .claude {
                            Text(strings.globalDefault).tag(String?.none)
                            ForEach(state.accounts(for: .claude), id: \.self) { dir in
                                Text(state.label(for: dir)).tag(String?.some(dir.path))
                            }
                        } else {
                            Text(strings.codexDefault).tag(String?.none)
                            ForEach(state.accounts(for: .codex), id: \.self) { dir in
                                Text(state.label(for: dir)).tag(String?.some(dir.path))
                            }
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(strings.account)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var providerConfiguration: some View {
        if kind == .claude {
            ClaudeConfigForm(model: $model, effort: $effort, safeMode: $safeMode,
                             configDir: $account, skill: $skill,
                             availableSkills: availableSkills,
                             workingDir: $workingDir,
                             accounts: state.accounts(for: .claude),
                             accountLabel: { state.label(for: $0) },
                             strings: strings,
                             showsAccount: false)
        } else if kind == .codex {
            CodexConfigForm(model: $codexModel, reasoning: $codexReasoning,
                            configDir: $account, skill: $skill,
                            availableSkills: availableSkills,
                            workingDir: $workingDir,
                            accounts: state.accounts(for: .codex),
                            accountLabel: { state.label(for: $0) },
                            strings: strings,
                            showsAccount: false)
        }
    }

    private var advancedConfiguration: some View {
        DisclosureGroup(
            strings.advancedOptions,
            isExpanded: $showingAdvancedOptions
        ) {
            VStack(alignment: .leading, spacing: 10) {
                providerConfiguration
                if Self.showsTimeout(for: outputMode) {
                    TimeoutPicker(
                        timeoutSeconds: $timeoutSeconds,
                        kind: kind,
                        strings: strings
                    )
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private var executionConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(strings.executionMode, selection: $outputMode) {
                Text(strings.runInBackground).tag(OutputMode.none)
                if kind != .shell {
                    Text(strings.runInTerminal).tag(OutputMode.terminal)
                }
                Text(strings.showResponse).tag(OutputMode.response)
            }
            .pickerStyle(.radioGroup)

            Text(outputModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Independente do modo de execução acima: notifica só em sucesso;
            // ao salvar a resposta, a notificação de resposta vence.
            Toggle(strings.notifyOnSuccess, isOn: $notifyOnSuccess)
                .toggleStyle(.checkbox)
                .disabled(outputMode == .terminal)
                .help(
                    outputMode == .terminal
                        ? strings.notifyOnSuccessUnavailableInTerminal
                        : ""
                )
            if outputMode == .terminal {
                Text(strings.notifyOnSuccessUnavailableInTerminal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var outputModeDescription: String {
        switch outputMode {
        case .none: return strings.runInBackgroundDescription
        case .terminal: return strings.runInTerminalDescription
        case .response: return strings.showResponseDescription
        }
    }

    private var scheduleConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(strings.scheduleSection)
            repetitionPicker
            scheduleDetails
        }
    }

    @ViewBuilder
    private var scheduleDetails: some View {
        if repetition == .fixed {
            TimeChipsEditor(times: $times, strings: strings)
            weekdaysEditor
            dayPresetsRow
            if overlapWarning {
                Label(strings.overlappingWindows, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let preview = nextFirePreview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if weekdays.isEmpty {
                Label(strings.saveNeedsDay, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else {
            Text(strings.fixedContinuousDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                strings.bootstrapWhenInactive,
                isOn: $bootstrapWhenInactive
            )
            .toggleStyle(.checkbox)
            Text(strings.bootstrapWhenInactiveHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            if continuousConflict {
                Label(strings.continuousConflict,
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Toggle(strings.enabled, isOn: $enabled)
                .toggleStyle(.checkbox)
            Spacer()
            Button(strings.cancel) { onDone() }
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? strings.add : strings.save) { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .help(saveDisabledReason ?? "")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var repetitionPicker: some View {
        Picker(strings.repetition, selection: $repetition) {
            Text(strings.fixedTimes).tag(ScheduledTask.Repetition.fixed)
            if kind != .shell {
                Text(strings.continuousWindow).tag(ScheduledTask.Repetition.continuous)
            }
        }
        .pickerStyle(.segmented)
    }

    private var weekdaysEditor: some View {
        HStack(spacing: 4) {
            Text(strings.days).font(.caption)
            ForEach(1...7, id: \.self) { day in
                Toggle(strings.dayLetters[day - 1], isOn: dayBinding(day))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    // As letras únicas (D S T Q Q S S) são ambíguas: o nome
                    // completo desambigua no hover e para leitores de tela.
                    .help(strings.dayName(day))
                    .accessibilityLabel(strings.dayName(day))
            }
        }
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { weekdays.contains(day) },
            set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } })
    }

    /// Atalhos com o mesmo vocabulário do resumo de dias da lista.
    private var dayPresetsRow: some View {
        HStack(spacing: 12) {
            dayPresetButton(Set(1...7))
            dayPresetButton([2, 3, 4, 5, 6])
            dayPresetButton([1, 7])
        }
        .font(.caption)
    }

    private func dayPresetButton(_ preset: Set<Int>) -> some View {
        Button(strings.daysSummary(preset)) { weekdays = preset }
            .buttonStyle(.link)
            .disabled(weekdays == preset)
    }

    private var continuousConflict: Bool {
        state.hasContinuousConflict(draftTask())
    }

    /// Aviso não bloqueante: dois horários dentro da mesma janela de 5h.
    /// Só para Claude/Codex — shell não abre janela.
    private var overlapWarning: Bool {
        guard kind != .shell, repetition == .fixed,
              let gap = AgendaMath.minCircularGap(times) else { return false }
        return gap < 300
    }

    private var nextFirePreview: String? {
        guard repetition == .fixed,
              let next = AgendaMath.nextOccurrence(times: times, weekdays: weekdays,
                                                   after: Date(), calendar: .current)
        else { return nil }
        return strings.nextAt(Fmt.weekdayTime(next, language: state.language))
    }

    private var isValid: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch repetition {
        case .fixed: return !times.isEmpty && !weekdays.isEmpty
        case .continuous: return kind != .shell && !continuousConflict
        }
    }

    /// Motivo de o Salvar estar desabilitado (tooltip); nil quando válido.
    private var saveDisabledReason: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return strings.saveNeedsMessage
        }
        switch repetition {
        case .fixed:
            if times.isEmpty { return strings.saveNeedsTime }
            if weekdays.isEmpty { return strings.saveNeedsDay }
        case .continuous:
            if continuousConflict { return strings.continuousConflict }
        }
        return nil
    }

    /// Recalcula as skills da conta alvo (abrir o sheet / trocar conta /
    /// trocar tipo). Conta nil = default global do provider — o mesmo
    /// diretório que o dispatch resolveria.
    private func refreshSkills(reloadCodexPlugins: Bool = true) {
        if reloadCodexPlugins {
            skillRefreshGeneration &+= 1
            skillRefreshTask?.cancel()
            skillRefreshTask = nil
        }
        let generation = skillRefreshGeneration

        guard kind != .shell else {
            availableSkills = []
            return
        }
        let provider: Provider = kind == .codex ? .codex : .claude
        let dir = account.map { URL(fileURLWithPath: $0) }
            ?? (provider == .codex ? AppState.defaultCodexConfigDir : AppState.defaultConfigDir)
        let inventoryKey =
            ProviderAccountContext.canonicalAccountDirectory(dir).path
        let cachedInventory = provider == .codex
            ? codexPluginInventories[inventoryKey]
            : nil

        var localSkills = SkillCatalog.skills(
            for: provider,
            at: dir,
            workingDir: selectedWorkingDirectoryURL,
            codexPluginInventory: cachedInventory)
        // Enquanto o inventário de plugins carrega (ou se o CLI estiver
        // indisponível), preserve uma seleção Codex já persistida. Só uma
        // resposta válida pode classificá-la como ausente.
        if provider == .codex,
           cachedInventory == nil,
           let skill,
           !skill.isEmpty,
           !localSkills.contains(where: { $0.name == skill }) {
            localSkills.append(SkillRef(name: skill))
            localSkills.sort { $0.name < $1.name }
        }
        availableSkills = localSkills

        guard provider == .codex,
              reloadCodexPlugins else {
            return
        }
        skillRefreshTask = Task { @MainActor in
            let inventory = await CodexPluginInventoryLoader.load(
                configDirectory: dir
            )
            guard !Task.isCancelled,
                  generation == skillRefreshGeneration else {
                return
            }
            skillRefreshTask = nil
            guard let inventory else { return }
            codexPluginInventories[inventoryKey] = inventory
            availableSkills = SkillCatalog.skills(
                for: provider,
                at: dir,
                workingDir: selectedWorkingDirectoryURL,
                codexPluginInventory: inventory
            )
        }
    }

    private var selectedWorkingDirectoryURL: URL? {
        let trimmed = workingDir.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        return URL(
            fileURLWithPath:
                NSString(string: trimmed).expandingTildeInPath
        )
    }

    static func hasAdvancedConfiguration(_ restored: RestoredState) -> Bool {
        restored.model != Message.defaultModel
            || restored.effort != Message.defaultEffort
            || restored.safeMode != Message.defaultSafeMode
            || !restored.codexModel.isEmpty
            || restored.codexReasoning != nil
            || restored.timeoutSeconds != nil
            || restored.skill?.isEmpty == false
            || !restored.workingDir.isEmpty
    }

    /// Monta o agendamento normalizando defaults para nil.
    private func draftTask() -> ScheduledTask {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAccount: String?
        switch kind {
        case .claude:
            effectiveAccount = Self.effectiveAccountPath(
                selection: account,
                accounts: state.accounts(for: .claude)
            )
        case .codex:
            effectiveAccount = Self.effectiveAccountPath(
                selection: account,
                accounts: state.accounts(for: .codex)
            )
        case .shell:
            effectiveAccount = nil
        }
        let command = Message(
            text: t, kind: kind,
            model: kind == .claude && model != Message.defaultModel ? model : nil,
            effort: kind == .claude && effort != Message.defaultEffort ? effort : nil,
            safeMode: kind == .claude && safeMode != Message.defaultSafeMode ? safeMode : nil,
            configDir: kind != .shell ? effectiveAccount : nil,
            workingDir: kind != .shell && !workingDir.isEmpty ? workingDir : nil,
            showResponse: outputMode == .response ? true : nil,
            runInTerminal: kind != .shell && outputMode != .terminal ? false : nil,
            timeoutSeconds: Message.normalizedTimeoutSeconds(
                timeoutSeconds,
                for: kind
            ),
            notifyOnSuccess: Self.effectiveNotifyOnSuccess(
                notifyOnSuccess,
                outputMode: outputMode
            ) ? true : nil,
            codexModel: kind == .codex && !codexModel.trimmingCharacters(in: .whitespaces).isEmpty
                ? codexModel.trimmingCharacters(in: .whitespaces) : nil,
            codexReasoning: kind == .codex ? codexReasoning : nil,
            skill: kind != .shell && skill?.isEmpty == false ? skill : nil)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var task = ScheduledTask(uid: editing?.uid ?? UUID(),
                                 name: trimmedName.isEmpty ? nil : trimmedName,
                                 command: command,
                                 repetition: repetition,
                                 times: repetition == .fixed ? times : [],
                                 weekdays: repetition == .fixed ? weekdays : [],
                                 bootstrapWhenInactive: repetition == .continuous
                                     ? bootstrapWhenInactive
                                     : nil)
        task.enabled = enabled
        return task
    }

    private func commit() {
        let task = draftTask()
        if let editing, let idx = state.tasks.firstIndex(where: { $0.uid == editing.uid }) {
            state.tasks[idx] = task
        } else {
            state.tasks.append(task)
        }
        onDone()
    }
}

/// Seletor segmentado desenhado à mão: o `Picker(.segmented)` do macOS descarta
/// a imagem custom do `Label` (só o texto sobrevive), então os segmentos são
/// botões próprios para exibir o `ProviderIcon` de cada tipo.
struct KindSelector: View {
    @Binding var kind: Message.Kind
    let strings: L10n

    var body: some View {
        HStack(spacing: 2) {
            segment(.claude, title: "Claude", provider: .claude)
            segment(.codex, title: "Codex", provider: .codex)
            segment(.shell, title: strings.command, provider: nil)
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }

    private func segment(_ value: Message.Kind, title: String, provider: Provider?) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { kind = value }
        } label: {
            HStack(spacing: 5) {
                ProviderIcon(provider: provider, size: 12)
                Text(title)
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(kind == value ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .accessibilityLabel(title)
        .accessibilityValue(kind == value ? strings.enabled : "")
        .accessibilityAddTraits(kind == value ? .isSelected : [])
        .background {
            if kind == value {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
        }
    }
}
