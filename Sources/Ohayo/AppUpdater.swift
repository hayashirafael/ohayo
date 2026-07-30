import Combine
import Foundation
import Sparkle

/// Ponte mínima entre o ciclo de atualização do Sparkle e a UI SwiftUI.
///
/// O updater só é iniciado no `.app` empacotado. Isso mantém `swift run` e os
/// testes utilizáveis, pois nesses contextos não há Info.plist nem bundle
/// instalável para o Sparkle substituir.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    init(isBundled: Bool = Bundle.main.bundleIdentifier != nil) {
        controller = SPUStandardUpdaterController(
            startingUpdater: isBundled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
