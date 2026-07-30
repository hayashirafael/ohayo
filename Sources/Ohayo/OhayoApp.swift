import AppKit
import SwiftUI

@main
struct OhayoApp: App {
    @StateObject private var env = AppEnvironment()
    @StateObject private var updater = AppUpdater()

    /// Vive pelo processo inteiro: o kernel solta o flock quando ele morre.
    private static let instanceLock = SingleInstanceLock()

    init() {
        // Duas instâncias sobre o mesmo UserDefaults = disparos duplicados e
        // histórico sobrescrito. A recém-aberta avisa e sai; o `@StateObject`
        // é preguiçoso, então o AppEnvironment (timers/engines) nem chega a
        // existir neste caminho.
        if !Self.instanceLock.acquire() {
            let language = AppLanguage(
                rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .english
            let strings = L10n(language: language)
            let alert = NSAlert()
            alert.messageText = strings.alreadyRunningTitle
            alert.informativeText = strings.alreadyRunningBody
            alert.runModal()
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(state: env.state)
        } label: {
            MenuBarLabel(state: env.state)
                .background {
                    StartupCoordinatorView(
                        state: env.state,
                        isBundled: Bundle.main.bundleIdentifier != nil
                    )
                }
        }
        .menuBarExtraStyle(.window)

        Window("Ohayo", id: "schedule") {
            SettingsView(state: env.state, env: env)
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)

        Settings {
            GeneralTab(state: env.state, updater: updater)
                .frame(width: 620)
                .frame(minHeight: 430)
        }

        Window(env.state.strings.permissionGuideTitle, id: "permissions") {
            PermissionSetupView(state: env.state)
        }
        .defaultSize(width: 620, height: 680)
        .windowResizability(.contentMinSize)
    }
}
