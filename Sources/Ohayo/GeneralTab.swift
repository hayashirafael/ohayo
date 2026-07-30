import SwiftUI

struct GeneralTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    private let loginItem: LoginItemManaging = SystemLoginItemManager()
    private var strings: L10n { state.strings }

    var body: some View {
        Form {
            Section(sectionTitle(en: "Startup", pt: "Inicialização")) {
                if loginItem.isSupported {
                    Toggle(strings.launchAtLogin, isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }))
                }
            }

            Section {
                Toggle(strings.remainingInMenuBar, isOn: $state.showRemainingInBar)
                Stepper(value: $state.panelUpcomingCount, in: 1...5) {
                    HStack {
                        Text(strings.panelUpcomingCountLabel)
                        Spacer()
                        Text("\(state.panelUpcomingCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text(sectionTitle(en: "Menu Bar", pt: "Barra de Menus"))
            } footer: {
                Text(strings.remainingInMenuBarFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(sectionTitle(en: "Notifications", pt: "Notificações")) {
                Toggle(
                    strings.showSensitiveNotificationDetails,
                    isOn: $state.showSensitiveNotificationDetails
                )
            }

            Section(sectionTitle(en: "Language", pt: "Idioma")) {
                Picker(strings.languageLabel, selection: $state.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.pickerTitle).tag(language)
                    }
                }
            }

            Section(sectionTitle(en: "System Access", pt: "Acesso ao Sistema")) {
                Button {
                    openWindow(id: "permissions")
                } label: {
                    Label(strings.permissionsSettingsButton, systemImage: "checklist")
                }
            }

            Section(sectionTitle(en: "About", pt: "Sobre")) {
                LabeledContent(strings.version) {
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let version = updater.availableVersion {
                    UpdateAvailableNotice(
                        version: version,
                        strings: strings,
                        update: updater.installAvailableUpdate
                    )
                }
                if updater.isSupported {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label(
                            strings.checkForUpdates,
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sectionTitle(en: String, pt: String) -> String {
        state.language == .portuguese ? pt : en
    }
}
