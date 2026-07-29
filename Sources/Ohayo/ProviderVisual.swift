import AppKit
import SwiftUI

/// Âncora para `Bundle(for:)` localizar o bundle que contém este módulo
/// (o .app empacotado ou o .xctest nos testes).
private final class ProviderVisualBundleFinder {}

@MainActor
enum ProviderVisual {
    private static var cache: [Provider: NSImage] = [:]

    /// Nunca usar `Bundle.module` aqui: o acessor gerado pelo `swift build`
    /// só procura na raiz do `.app` e num caminho absoluto da máquina de
    /// build, e faz `fatalError` quando não acha — foi o crash ao abrir o
    /// Settings no app distribuído via Homebrew (o make-app.sh coloca o
    /// bundle em Contents/Resources). Este resolvedor cobre os layouts reais
    /// e degrada para `nil` (ícone de fallback) em vez de derrubar o app.
    nonisolated static let resourceBundleName = "Ohayo_Ohayo.bundle"

    nonisolated static func resourceBundleCandidates(
        mainResourceURL: URL?,
        mainBundleURL: URL?,
        finderResourceURL: URL?,
        finderBundleURL: URL?
    ) -> [URL] {
        var bases: [URL] = []
        // .app empacotado (make-app.sh copia para Contents/Resources).
        if let mainResourceURL { bases.append(mainResourceURL) }
        // Binário solto (`swift run`): o bundle fica ao lado do executável.
        if let mainBundleURL { bases.append(mainBundleURL) }
        // Módulo linkado dentro de outro bundle (ex.: .xctest).
        if let finderResourceURL { bases.append(finderResourceURL) }
        // Irmão do bundle que contém o módulo (`swift test` deixa o bundle
        // de recursos ao lado do .xctest em .build/debug).
        if let finderBundleURL { bases.append(finderBundleURL.deletingLastPathComponent()) }
        return bases.map { $0.appendingPathComponent(resourceBundleName) }
    }

    private static let resourceBundle: Bundle? = {
        let finder = Bundle(for: ProviderVisualBundleFinder.self)
        for url in resourceBundleCandidates(mainResourceURL: Bundle.main.resourceURL,
                                            mainBundleURL: Bundle.main.bundleURL,
                                            finderResourceURL: finder.resourceURL,
                                            finderBundleURL: finder.bundleURL) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()

    static func image(for provider: Provider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let name = provider == .claude ? "ClaudeSpark" : "OpenAIBlossom"
        guard let url = resourceBundle?.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[provider] = image
        return image
    }
}

struct ProviderIcon: View {
    let provider: Provider?
    var size: CGFloat = 16
    var fallbackSystemName: String = "terminal"

    var body: some View {
        Group {
            if let provider, let image = ProviderVisual.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
            } else {
                Image(systemName: fallbackSystemName)
                    .resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        // O ícone sempre acompanha um rótulo textual no app. Escondê-lo evita
        // anúncios duplicados e não fixa "Command" em inglês no VoiceOver.
        .accessibilityHidden(true)
    }
}

struct ProviderBadge: View {
    let provider: Provider?
    let title: String
    var fallbackSystemName: String = "terminal"

    var body: some View {
        HStack(spacing: 5) {
            ProviderIcon(provider: provider, size: 13,
                         fallbackSystemName: fallbackSystemName)
            Text(title)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
    }
}
