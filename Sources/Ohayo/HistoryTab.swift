import SwiftUI

struct HistoryTab: View {
    @ObservedObject var state: AppState
    @State private var showsClearConfirmation = false
    private var strings: L10n { state.strings }

    var body: some View {
        Group {
            if state.history.isEmpty { emptyState } else { historyList }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            strings.clearHistoryConfirmationTitle,
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(strings.clearHistoryAction, role: .destructive) {
                state.clearHistory()
            }
        } message: {
            Text(strings.clearHistoryConfirmationBody)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(strings.noHistory).font(.headline)
            Text(strings.noHistoryDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(40)
    }

    /// Eventos visíveis após o filtro de conta (deep-link do painel).
    private var visibleHistory: [FireEvent] {
        state.history.filter { state.matchesFilter($0) }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HStack {
                    if let filter = state.accountFilter {
                        HStack(spacing: 5) {
                            Label(strings.filteredBy(state.label(for: filter)),
                                  systemImage: "line.3.horizontal.decrease.circle")
                                .font(.caption)
                            Button { state.accountFilter = nil } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .help(strings.clearFilter)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label(strings.clearHistory, systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.bottom, 2)
                ForEach(Array(visibleHistory.enumerated()), id: \.offset) { _, event in
                    card(event)
                }
                Text(strings.historyFooter(limit: AppState.historyLimit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            .padding(16)
        }
    }

    private func card(_ event: FireEvent) -> some View {
        let identity = state.identity(for: event)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                providerMark(identity)
                identityHeader(identity)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    statusBadge(event)
                    Text(Fmt.dayTime(event.date, language: state.language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text(event.messageText ?? strings.historyUnknownCommand)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(resultDetail(event))
                .font(.caption)
                .foregroundStyle(statusColor(event))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                providerBadge(identity)
                if let model = modelLabel(identity) {
                    badge(model, systemImage: "cpu")
                }
                if let origin = event.origin, let label = strings.origin(origin) {
                    badge(label, systemImage: origin == .renewal
                          ? "arrow.triangle.2.circlepath" : "calendar")
                }
            }

            if let response = event.response, !response.isEmpty {
                DisclosureGroup(responseTitle(event)) {
                    Text(response)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                }
                .font(.caption)
            }
        }
        .padding(13)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }

    private func providerMark(_ identity: EventIdentity) -> some View {
        ProviderIcon(provider: identity.provider, size: 21,
                     fallbackSystemName: identity.accountName == nil ? "terminal" : "questionmark")
            .frame(width: 34, height: 34)
            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func identityHeader(_ identity: EventIdentity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(identity.displayName ?? (identity.accountName == nil
                 ? strings.command : strings.historyUnknownAccount))
                .font(.headline)
                .lineLimit(1)
            if let email = identity.email, email != identity.displayName {
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
    }

    private func providerBadge(_ identity: EventIdentity) -> some View {
        let title: String
        let fallback: String
        if let provider = identity.provider {
            title = provider.displayName
            fallback = "questionmark"
        } else if identity.accountName == nil {
            title = strings.command
            fallback = "terminal"
        } else {
            title = strings.historyUnknownProvider
            fallback = "questionmark"
        }
        return ProviderBadge(provider: identity.provider, title: title,
                             fallbackSystemName: fallback)
    }

    private func modelLabel(_ identity: EventIdentity) -> String? {
        if let model = identity.modelName { return model }
        return identity.provider == .codex ? strings.historyAccountDefaultModel : nil
    }

    private func badge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.12), in: Capsule())
    }

    private func statusBadge(_ event: FireEvent) -> some View {
        Label(statusTitle(event), systemImage: statusSymbol(event))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor(event))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor(event).opacity(0.12), in: Capsule())
    }

    private func statusTitle(_ event: FireEvent) -> String {
        switch event.result {
        case .success: return strings.historySuccess
        case .launched: return strings.historyLaunched
        case .failure: return strings.historyFailure
        case .skipped: return strings.historySkipped
        case .missed: return strings.historyMissed
        }
    }

    private func statusSymbol(_ event: FireEvent) -> String {
        switch event.result {
        case .success: return "checkmark.circle.fill"
        case .launched: return "terminal.fill"
        case .failure: return "xmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle.fill"
        case .missed: return "moon.zzz.fill"
        }
    }

    private func statusColor(_ event: FireEvent) -> Color {
        switch event.result {
        case .success: return .green
        case .launched: return .blue
        case .failure: return .red
        case .skipped: return .secondary
        case .missed: return .orange
        }
    }

    private func resultDetail(_ event: FireEvent) -> String {
        switch event.result {
        case .success:
            return strings.historyExecutedSuccessfully
        case .launched:
            return strings.historyTerminalLaunched
        case .failure(let message):
            return message
        case .skipped(let until):
            return strings.historyWindowActive(
                until: Fmt.hhmm(until, language: state.language))
        case .missed(let occurrence):
            return strings.historyMissedOccurrence(
                Fmt.dayTime(occurrence, language: state.language))
        }
    }

    private func responseTitle(_ event: FireEvent) -> String {
        if case .failure = event.result { return strings.historyDetails }
        return strings.historyResponse
    }
}
