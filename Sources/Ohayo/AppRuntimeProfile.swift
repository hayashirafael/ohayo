import Foundation

/// Identidade de runtime do app instalado e dos builds locais.
///
/// Somente o bundle ID oficial seleciona produção. Um executável sem bundle
/// (`swift run Ohayo`) e qualquer bundle não oficial falham com segurança para
/// o perfil isolado de desenvolvimento.
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

    /// Apps empacotados usam `.standard`, cujo domínio é o bundle ID. Um
    /// executável SwiftPM sem bundle entra explicitamente no domínio Dev em
    /// vez de depender do domínio implícito do processo hospedeiro.
    static func defaultUserDefaults(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> UserDefaults {
        guard bundleIdentifier == nil else { return .standard }
        return UserDefaults(suiteName: developmentBundleIdentifier) ?? .standard
    }
}
