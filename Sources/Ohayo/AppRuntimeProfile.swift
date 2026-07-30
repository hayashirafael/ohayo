import Foundation

/// Runtime identity for the installed app and local development builds.
///
/// Only the official bundle identifier selects production. An unbundled
/// executable (`swift run Ohayo`) and any non-production bundle fail safely
/// into the isolated development profile.
enum AppRuntimeProfile: String, CaseIterable {
    case production
    case development

    static let productionBundleIdentifier = "io.github.hayashirafael.Ohayo"
    static let developmentBundleIdentifier = "io.github.hayashirafael.Ohayo.dev"

    static func resolve(bundleIdentifier: String?) -> Self {
        bundleIdentifier == productionBundleIdentifier
            ? .production
            : .development
    }

    static var current: Self {
        resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    var bundleIdentifier: String {
        switch self {
        case .production: Self.productionBundleIdentifier
        case .development: Self.developmentBundleIdentifier
        }
    }

    var displayName: String {
        switch self {
        case .production: "Ohayo"
        case .development: "Ohayo Dev"
        }
    }

    var supportDirectoryName: String { displayName }
    var preferencesDomainIdentifier: String { bundleIdentifier }
    var supportsAppUpdates: Bool { self == .production }
    var supportsLoginItem: Bool { self == .production }

    /// Packaged apps use `.standard`, whose domain is their bundle identifier.
    /// An unbundled SwiftPM executable explicitly joins the development domain
    /// instead of relying on the host process's implicit preferences domain.
    static func defaultUserDefaults(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> UserDefaults {
        guard bundleIdentifier == nil else { return .standard }
        return UserDefaults(suiteName: developmentBundleIdentifier) ?? .standard
    }
}
