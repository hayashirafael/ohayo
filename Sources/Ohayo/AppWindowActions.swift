import AppKit

/// Coordena a transição do painel transitório da barra para uma janela normal.
@MainActor
enum AppWindowActions {
    static func presentWindow(
        closePanel: @escaping @MainActor () -> Void,
        openWindow: @escaping @MainActor () -> Void
    ) {
        presentWindow(
            closePanel: closePanel,
            prepareForPresentation: {
                WindowActivationCoordinator.shared.prepareForPresentation()
            },
            openWindow: openWindow,
            deferToNextRunLoop: { action in
                DispatchQueue.main.async {
                    action()
                }
            },
            activate: {
                NSRunningApplication.current.activate(
                    options: [.activateIgnoringOtherApps]
                )
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }

    static func presentWindow(
        closePanel: @escaping @MainActor () -> Void,
        prepareForPresentation: @escaping @MainActor () -> Void,
        openWindow: @escaping @MainActor () -> Void,
        deferToNextRunLoop: (@escaping @MainActor () -> Void) -> Void,
        activate: @escaping @MainActor () -> Void
    ) {
        // O MenuBarExtra mantém uma janela transitória que pode recuperar o
        // foco se outra janela for ativada antes de ele fechar.
        closePanel()
        prepareForPresentation()
        openWindow()

        // SwiftUI materializa/reexibe Window(id:) durante a atualização da
        // cena. Ative o app depois disso para que a janela vire key e apareça
        // à frente, inclusive quando o clique partiu de outro aplicativo.
        deferToNextRunLoop {
            activate()
        }
    }
}

/// Um app `LSUIElement` precisa adotar a política regular para o macOS permitir
/// que suas janelas recebam foco. O ícone no Dock só permanece enquanto alguma
/// janela normal do Ohayo estiver aberta.
@MainActor
private final class WindowActivationCoordinator: NSObject {
    static let shared = WindowActivationCoordinator()

    private var isObservingWindowClosures = false

    func prepareForPresentation() {
        if !isObservingWindowClosures {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: nil
            )
            isObservingWindowClosures = true
        }

        NSApp.setActivationPolicy(.regular)
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.styleMask.contains(.titled),
              !window.className.contains("MenuBarExtraWindow")
        else {
            return
        }

        DispatchQueue.main.async {
            let hasVisibleNormalWindow = NSApp.windows.contains {
                $0.isVisible
                    && $0.styleMask.contains(.titled)
                    && !$0.className.contains("MenuBarExtraWindow")
            }

            if !hasVisibleNormalWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
