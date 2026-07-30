import Foundation
import ServiceManagement

protocol LoginItemManaging {
    var isSupported: Bool { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

struct SystemLoginItemManager: LoginItemManaging {
    let profile: AppRuntimeProfile

    init(profile: AppRuntimeProfile = .current) {
        self.profile = profile
    }

    var isSupported: Bool { profile.supportsLoginItem }
    var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }
        do {
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            NSLog("Ohayo LoginItem: \(error)")
        }
    }
}

struct ClosureLoginItemManager: LoginItemManaging {
    let isSupported: Bool
    let getEnabled: () -> Bool
    let setEnabledAction: (Bool) -> Void

    init(isSupported: Bool, getEnabled: @escaping () -> Bool,
         setEnabled: @escaping (Bool) -> Void) {
        self.isSupported = isSupported
        self.getEnabled = getEnabled
        self.setEnabledAction = setEnabled
    }

    var isEnabled: Bool { getEnabled() }
    func setEnabled(_ enabled: Bool) { setEnabledAction(enabled) }
}

/// Compatibility facade until settings and the guide receive injected managers.
enum LoginItem {
    private static let manager = SystemLoginItemManager()

    static var isSupported: Bool { manager.isSupported }
    static var isEnabled: Bool { manager.isEnabled }
    static func setEnabled(_ enabled: Bool) { manager.setEnabled(enabled) }
}
