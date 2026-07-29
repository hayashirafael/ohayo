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
/// há evidência de uma janela ativa; exclamação em erro; esmaecido quando
/// pausado. Texto opcional = janela ativa que vence primeiro.
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.strings.menuBarAccessibilityLabel))
        .accessibilityValue(Text(accessibilityStatus))
    }

    /// Somente uma janela detectada é evidência de uso ativo. Retries e
    /// cooldowns futuros não podem preencher o glifo.
    var soonestEnd: Date? {
        MenuBarLabelLogic.soonestActiveWindowEnd(
            in: state.renewalSnapshot,
            after: Date()
        )
    }

    var glyphState: MenuBarGlyph.State {
        .init(hasProblem: hasProblem, hasActiveWindow: soonestEnd != nil)
    }

    var hasProblem: Bool {
        let renewal = state.renewalSnapshot
        return !state.missingCLIs.isEmpty
            || lastEventFailed
            || (!state.allScheduledAccountsPaused
                && (!renewal.quotaUnavailableReasons.isEmpty
                    || !renewal.needsAttentionAccounts.isEmpty))
    }

    /// Valor falado pelo VoiceOver, com a mesma prioridade fail-closed usada
    /// pelo glifo. Mantido como propriedade testável para não deixar a
    /// acessibilidade divergir da apresentação visual.
    var accessibilityStatus: String {
        if let missing = state.missingCLIs.first {
            return state.strings.cliNotFound(missing)
        }
        if lastEventFailed {
            return state.strings.notificationFailureTitle
        }
        if state.allScheduledAccountsPaused {
            return state.strings.menuBarStatusPaused
        }
        if !state.renewalSnapshot.quotaUnavailableReasons.isEmpty {
            return state.strings.quotaUnavailable
        }
        if !state.renewalSnapshot.needsAttentionAccounts.isEmpty {
            return state.strings.needsAttention
        }
        if let end = soonestEnd {
            return state.strings.menuBarStatusActive(
                Fmt.remaining(until: end, from: Date())
            )
        }
        return state.strings.menuBarStatusIdle
    }

    private var lastEventFailed: Bool {
        if case .failure = state.lastEvent?.result { return true }
        return false
    }
}
