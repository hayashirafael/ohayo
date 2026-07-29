import SwiftUI

enum MenuBarLabelLogic {
    static func soonestActiveWindowEnd(
        in snapshot: RenewalSnapshot,
        after now: Date
    ) -> Date? {
        snapshot.byTask.values.compactMap { entry in
            guard case .scheduled(let end) = entry.phase,
                  end > now else {
                return nil
            }
            return end
        }.min()
    }
}

/// Label da barra: glifo próprio (balão + arco de renovação) preenchido quando
/// qualquer conta está com janela ativa; exclamação em erro; esmaecido quando
/// pausado. Texto opcional = janela que vence primeiro entre as contas em
/// renovação.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image(for: glyphState))
                .opacity(state.allScheduledAccountsPaused && !hasProblem ? 0.5 : 1)
            if state.showRemainingInBar, let end = soonestEnd {
                // monospacedDigit: sem isso a largura oscila conforme os dígitos
                // do tempo restante mudam (jitter na barra a cada minuto).
                Text(Fmt.remaining(until: end, from: Date()))
                    .monospacedDigit()
            }
        }
    }

    private var soonestEnd: Date? {
        MenuBarLabelLogic.soonestActiveWindowEnd(
            in: state.renewalSnapshot,
            after: Date()
        )
    }

    private var glyphState: MenuBarGlyph.State {
        .init(hasProblem: hasProblem, hasActiveWindow: soonestEnd != nil)
    }

    private var hasProblem: Bool { !state.missingCLIs.isEmpty || lastEventFailed }

    private var lastEventFailed: Bool {
        if case .failure = state.lastEvent?.result { return true }
        return false
    }
}
