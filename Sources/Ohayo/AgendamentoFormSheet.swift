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

    init(state: AppState, editing: ScheduledTask?, onDone: @escaping () -> Void) {
        self._state = ObservedObject(wrappedValue: state)
        self.editing = editing
        self.onDone = onDone
        _draft = State(initialValue: AgendamentoDraft(editing: editing))
    }

    private var strings: L10n { state.strings }
    private var editor: AgendamentoEditor {
        AgendamentoEditor(state: state)
    }

    var body: some View {
        let snapshot = editor.formSnapshot(for: draft)
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? strings.newSchedule : strings.editSchedule).font(.headline)

            sectionHeader(strings.messageSection)
            KindSelector(kind: kindBinding, strings: strings)
            TextField(strings.nameOptional, text: $draft.name)
            TextField(strings.messageOrCommand, text: $draft.text)
            if draft.kind == .claude {
                ClaudeConfigForm(
                    model: $draft.model,
                    effort: $draft.effort,
                    safeMode: $draft.safeMode,
                                 configDir: $draft.account,
                                 skill: skillBinding,
                                 availableSkills: availableSkills,
                                 workingDir: $draft.workingDir,
                                 accounts: state.accounts(for: .claude),
                                 accountLabel: { state.label(for: $0) },
                                 strings: strings)
            }
            if draft.kind == .codex {
                CodexConfigForm(
                    model: $draft.codexModel,
                    reasoning: $draft.codexReasoning,
                                configDir: $draft.account,
                                skill: skillBinding,
                                availableSkills: availableSkills,
                                workingDir: $draft.workingDir,
                                accounts: state.accounts(for: .codex),
                                accountLabel: { state.label(for: $0) },
                                strings: strings)
            }
            if snapshot.hasAccountUnavailableIssue {
                Label(
                    strings.accountFolderMissing,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(strings.none, isOn: outputModeBinding(.none))
                    .toggleStyle(.checkbox)
                if draft.kind != .shell {
                    Toggle(strings.runInTerminal, isOn: outputModeBinding(.terminal))
                        .toggleStyle(.checkbox)
                }
                Toggle(strings.showResponse, isOn: outputModeBinding(.response))
                    .toggleStyle(.checkbox)
                if AgendamentoDraft.showsTimeout(
                    for: draft.outputMode
                ) {
                    TimeoutPicker(
                        timeoutSeconds: $draft.timeoutSeconds,
                        kind: draft.kind,
                        strings: strings
                    )
                }
                // Independente do modo de saída acima: notifica só em sucesso;
                // com "Mostrar resposta" ligado, a notificação de resposta vence.
                Toggle(
                    strings.notifyOnSuccess,
                    isOn: $draft.notifyOnSuccess
                )
                    .toggleStyle(.checkbox)
            }
            .font(.caption)

            Divider().padding(.vertical, 2)

            sectionHeader(strings.scheduleSection)
            repetitionPicker
            if draft.repetition == .fixed {
                TimeChipsEditor(times: $draft.times, strings: strings)
                weekdaysEditor
                dayPresetsRow
                if overlapWarning {
                    Label(strings.overlappingWindows, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let preview = nextFirePreview {
                    Text(preview).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(strings.fixedContinuousDescription)
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    strings.bootstrapWhenInactive,
                    isOn: $draft.bootstrapWhenInactive
                )
                .toggleStyle(.checkbox)
                .font(.caption)
                Text(strings.bootstrapWhenInactiveHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.hasContinuousConflict {
                    Label(strings.continuousConflict,
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Toggle(strings.enabled, isOn: $draft.enabled)
                .toggleStyle(.checkbox)
                .font(.caption)

            HStack {
                Spacer()
                Button(strings.cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? strings.add : strings.save) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!snapshot.canSave)
                    .help(saveDisabledReason(for: snapshot.firstIssue) ?? "")
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
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

    private func outputModeBinding(_ mode: OutputMode) -> Binding<Bool> {
        Binding(
            get: { draft.outputMode == mode },
            set: { selected in
                if selected { draft.outputMode = mode }
            })
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
        .background {
            if kind == value {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
        }
    }
}
