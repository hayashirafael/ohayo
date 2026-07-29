import AppKit

/// App-level window actions that SwiftUI does not expose on the macOS 13
/// deployment target.
@MainActor
enum AppWindowActions {
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        // SwiftUI's Settings scene changed its responder-chain selector name.
        // Try the current spelling first and retain the macOS 13 fallback.
        if NSApp.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        ) {
            return
        }

        _ = NSApp.sendAction(
            Selector(("showPreferencesWindow:")),
            to: nil,
            from: nil
        )
    }
}
