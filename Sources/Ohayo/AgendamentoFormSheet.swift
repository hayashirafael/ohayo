import SwiftUI

/// Formulário único de agendamento: tipo (Claude/Codex/Comando), prompt com
/// personalização por tipo, e repetição (contínua ou horários fixos).
struct AgendamentoFormSheet: View {
    typealias OutputMode = AgendamentoOutputMode

    @ObservedObject var state: AppState
    /// Agendamento em edição; nil = modo "adicionar".
    let editing: ScheduledTask?
    let onDone: () -> Void

    @State private var draft: AgendamentoDraft
    @State private var availableSkills: [SkillRef] = []
    @State private var skillRefreshGeneration: UInt = 0
    @State private var skillRefreshTask: Task<Void, Never>? = nil
    @State private var codexPluginInventories =
        CodexPluginInventoryCache()
    @State private var commitErrorMessage: String?
    @State private var showingAdvancedOptions: Bool

    init(state: AppState, editing: ScheduledTask?, onDone: @escaping () -> Void) {
        self._state = ObservedObject(wrappedValue: state)
        self.editing = editing
        self.onDone = onDone
        let restored = AgendamentoDraft(editing: editing)
        _draft = State(initialValue: restored)
        _showingAdvancedOptions = State(
            initialValue: Self.hasAdvancedConfiguration(restored)
        )
    }

    private var strings: L10n { state.strings }
    private var editor: AgendamentoEditor {
        AgendamentoEditor(state: state)
    }

