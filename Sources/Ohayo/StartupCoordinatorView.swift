import SwiftUI

enum StartupCoordinator {
    static func shouldOpenGuide(hasDismissed: Bool, isBundled: Bool) -> Bool {
        isBundled && !hasDismissed
    }
}

struct StartupCoordinatorView: View {
    @ObservedObject var state: AppState
    let isBundled: Bool
    let exposesMainWindowForUITesting: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var evaluated = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard !evaluated else { return }
                evaluated = true
                if exposesMainWindowForUITesting {
                    state.accountFilter = nil
                    state.settingsSection = .geral
                    AppWindowActions.presentWindow(
                        closePanel: AppWindowActions.closeMenuBarPanel,
                        openWindow: { openWindow(id: "schedule") }
                    )
                    return
                }
                if StartupCoordinator.shouldOpenGuide(
                    hasDismissed: state.hasDismissedPermissionGuide,
                    isBundled: isBundled
                ) {
                    openWindow(id: "permissions")
                }
            }
    }
}
