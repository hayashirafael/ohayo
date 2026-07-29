import SwiftUI

struct GeneralTab: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    private let loginItem: LoginItemManaging = SystemLoginItemManager()
    private var strings: L10n { state.strings }

    var body: some View {
        Form {
            Section {
                if loginItem.isSupported {
                    Toggle(strings.launchAtLogin, isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }))
                }
                Toggle(strings.remainingInMenuBar, isOn: $state.showRemainingInBar)
                Toggle(
                    strings.showSensitiveNotificationDetails,
                    isOn: $state.showSensitiveNotificationDetails
                )
                Stepper(value: $state.panelUpcomingCount, in: 1...5) {
                    HStack {
                        Text(strings.panelUpcomingCountLabel)
                        Spacer()
                        Text("\(state.panelUpcomingCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Picker(strings.languageLabel, selection: $state.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.pickerTitle).tag(language)
                    }
                }
            } footer: {
                Text(strings.remainingInMenuBarFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(strings.version) {
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button {
                    openWindow(id: "permissions")
                } label: {
                    Label(strings.permissionsSettingsButton, systemImage: "checklist")
                }
            }
        }
        .formStyle(.grouped)
    }
}
