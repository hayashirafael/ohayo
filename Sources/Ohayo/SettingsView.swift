import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case contas, horarios, historico, geral

    static let sidebarCases: [SettingsSection] = [
        .horarios,
        .contas,
        .historico,
        .geral
    ]

    var id: String { rawValue }
    func title(language: AppLanguage) -> String {
        L10n(language: language).settingsSectionTitle(self)
    }
    var icon: String {
        switch self {
        case .contas: return "person.crop.circle"
        case .horarios: return "checklist"
        case .historico: return "clock.arrow.circlepath"
        case .geral: return "gearshape"
        }
    }
}

/// Janela central do Ohayo: operação, histórico e ajustes no mesmo lugar.
struct SettingsView: View {
    @ObservedObject var state: AppState
    let env: AppEnvironment
    @ObservedObject var updater: AppUpdater

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.sidebarCases, selection: $state.settingsSection) { section in
                Label(section.title(language: state.language), systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .navigationTitle(state.settingsSection.title(language: state.language))
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 720,
            idealWidth: 820,
            minHeight: 520,
            idealHeight: 600
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch state.settingsSection {
        case .contas: ContasView(state: state)
        case .horarios: HorariosView(state: state, env: env)
        case .historico: HistoryTab(state: state)
        case .geral: GeneralTab(state: state, updater: updater)
        }
    }
}