    var body: some View {
        let snapshot = editor.formSnapshot(for: draft)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(editing == nil ? strings.newSchedule : strings.editSchedule)
                        .font(.title2.bold())

                    commandConfiguration(snapshot: snapshot)

                    Divider()

                    scheduleConfiguration(snapshot: snapshot)

                    Divider()

                    executionConfiguration
                    advancedConfiguration
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            actionBar(snapshot: snapshot)
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
        .onChange(of: draft.account) { _ in refreshSkills() }
        .onChange(of: draft.workingDir) { _ in
            // Plugins pertencem à conta, não ao cwd. Recalcula apenas os
            // scopes do projeto e reaproveita o inventário já carregado,
            // sem iniciar um subprocesso a cada caractere digitado.
            refreshSkills(reloadCodexPlugins: false)
        }
        .onDisappear {
            // A consulta do CLI pode terminar depois de o sheet fechar.
            // Invalida a geração para uma resposta tardia não alterar state.
            skillRefreshGeneration &+= 1
            skillRefreshTask?.cancel()
            skillRefreshTask = nil
        }
        .alert(
            strings.save,
            isPresented: Binding(
                get: { commitErrorMessage != nil },
                set: { if !$0 { commitErrorMessage = nil } }
            )
        ) {
            Button(strings.ok) { commitErrorMessage = nil }
        } message: {
            Text(commitErrorMessage ?? "")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func commandConfiguration(
        snapshot: AgendamentoFormSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(strings.messageSection)
            KindSelector(kind: kindBinding, strings: strings)
            TextField(strings.nameOptional, text: $draft.name)
            accountConfiguration
            commandEditor
            if snapshot.firstIssue == .emptyMessage {
                Label(strings.saveNeedsMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if snapshot.hasAccountUnavailableIssue {
                Label(
                    strings.accountFolderMissing,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var commandEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
            if draft.text.isEmpty {
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
        if draft.kind != .shell {
            Grid(alignment: .leading, horizontalSpacing: 10) {
                GridRow {
                    ConfigRowLabel(strings.account)
                    Picker("", selection: $draft.account) {
                        if draft.kind == .claude {
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
        if draft.kind == .claude {
            ClaudeConfigForm(model: $draft.model,
                             effort: $draft.effort,
                             safeMode: $draft.safeMode,
                             configDir: $draft.account,
                             skill: skillBinding,
                             availableSkills: availableSkills,
                             workingDir: $draft.workingDir,
                             accounts: state.accounts(for: .claude),
                             accountLabel: { state.label(for: $0) },
                             strings: strings,
                             showsAccount: false)
        } else if draft.kind == .codex {
            CodexConfigForm(model: $draft.codexModel,
                            reasoning: $draft.codexReasoning,
                            configDir: $draft.account,
                            skill: skillBinding,
                            availableSkills: availableSkills,
                            workingDir: $draft.workingDir,
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
                if AgendamentoDraft.showsTimeout(
                    for: draft.outputMode
                ) {
                    TimeoutPicker(
                        timeoutSeconds: $draft.timeoutSeconds,
                        kind: draft.kind,
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
            Picker(strings.executionMode, selection: outputModeSelection) {
                Text(strings.runInBackground).tag(OutputMode.none)
                if draft.kind != .shell {
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
            Toggle(strings.notifyOnSuccess, isOn: $draft.notifyOnSuccess)
                .toggleStyle(.checkbox)
                .disabled(draft.outputMode == .terminal)
                .help(
                    draft.outputMode == .terminal
                        ? strings.notifyOnSuccessUnavailableInTerminal
                        : ""
                )
            if draft.outputMode == .terminal {
                Text(strings.notifyOnSuccessUnavailableInTerminal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var outputModeDescription: String {
        switch draft.outputMode {
        case .none: return strings.runInBackgroundDescription
        case .terminal: return strings.runInTerminalDescription
        case .response: return strings.showResponseDescription
        }
    }

    private func scheduleConfiguration(
        snapshot: AgendamentoFormSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(strings.scheduleSection)
            repetitionPicker
            scheduleDetails(snapshot: snapshot)
        }
    }

    @ViewBuilder
    private func scheduleDetails(
        snapshot: AgendamentoFormSnapshot
    ) -> some View {
        if draft.repetition == .fixed {
            TimeChipsEditor(times: $draft.times, strings: strings)
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
            if draft.weekdays.isEmpty {
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
                isOn: $draft.bootstrapWhenInactive
            )
            .toggleStyle(.checkbox)
            Text(strings.bootstrapWhenInactiveHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            if snapshot.hasContinuousConflict {
                Label(strings.continuousConflict,
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func actionBar(
        snapshot: AgendamentoFormSnapshot
    ) -> some View {
        HStack(spacing: 12) {
            Toggle(strings.enabled, isOn: $draft.enabled)
                .toggleStyle(.checkbox)
            Spacer()
            Button(strings.cancel) { onDone() }
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? strings.add : strings.save) { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!snapshot.canSave)
                .help(saveDisabledReason(for: snapshot.firstIssue) ?? "")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var kindBinding: Binding<Message.Kind> {
        Binding(
            get: { draft.kind },
            set: { newKind in
                draft.changeKind(to: newKind)
                refreshSkills()
            }
        )
    }

    private var skillBinding: Binding<String?> {
        Binding(
            get: { draft.skill },
            set: { draft.selectSkill($0) }
        )
    }

    private var outputModeSelection: Binding<OutputMode> {
        Binding(
            get: { draft.outputMode },
            set: { mode in
                draft.outputMode = mode
                if mode == .terminal {
                    draft.notifyOnSuccess = false
                }
            }
        )
    }

    private var repetitionPicker: some View {
        Picker(strings.repetition, selection: $draft.repetition) {
            Text(strings.fixedTimes).tag(ScheduledTask.Repetition.fixed)
            if draft.kind != .shell {
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
            get: { draft.weekdays.contains(day) },
            set: { on in
                if on {
                    draft.weekdays.insert(day)
                } else {
                    draft.weekdays.remove(day)
                }
            }
        )
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
        Button(strings.daysSummary(preset)) {
            draft.weekdays = preset
        }
            .buttonStyle(.link)
            .disabled(draft.weekdays == preset)
    }

    /// Aviso não bloqueante: dois horários dentro da mesma janela de 5h.
    /// Só para Claude/Codex — shell não abre janela.
    private var overlapWarning: Bool {
        guard draft.kind != .shell,
              draft.repetition == .fixed,
              let gap = AgendaMath.minCircularGap(draft.times) else {
            return false
        }
        return gap < 300
    }

    private var nextFirePreview: String? {
        guard draft.repetition == .fixed,
              let next = AgendaMath.nextOccurrence(
                  times: draft.times,
                  weekdays: draft.weekdays,
                  after: Date(),
                  calendar: .current
              )
        else { return nil }
        return strings.nextAt(Fmt.weekdayTime(next, language: state.language))
    }

    /// Motivo de o Salvar estar desabilitado (tooltip); nil quando válido.
    private func saveDisabledReason(
        for issue: AgendamentoIssue?
    ) -> String? {
        guard let issue else { return nil }
        switch issue {
        case .emptyMessage:
            return strings.saveNeedsMessage
        case .missingTime:
            return strings.saveNeedsTime
        case .missingWeekday:
            return strings.saveNeedsDay
        case .continuousShell:
            return strings.continuousShellInvalidEvent
        case .continuousConflict:
            return strings.continuousConflict
        case .accountUnavailable:
            return strings.accountFolderMissing
        }
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

        guard draft.kind != .shell else {
            availableSkills = []
            return
        }
        let provider: Provider =
            draft.kind == .codex ? .codex : .claude
        let dir = draft.account.map { URL(fileURLWithPath: $0) }
            ?? (provider == .codex ? AppState.defaultCodexConfigDir : AppState.defaultConfigDir)
        let inventoryKey =
            ProviderAccountContext.canonicalAccountDirectory(dir).path
        let pluginInventoryState = provider == .codex
            ? codexPluginInventories.queryState(for: inventoryKey)
            : .notQueried
        let cachedInventory = pluginInventoryState.inventory

        var localSkills = SkillCatalog.skills(
            for: provider,
            at: dir,
            workingDir: selectedWorkingDirectoryURL,
            codexPluginInventory: cachedInventory)
        // Enquanto esta conta ainda não tem resposta autoritativa, preserve
        // uma seleção Codex já persistida. Falha/timeout também a preserva,
        // mas um inventário válido é autoridade até quando vem vazio.
        if provider == .codex,
           pluginInventoryState.preservesPersistedSelection,
           cachedInventory == nil,
           let skill = draft.skill,
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
            codexPluginInventories.replaceQueryResult(
                inventory,
                for: inventoryKey
            )
            guard let inventory else {
                refreshSkills(reloadCodexPlugins: false)
                return
            }
            availableSkills = SkillCatalog.skills(
                for: provider,
                at: dir,
                workingDir: selectedWorkingDirectoryURL,
                codexPluginInventory: inventory
            )
        }
    }

    private var selectedWorkingDirectoryURL: URL? {
        let trimmed = draft.workingDir.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        return URL(
            fileURLWithPath:
                NSString(string: trimmed).expandingTildeInPath
        )
    }

    static func hasAdvancedConfiguration(_ draft: AgendamentoDraft) -> Bool {
        draft.model != Message.defaultModel
            || draft.effort != Message.defaultEffort
            || draft.safeMode != Message.defaultSafeMode
            || !draft.codexModel.isEmpty
            || draft.codexReasoning != nil
            || draft.timeoutSeconds != nil
            || draft.skill?.isEmpty == false
            || !draft.workingDir.isEmpty
    }

    private func commit() {
        switch editor.apply(.save(draft)) {
        case .success:
            onDone()
        case .failure(let error):
            switch error {
            case .invalid(let issues):
                commitErrorMessage =
                    saveDisabledReason(for: issues.first)
                        ?? strings.scheduleCouldNotSave
            case .notFound:
                commitErrorMessage = strings.scheduleNoLongerExists
            case .stale:
                commitErrorMessage = strings.scheduleChangedWhileEditing
            }
        }
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
