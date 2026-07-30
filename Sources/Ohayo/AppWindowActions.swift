import AppKit

/// App-level window actions that SwiftUI does not expose on the macOS 13
/// deployment target.
@MainActor
enum AppWindowActions {
    static func shouldOpenSettingsForUITesting(
        profile: AppRuntimeProfile,
        arguments: [String]
    ) -> Bool {
        profile == .development && arguments.contains("--ui-testing")
    }

    static func openSettings() {
        openSettings(
            deferToNextRunLoop: { action in
                DispatchQueue.main.async {
                    action()
                }
            },
            activate: {
                NSApp.activate(ignoringOtherApps: true)
            },
            sendAction: { selectorName in
                NSApp.sendAction(
                    Selector((selectorName)),
                    to: nil,
                    from: nil
                )
            }
        )
    }

    static func openSettings(
        deferToNextRunLoop: (@escaping @MainActor () -> Void) -> Void,
        activate: @escaping @MainActor () -> Void,
        sendAction: @escaping @MainActor (String) -> Bool
    ) {
        // MenuBarExtra keeps its own transient responder chain while the panel
        // is open. Defer activation and delivery until the panel closes so
        // SwiftUI's Settings scene can receive the action instead of silently
        // dropping it.
        deferToNextRunLoop {
            activate()

            // SwiftUI's Settings scene changed its responder-chain selector
            // name. Try the current spelling first and retain the macOS 13
            // fallback.
            if sendAction("showSettingsWindow:") {
                return
            }

            _ = sendAction("showPreferencesWindow:")
        }
    }
}
