import SwiftUI

/// Painel do menu da barra (.window): os próximos N agendamentos a disparar entre
/// todas as contas (padrão 1, configurável em Geral), ordenadas por horário.
/// Contas pausadas são puladas — o painel mostra o que vai executar de fato.
/// Clique num agendamento abre Ohayo › Agendamentos filtrado pela conta dele.
struct MenuPanel: View {
    @ObservedObject var state: AppState
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @State private var hovered: UUID?
    private var strings: L10n { state.strings }

    private var upcoming: [MenuPanelLogic.UpcomingEvent] {
        MenuPanelLogic.upcomingEvents(
            tasks: state.tasks,
            nextRenewals: state.nextRenewals, nextTaskFires: state.nextTaskFires,
            isPaused: { state.isPaused($0) },
            isQuotaUnavailable: {
                state.quotaUnavailableReasons[$0.standardizedFileURL] != nil
            },
            needsAttention: {
                state.renewalNeedsAttention.contains($0.standardizedFileURL)
            },
            accountDir: { state.accountDir(for: $0) },
            now: Date(), limit: state.panelUpcomingCount,
            renewalFallbackName: strings.renewalFallbackName)
    }

    var body: some View {
        VStack(spacing: 7) {
            header
            content
            footer
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            hovered = nil
            // O painel não mostra mais a janela de 5h, mas o glifo da barra
            // (MenuBarLabel) ainda depende de windowEnds atualizado.
            Task { await env.refreshWindowEnds() }
        }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 8) {
            if state.missingCLIs.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ohayo")
                        .font(.headline)
                    if panelHasProblem {
                        Button(action: openHealthDetails) {
                            Label(panelHealthTitle, systemImage: panelHealthSymbol)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help(healthDetailsTitle)
                    } else {
                        Label(panelHealthTitle, systemImage: panelHealthSymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button(action: openPermissions) {
                    Label(headerTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help(strings.reviewSetup)
            }
            Spacer()
            Menu {
                Button {
                    openSettings()
                } label: {
                    Label(strings.settingsShort, systemImage: "gearshape")
                }
                Button {
                    openPermissions()
                } label: {
                    Label(strings.permissionsSettingsButton, systemImage: "checklist")
                }
                Divider()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(strings.quitOhayo, systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(strings.moreActions)
            .accessibilityLabel(strings.moreActions)
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 2)
    }

    private var headerTitle: String {
        if let missing = state.missingCLIs.first {
            return strings.installCLIWarning(missing)
        }
        return "Ohayo"
    }

    private var panelHasProblem: Bool {
        if lastEventFailed { return true }
        return !state.allScheduledAccountsPaused
            && (!state.quotaUnavailableReasons.isEmpty
                || !state.renewalNeedsAttention.isEmpty)
    }

    private var panelHealthTitle: String {
        if panelHasProblem { return strings.menuBarStatusProblem }
        if state.allScheduledAccountsPaused { return strings.menuBarStatusPaused }
        return strings.ready
    }

    private var panelHealthSymbol: String {
        if panelHasProblem { return "exclamationmark.triangle.fill" }
        if state.allScheduledAccountsPaused { return "pause.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var lastEventFailed: Bool {
        if case .failure = state.lastEvent?.result { return true }
        return false
    }

    private var healthDetailsTitle: String {
        lastEventFailed ? strings.viewDetails : strings.reviewSchedules
    }

    private func openHealthDetails() {
        open(lastEventFailed ? .historico : .horarios, filter: nil)
    }

    // MARK: - Próximos disparos (1º em destaque, demais compactos)

    @ViewBuilder
    private var content: some View {
        let events = upcoming
        if events.isEmpty {
            emptyContent
        } else {
            highlightCard(events[0])
            ForEach(events.dropFirst(), id: \.taskUID) { compactRow($0) }
        }
    }

    private var emptyPanelState: MenuPanelLogic.PanelEmptyState {
        MenuPanelLogic.emptyState(
            tasks: state.tasks,
            accountDir: { state.accountDir(for: $0) },
            isPaused: { state.isPaused($0) },
            isQuotaUnavailable: {
                state.quotaUnavailableReasons[$0.standardizedFileURL] != nil
            },
            needsAttention: {
                state.renewalNeedsAttention.contains($0.standardizedFileURL)
            })
    }

    private var emptyContent: some View {
        VStack(spacing: 9) {
            Image(systemName: emptySymbol)
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(emptyStateIsProblem ? .orange : .secondary)
            Text(emptyTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(emptyDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(emptyActionTitle, action: emptyAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptySymbol: String {
        switch emptyPanelState {
        case .noSchedules: return "calendar.badge.plus"
        case .allDisabled: return "pause.rectangle"
        case .allPaused: return "pause.circle"
        case .quotaUnavailable: return "exclamationmark.shield"
        case .needsAttention: return "exclamationmark.triangle"
        case .waiting: return "hourglass"
        }
    }

    private var emptyStateIsProblem: Bool {
        switch emptyPanelState {
        case .quotaUnavailable, .needsAttention: return true
        case .noSchedules, .allDisabled, .allPaused, .waiting: return false
        }
    }

    private var emptyTitle: String {
        switch emptyPanelState {
        case .noSchedules: return strings.noSchedulesPanelTitle
        case .allDisabled: return strings.allSchedulesDisabledPanelTitle
        case .allPaused: return strings.allAccountsPaused
        case .quotaUnavailable: return strings.quotaUnavailablePanelTitle
        case .needsAttention: return strings.needsAttentionPanelTitle
        case .waiting: return strings.waitingForWindowPanelTitle
        }
    }

    private var emptyDescription: String {
        switch emptyPanelState {
        case .noSchedules: return strings.noSchedulesPanelDescription
        case .allDisabled: return strings.allSchedulesDisabledPanelDescription
        case .allPaused: return strings.allPausedPanelDescription
        case .quotaUnavailable: return strings.quotaUnavailablePanelDescription
        case .needsAttention: return strings.needsAttentionPanelDescription
        case .waiting: return strings.waitingForWindowPanelDescription
        }
    }

    private var emptyActionTitle: String {
        switch emptyPanelState {
        case .noSchedules: return strings.newSchedule
        case .allDisabled: return strings.reviewSchedules
        case .allPaused: return strings.reviewAccounts
        case .quotaUnavailable, .needsAttention, .waiting:
            return strings.reviewSchedules
        }
    }

    private func emptyAction() {
        switch emptyPanelState {
        case .allPaused:
            open(.contas, filter: nil)
        case .noSchedules:
            state.newScheduleRequest = UUID()
            open(.horarios, filter: nil)
        case .allDisabled, .quotaUnavailable, .needsAttention, .waiting:
            open(.horarios, filter: nil)
        }
    }

    /// Card em destaque da próxima tarefa: provedor · conta / nome · horário.
    private func highlightCard(_ event: MenuPanelLogic.UpcomingEvent) -> some View {
        Button {
            open(.horarios, filter: event.account)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    eventIcon(event, size: 16)
                        .frame(width: 20, height: 20)
                    Text(event.account.map { state.label(for: $0) } ?? strings.command)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                }
                HStack {
                    Text(event.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(Fmt.eventTime(event.date, now: Date(), language: state.language))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                }
                .padding(.leading, 28)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .background(.quaternary.opacity(hovered == event.taskUID ? 0.9 : 0.5),
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(strings.accountTasks)
        .accessibilityLabel(
            "\(event.name), \(event.account.map { state.label(for: $0) } ?? strings.command), "
                + Fmt.eventTime(event.date, now: Date(), language: state.language)
        )
        .onHover { hovered = $0 ? event.taskUID : nil }
    }

    /// Linha compacta dos demais disparos: provedor · conta · nome · horário.
    private func compactRow(_ event: MenuPanelLogic.UpcomingEvent) -> some View {
        Button {
            open(.horarios, filter: event.account)
        } label: {
            HStack(spacing: 6) {
                eventIcon(event, size: 12)
                Text("\(event.account.map { state.label(for: $0) } ?? strings.command) · \(event.name)")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer()
                Text(Fmt.eventTime(event.date, now: Date(), language: state.language))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
            .background(.quaternary.opacity(hovered == event.taskUID ? 0.6 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(strings.accountTasks)
        .onHover { hovered = $0 ? event.taskUID : nil }
    }

    @ViewBuilder
    private func eventIcon(_ event: MenuPanelLogic.UpcomingEvent, size: CGFloat) -> some View {
        if let account = event.account {
            ProviderIcon(provider: state.provider(for: account), size: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rodapé (Agendamentos · Histórico · Ajustes)

    private var footer: some View {
        HStack(spacing: 7) {
            footerButton("checklist", strings.schedules) { open(.horarios, filter: nil) }
            footerButton("clock.arrow.circlepath", strings.history) { open(.historico, filter: nil) }
            footerButton("gearshape", strings.settingsShort) { openSettings() }
        }
        .padding(.top, 3)
        .overlay(alignment: .top) { Divider().offset(y: -3) }
    }

    private func footerButton(_ symbol: String, _ title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navegação

    private func open(_ section: SettingsSection, filter: URL?) {
        state.accountFilter = filter
        state.settingsSection = section
        openWindow(id: "schedule")
        NSApp.activate(ignoringOtherApps: true)
        closePanel()
    }

    private func openSettings() {
        AppWindowActions.openSettings()
        closePanel()
    }

    private func openPermissions() {
        openWindow(id: "permissions")
        NSApp.activate(ignoringOtherApps: true)
        closePanel()
    }

    /// O painel .window do MenuBarExtra não fecha sozinho ao abrir outra
    /// janela — fecha a janela do próprio painel explicitamente.
    private func closePanel() {
        NSApp.windows.first { $0.className.contains("MenuBarExtraWindow") }?.close()
    }
}
