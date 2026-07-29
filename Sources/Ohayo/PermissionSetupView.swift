import SwiftUI

@MainActor
struct PermissionSetupView: View {
    @ObservedObject var state: AppState
    @StateObject private var model: PermissionSetupModel
    @StateObject private var doctorModel: ProviderDoctorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private var strings: L10n { state.strings }

    init(
        state: AppState,
        model: PermissionSetupModel? = nil,
        doctorModel: ProviderDoctorModel? = nil
    ) {
        self.state = state
        _model = StateObject(wrappedValue: model ?? PermissionSetupModel())
        _doctorModel = StateObject(wrappedValue: doctorModel ?? ProviderDoctorModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(strings.permissionGuideTitle).font(.title2).bold()
            Text(strings.permissionGuideIntro).foregroundStyle(.secondary)
            Form {
                Section(strings.providerDoctorTitle) {
                    ProviderDoctorView(
                        model: doctorModel,
                        accounts: doctorAccounts,
                        strings: strings
                    )
                }
                permissionRow(
                    title: strings.notificationsPermissionTitle,
                    body: strings.notificationsPermissionBody,
                    status: model.notificationStatus,
                    actionTitle: strings.allowNotifications,
                    settingsDestination: .notifications
                ) { Task { await model.requestNotifications() } }
                permissionRow(
                    title: strings.terminalAutomationTitle,
                    body: strings.terminalAutomationBody,
                    status: model.terminalStatus,
                    actionTitle: strings.testTerminal,
                    settingsDestination: .terminalAutomation
                ) { Task { await model.testTerminal() } }
                if model.loginItemSupported {
                    Toggle(strings.launchAtLogin, isOn: Binding(
                        get: { model.loginItemEnabled },
                        set: { model.setLoginItemEnabled($0) }))
                    Text(strings.optional).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(strings.configureLater) { closeGuide() }
                    .keyboardShortcut(.cancelAction)
                Button(strings.openSchedules) { continueToSchedules() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(
            minWidth: 560,
            idealWidth: 620,
            minHeight: 560,
            idealHeight: 680
        )
        .task { await model.refresh() }
        .onDisappear { state.dismissPermissionGuide() }
    }

    private var doctorAccounts: [ProviderDoctorAccount] {
        Provider.allCases.flatMap { provider in
            ProviderDoctorAccounts.configured(
                provider: provider,
                discoveredAccounts: state.accounts(for: provider),
                providerInUse: state.tasks.contains {
                    switch ($0.resolvedCommand.kind, provider) {
                    case (.claude, .claude), (.codex, .codex): return true
                    default: return false
                    }
                },
                label: { state.label(for: $0) }
            )
        }
    }

    private func closeGuide() {
        state.dismissPermissionGuide()
        dismiss()
    }

    private func continueToSchedules() {
        state.dismissPermissionGuide()
        state.settingsSection = .horarios
        openWindow(id: "schedule")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    private func permissionRow(
        title: String, body: String, status: PermissionAccessStatus,
        actionTitle: String,
        settingsDestination: PermissionSettingsDestination,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(strings.permissionStatus(status)).foregroundStyle(.secondary)
            }
            Text(body).font(.callout).foregroundStyle(.secondary)
            if status == .denied {
                Button(strings.openSystemSettings) {
                    model.openSettings(settingsDestination)
                }
            } else {
                Button(actionTitle, action: action)
                    .disabled(!status.allowsRequest)
            }
        }
        .padding(.vertical, 4)
    }
}
