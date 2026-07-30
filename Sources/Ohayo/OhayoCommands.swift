import SwiftUI

/// Preserva o atalho macOS de Ajustes mesmo com Geral vivendo na janela
/// central do produto em vez de uma cena `Settings` separada.
struct OhayoCommands: Commands {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    @MainActor
    static func prepareGeneralNavigation(state: AppState) {
        state.accountFilter = nil
        state.settingsSection = .geral
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(state.strings.settingsShort) {
                Self.prepareGeneralNavigation(state: state)
                AppWindowActions.presentWindow(
                    closePanel: AppWindowActions.closeMenuBarPanel,
                    openWindow: { openWindow(id: "schedule") }
                )
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
