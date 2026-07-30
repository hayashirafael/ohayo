import Combine
import Foundation
import Sparkle

@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var onUpdateAvailable: ((String) -> Void)? { get set }
    var onUpdateUnavailable: (() -> Void)? { get set }

    func checkForUpdates()
}

/// Adapta os callbacks do Sparkle para um contrato observável e testável.
@MainActor
private final class SparkleUpdateChecker: NSObject, UpdateChecking, SPUUpdaterDelegate {
    var onUpdateAvailable: ((String) -> Void)?
    var onUpdateUnavailable: (() -> Void)?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .eraseToAnyPublisher()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onUpdateAvailable?(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onUpdateUnavailable?()
    }

}

/// Ponte mínima entre o ciclo de atualização do Sparkle e a UI SwiftUI.
///
/// O updater só existe no perfil de produção. O canal de desenvolvimento
/// mantém o framework para link/carregamento, mas não cria nem consulta o
/// controller do Sparkle.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    let isSupported: Bool

    private let checker: UpdateChecking?
    private var cancellable: AnyCancellable?

    init(profile: AppRuntimeProfile = .current) {
        isSupported = profile.supportsAppUpdates
        guard isSupported else {
            checker = nil
            return
        }

        let checker = SparkleUpdateChecker()
        self.checker = checker
        observe(checker)
    }

    init(checker: UpdateChecking) {
        isSupported = true
        self.checker = checker
        observe(checker)
    }

    private func observe(_ checker: UpdateChecking) {
        canCheckForUpdates = checker.canCheckForUpdates
        checker.onUpdateAvailable = { [weak self] version in
            self?.availableVersion = version
        }
        checker.onUpdateUnavailable = { [weak self] in
            self?.availableVersion = nil
        }
        cancellable = checker.canCheckForUpdatesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let checker else { return }
        checker.checkForUpdates()
    }

    func installAvailableUpdate() {
        guard availableVersion != nil else { return }
        checkForUpdates()
    }
}
