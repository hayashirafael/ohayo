import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case contas, horarios, historico, geral

    /// `geral` lives in the native Settings scene. Keep the case in the
    /// shared navigation state so existing deep links remain source-compatible.
    static let operationalCases: [SettingsSection] = [.horarios, .contas, .historico]

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

/// Operational window for the parts of Ohayo users monitor and act on.
///
/// App preferences live in the native SwiftUI `Settings` scene instead of
/// competing with accounts, schedules, and run history in this sidebar.
struct SettingsView: View {
    @ObservedObject var state: AppState
    let env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.operationalCases, selection: $state.settingsSection) { section in
                Label(section.title(language: state.language), systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .navigationTitle(operationalSelection.title(language: state.language))
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 720,
            idealWidth: 820,
            minHeight: 520,
            idealHeight: 600
        )
        .onAppear(perform: normalizeSelection)
        .onChange(of: state.settingsSection) { _ in
            normalizeSelection()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch operationalSelection {
        case .contas: ContasView(state: state)
        case .horarios: HorariosView(state: state, env: env)
        case .historico: HistoryTab(state: state)
        case .geral: EmptyView()
        }
    }

    private var operationalSelection: SettingsSection {
        state.settingsSection == .geral ? .horarios : state.settingsSection
    }

    private func normalizeSelection() {
        if state.settingsSection == .geral {
            state.settingsSection = .horarios
        }
    }
}
