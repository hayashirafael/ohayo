import Combine
import Foundation
import Sparkle

/// Ponte mínima entre o ciclo de atualização do Sparkle e a UI SwiftUI.
///
/// O updater só existe no perfil de produção. O canal de desenvolvimento
/// mantém o framework para link/carregamento, mas não cria nem consulta o
/// controller do Sparkle.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    let isSupported: Bool

    private let controller: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    init(profile: AppRuntimeProfile = .current) {
        isSupported = profile.supportsAppUpdates
        guard isSupported else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller

        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let controller else { return }
        controller.checkForUpdates(nil)
    }
}
