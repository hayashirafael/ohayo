import SwiftUI

/// Seção Horários: barra fixa (resumo, filtros, ordenação e novo agendamento)
/// sobre a lista compacta de agendamentos — cada linha expande no clique.
struct HorariosView: View {
    @ObservedObject var state: AppState
    let env: AppEnvironment
    @State private var showingForm = false
    @State private var editing: ScheduledTask? = nil
    @State private var conflictAlert = false
    // Estado efêmero da janela (decisão de produto: não persiste).
    @State private var filter = HorariosFilter()
    @State private var sort: HorariosSort = .padrao
    @State private var expanded: Set<UUID> = []
    @State private var firing: Set<UUID> = []
    /// Agendamento aguardando confirmação de exclusão (excluir não tem undo).
    @State private var pendingDelete: ScheduledTask? = nil
    private var strings: L10n { state.strings }

    var body: some View {
        Group {
            if state.tasks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    headerBar
                    Divider()
                    listArea
                }
            }
        }
        .sheet(isPresented: $showingForm) {
            AgendamentoFormSheet(state: state, editing: editing) { showingForm = false }
        }
        .alert(strings.continuousConflictTitle, isPresented: $conflictAlert) {
            Button(strings.ok, role: .cancel) {}
        } message: {
            Text(strings.continuousConflict)
        }
        .confirmationDialog(
            strings.deleteScheduleConfirmTitle,
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { task in
            Button(strings.delete, role: .destructive) { remove(task) }
            Button(strings.cancel, role: .cancel) {}
        } message: { task in
            Text(HorariosListModel.title(task))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(strings.noSchedulesYet)
            Text(strings.noSchedulesDescription)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(strings.newSchedule) { editing = nil; showingForm = true }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(40)
    }

    // MARK: Linhas resolvidas contra o estado

    /// Linhas com conta/rótulo/próximo disparo resolvidos — entrada do modelo.
    /// Já escopadas pelo deep-link de conta do painel (`accountFilter`), que
    /// funciona como um escopo externo sobre a tela toda (chip no header).
    private var rows: [HorariosRow] {
        state.tasks.filter { state.taskMatchesFilter($0) }.map { task in
            let dir = state.accountDir(for: task)
            return HorariosRow(task: task,
                               accountPath: dir?.standardizedFileURL.path,
                               accountLabel: dir.map { state.label(for: $0) },
                               nextFire: nextFireDate(task))
        }
    }

    private var visibleRows: [HorariosRow] {
        HorariosListModel.apply(rows, filter: filter, sort: sort)
    }

    /// Próximo disparo futuro da tarefa (fixa via TaskScheduler, contínua via
    /// RenewalEngine); nil quando desativada ou nada armado.
    private func nextFireDate(_ task: ScheduledTask) -> Date? {
        guard task.enabled else { return nil }
        switch task.repetition {
        case .continuous:
            guard let dir = state.accountDir(for: task),
                  let next = state.nextRenewals[dir], next > Date() else { return nil }
            return next
        case .fixed:
            guard let next = state.nextTaskFires[task.uid], next > Date() else { return nil }
            return next
        }
    }

    // MARK: Barra do topo

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryLine
            if let deepLink = state.accountFilter {
                accountFilterChip(deepLink)
            }
            HStack(spacing: 8) {
                filterMenu
                sortMenu
                Spacer()
                Button {
                    editing = nil
                    showingForm = true
                } label: {
                    Label(strings.newSchedule, systemImage: "plus")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summaryLine: some View {
        let summary = HorariosListModel.summary(rows)
        var parts = [strings.scheduleSummary(total: summary.total, active: summary.active)]
        if let next = summary.next {
            parts.append(strings.summaryNext(Fmt.weekdayTime(next, language: state.language)))
        }
        if filter.isActive {
            parts.append(strings.visibleCount(visibleRows.count))
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Chip do deep-link de conta vindo do painel do menu: escopa a tela a uma
    /// conta e some ao ser limpo (o × zera `state.accountFilter`).
    private func accountFilterChip(_ dir: URL) -> some View {
        HStack(spacing: 6) {
            Label(strings.filteredBy(state.label(for: dir)),
                  systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption)
            Button {
                state.accountFilter = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(strings.clearFilter)
        }
        .foregroundStyle(.tint)
    }

    private var filterMenu: some View {
        Menu {
            Picker(strings.account, selection: $filter.accountPath) {
                Text(strings.allAccountsOption).tag(String?.none)
                ForEach(state.discoverAccounts(), id: \.self) { dir in
                    Text(state.label(for: dir))
                        .tag(String?.some(dir.standardizedFileURL.path))
                }
            }
            Picker(strings.providerLabel, selection: $filter.kind) {
                Text(strings.allOption).tag(Message.Kind?.none)
                Text(Provider.claude.displayName).tag(Message.Kind?.some(.claude))
                Text(Provider.codex.displayName).tag(Message.Kind?.some(.codex))
                Text(strings.taskKind(.shell)).tag(Message.Kind?.some(.shell))
            }
            Picker(strings.statusLabel, selection: $filter.enabled) {
                Text(strings.allOption).tag(Bool?.none)
                Text(strings.activeOption).tag(Bool?.some(true))
                Text(strings.inactiveOption).tag(Bool?.some(false))
            }
            Picker(strings.type, selection: $filter.repetition) {
                Text(strings.allOption).tag(ScheduledTask.Repetition?.none)
                Text(strings.continuousBadge).tag(ScheduledTask.Repetition?.some(.continuous))
                Text(strings.fixedTimes).tag(ScheduledTask.Repetition?.some(.fixed))
            }
            Divider()
            Button(strings.clearFilters) { filter = HorariosFilter() }
                .disabled(!filter.isActive)
        } label: {
            Label(strings.filter, systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .foregroundStyle(filter.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private var sortMenu: some View {
        Menu {
            Picker(strings.sortMenu, selection: $sort) {
                Text(strings.sortDefault).tag(HorariosSort.padrao)
                Text(strings.account).tag(HorariosSort.conta)
                Text(strings.sortByNextFire).tag(HorariosSort.proximoDisparo)
                Text(strings.sortByName).tag(HorariosSort.nome)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(strings.sortMenu, systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
    }

    // MARK: Lista

    @ViewBuilder
    private var listArea: some View {
        let visible = visibleRows
        if visible.isEmpty {
            VStack(spacing: 8) {
                Text(strings.noFilterMatches)
                    .font(.callout).foregroundStyle(.secondary)
                Button(strings.clearFilters) { filter = HorariosFilter(); state.accountFilter = nil }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(visible, id: \.task.uid) { row in
                        taskRow(row)
                    }
                } footer: {
                    Text(strings.scheduleListFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func taskRow(_ row: HorariosRow) -> some View {
        let task = row.task
        let isExpanded = expanded.contains(task.uid)
        VStack(alignment: .leading, spacing: 6) {
            compactLine(row, isExpanded: isExpanded)
            if isExpanded { detailBlock(row) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded(task.uid) }
        .contextMenu {
            Button(strings.runNow) { runNow(task) }
            Button(strings.edit) { editing = task; showingForm = true }
            Button(strings.delete, role: .destructive) { pendingDelete = task }
        }
    }

    /// Linha compacta: chevron · toggle · provedor · título · conta · próximo.
    private func compactLine(_ row: HorariosRow, isExpanded: Bool) -> some View {
        let task = row.task
        let msg = task.resolvedCommand
        return HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Toggle("", isOn: enabledBinding(task))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            ProviderIcon(provider: provider(for: msg.kind), size: 16)
                .foregroundStyle(task.enabled ? .primary : .secondary)
            Text(HorariosListModel.title(task))
                .fontWeight(.medium)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(task.enabled ? .primary : .secondary)
            if let label = row.accountLabel {
                Text(label)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if msg.kind != .shell, let cfg = msg.configDir, !cfg.isEmpty,
               row.accountPath == nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help(strings.accountFolderMissing)
            }
            if let next = nextLineText(row) {
                Text(next).font(.caption2).foregroundStyle(.tint)
            }
        }
    }

    /// Detalhe expandido: prompt, conta·modelo, horários, badge e ações.
    @ViewBuilder
    private func detailBlock(_ row: HorariosRow) -> some View {
        let task = row.task
        let msg = task.resolvedCommand
        VStack(alignment: .leading, spacing: 4) {
            if task.name != nil, !msg.text.isEmpty {
                Text(msg.text)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.tail)
            }
            if let target = targetLine(task) {
                detailLabel(target, systemImage: "person.crop.circle")
            }
            HStack(spacing: 6) {
                detailLabel(scheduleLine(task),
                            systemImage: task.repetition == .continuous
                                ? "arrow.triangle.2.circlepath" : "clock")
                repetitionBadge(task)
            }
            HStack(spacing: 14) {
                Button { runNow(task) } label: {
                    Label(strings.runNow, systemImage: "play.circle")
                }
                .disabled(firing.contains(task.uid))
                Button { editing = task; showingForm = true } label: {
                    Label(strings.edit, systemImage: "pencil")
                }
                Button(role: .destructive) { pendingDelete = task } label: {
                    Label(strings.delete, systemImage: "minus.circle")
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(.leading, 24)
    }

    // MARK: Ações

    private func toggleExpanded(_ uid: UUID) {
        if expanded.contains(uid) { expanded.remove(uid) } else { expanded.insert(uid) }
    }

    /// Disparo manual: desabilita o botão enquanto está em voo; o resultado
    /// aparece no Histórico (e nas notificações já existentes).
    private func runNow(_ task: ScheduledTask) {
        guard !firing.contains(task.uid) else { return }
        firing.insert(task.uid)
        Task {
            await env.fireNow(task)
            firing.remove(task.uid)
        }
    }

    private func remove(_ task: ScheduledTask) {
        state.tasks.removeAll { $0.uid == task.uid }
        expanded.remove(task.uid)
    }

    // MARK: Textos auxiliares

    private func detailLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func repetitionBadge(_ task: ScheduledTask) -> some View {
        Text(task.repetition == .continuous ? strings.continuousBadge : strings.fixedTimes)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.12), in: Capsule())
    }

    private func provider(for kind: Message.Kind) -> Provider? {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        case .shell: return nil
        }
    }

    /// Conta + modelo do disparo: "ailton@… · Haiku 4.5 · low" (Claude),
    /// "conta · gpt-x" (Codex). Shell não mira conta → nil.
    private func targetLine(_ task: ScheduledTask) -> String? {
        let msg = task.resolvedCommand
        guard msg.kind != .shell else { return nil }
        var parts: [String] = []
        if let dir = state.accountDir(for: task) {
            parts.append(state.label(for: dir))
        } else {
            parts.append(msg.kind == .claude ? strings.globalDefault : strings.codexDefault)
        }
        switch msg.kind {
        case .claude:
            parts.append("\(msg.resolvedModel.label) · \(msg.resolvedEffort.rawValue)")
        case .codex:
            if let model = msg.codexModel, !model.isEmpty { parts.append(model) }
        case .shell:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// "17:14 · todos os dias" (fixos) ou a descrição da janela contínua.
    private func scheduleLine(_ task: ScheduledTask) -> String {
        switch task.repetition {
        case .continuous:
            return strings.fixedContinuousDescription
        case .fixed:
            let horarios = task.times.sorted().map(Fmt.minutes).joined(separator: " · ")
            return "\(horarios) — \(Self.daysSummary(task.weekdays, language: state.language))"
        }
    }

    /// Próximo disparo da linha compacta: "renova 14:05", "próxima sáb 17:14"
    /// ou "aguardando janela" (contínua sem janela detectada).
    private func nextLineText(_ row: HorariosRow) -> String? {
        guard row.task.enabled else { return nil }
        switch row.task.repetition {
        case .continuous:
            if let path = row.accountPath,
               state.quotaUnavailableReasons[
                   URL(fileURLWithPath: path).standardizedFileURL
               ] != nil {
                return strings.quotaUnavailable
            }
            if let path = row.accountPath,
               state.renewalNeedsAttention.contains(
                   URL(fileURLWithPath: path).standardizedFileURL
               ) {
                return strings.needsAttention
            }
            guard let next = row.nextFire else { return strings.waitingForWindow }
            switch state.renewalRecoveryState(for: row.task) {
            case .retry:
                return strings.retriesAt(
                    Fmt.hhmm(next, language: state.language)
                )
            case .cooldown:
                return strings.mayTryAt(
                    Fmt.hhmm(next, language: state.language)
                )
            case .needsAttention, .none:
                break
            }
            return strings.renewsAt(Fmt.hhmm(next, language: state.language))
        case .fixed:
            guard let next = row.nextFire else { return nil }
            return strings.nextAt(Fmt.weekdayTime(next, language: state.language))
        }
    }

    /// Resumo dos dias: "todos os dias", "seg a sex", "fim de semana" ou lista.
    static func daysSummary(_ weekdays: Set<Int>, language: AppLanguage = .english) -> String {
        L10n(language: language).daysSummary(weekdays)
    }

    private func enabledBinding(_ task: ScheduledTask) -> Binding<Bool> {
        Binding(
            get: { state.tasks.first { $0.uid == task.uid }?.enabled ?? false },
            set: { on in
                if !state.setTaskEnabled(task, on) { conflictAlert = true }
            })
    }
}
