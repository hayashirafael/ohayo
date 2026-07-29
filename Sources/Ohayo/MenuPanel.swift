import SwiftUI

/// Painel do menu da barra (.window): as próximas N tarefas a disparar entre
/// todas as contas (padrão 1, configurável em Geral), ordenadas por horário.
/// Contas pausadas são puladas — o painel mostra o que vai executar de fato.
/// Clique numa tarefa abre Ajustes › Tarefas filtrado pela conta dela.
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
        .padding(10)
        .frame(width: 310)
        .onAppear {
            hovered = nil
            // O painel não mostra mais a janela de 5h, mas o glifo da barra
            // (MenuBarLabel) ainda depende de windowEnds atualizado.
            Task { await env.refreshWindowEnds() }
        }
    }

    // MARK: - Cabeçalho ("Ohayo" ou aviso de CLI + botão Sair)

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.caption)
                .foregroundStyle(state.missingCLIs.isEmpty ? .secondary : Color.orange)
                .lineLimit(1)
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(strings.quit)
        }
        .padding(.horizontal, 2)
    }

    private var headerTitle: String {
        if let missing = state.missingCLIs.first {
            return strings.installCLIWarning(missing)
        }
        return "Ohayo"
    }

    // MARK: - Próximos disparos (1º em destaque, demais compactos)

    @ViewBuilder
    private var content: some View {
        let events = upcoming
        if events.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else {
            highlightCard(events[0])
            ForEach(events.dropFirst(), id: \.taskUID) { compactRow($0) }
        }
    }

    private var emptyText: String {
        switch MenuPanelLogic.emptyState(
            tasks: state.tasks,
            accountDir: { state.accountDir(for: $0) },
            isPaused: { state.isPaused($0) },
            isQuotaUnavailable: {
                state.quotaUnavailableReasons[$0.standardizedFileURL] != nil
            },
            needsAttention: {
                state.renewalNeedsAttention.contains($0.standardizedFileURL)
            }) {
        case .noSchedules: return strings.noActiveSchedules
        case .allPaused: return strings.allAccountsPaused
        case .quotaUnavailable: return strings.quotaUnavailable
        case .needsAttention: return strings.needsAttention
        case .waiting: return strings.waitingForWindow
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

    // MARK: - Rodapé (Tarefas · Histórico · Ajustes)

    private var footer: some View {
        HStack(spacing: 7) {
            footerButton("checklist", strings.schedules) { open(.horarios, filter: nil) }
            footerButton("clock.arrow.circlepath", strings.history) { open(.historico, filter: nil) }
            footerButton("gearshape", strings.settingsShort) { open(.geral, filter: nil) }
        }
        .padding(.top, 3)
        .overlay(alignment: .top) { Divider().offset(y: -3) }
    }

    private func footerButton(_ symbol: String, _ title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
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

    /// O painel .window do MenuBarExtra não fecha sozinho ao abrir outra
    /// janela — fecha a janela do próprio painel explicitamente.
    private func closePanel() {
        NSApp.windows.first { $0.className.contains("MenuBarExtraWindow") }?.close()
    }
}
