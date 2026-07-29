import SwiftUI
import AppKit

/// Seção Contas: identidade, provedor, pasta local, quantos agendamentos
/// ativos miram cada conta e o pausar/retomar por conta. Renovação e comandos
/// moram em Horários.
struct ContasView: View {
    @ObservedObject var state: AppState
    @State private var editingAlias: URL? = nil
    @State private var aliasDraft = ""
    @State private var invalidFolderAlert = false
    @State private var pendingRemoval: URL? = nil
    private var strings: L10n { state.strings }

    var body: some View {
        VStack(spacing: 0) {
            Text(strings.accountsSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            if state.discoverAccounts().isEmpty {
                emptyState
            } else {
                accountsForm
            }
        }
        .alert(strings.invalidFolderTitle, isPresented: $invalidFolderAlert) {
            Button(strings.ok, role: .cancel) {}
        } message: {
            Text(strings.invalidFolderMessage)
        }
        .confirmationDialog(
            pendingRemoval.map { strings.removeAccountConfirmationTitle(state.label(for: $0)) }
                ?? strings.removeAccountHelp,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { dir in
            Button(strings.removeAccount(state.label(for: dir)), role: .destructive) {
                state.unregisterAccount(dir)
                pendingRemoval = nil
            }
            Button(strings.cancel, role: .cancel) {}
        } message: { dir in
            Text(strings.removeAccountConfirmationBody(
                scheduleCount: affectedScheduleCount(for: dir)
            ))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(strings.noAccountsYet)
                .font(.headline)
            Text(strings.noAccountsDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                addAccount()
            } label: {
                Label(strings.addAccount, systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var accountsForm: some View {
        Form {
            ForEach(Provider.allCases, id: \.self) { provider in
                let accounts = state.accounts(for: provider)
                ForEach(accounts, id: \.self) { dir in
                    Section {
                        if state.cliFound[provider] == false {
                            Label(strings.installCLIForAccount(provider),
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !FileManager.default.fileExists(atPath: dir.path) {
                            Label(strings.accountFolderMissingAccountTab,
                                  systemImage: "questionmark.folder")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        header(dir)
                        LabeledContent(
                            strings.providerLabel,
                            value: state.provider(for: dir).displayName
                        )
                        LabeledContent(strings.folderLabel) {
                            Text((dir.path as NSString).abbreviatingWithTildeInPath)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                        Text(scheduleCountText(dir))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        if dir == accounts.first {
                            HStack(spacing: 6) {
                                ProviderIcon(provider: provider, size: 14)
                                Text(provider.displayName)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    addAccount()
                } label: {
                    Label(strings.addAccount, systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            } footer: {
                Text(strings.accountsFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Abre o NSOpenPanel para cadastrar uma conta; pasta sem assinatura → alerta.
    private func addAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true // ~/.claude2 e afins são pastas ocultas
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = strings.add
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if state.registerAccount(url) == nil { invalidFolderAlert = true }
    }

    @ViewBuilder
    private func header(_ dir: URL) -> some View {
        HStack(spacing: 9) {
            ProviderIcon(provider: state.provider(for: dir), size: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if editingAlias == dir {
                    TextField(strings.accountAlias, text: $aliasDraft, onCommit: { commitAlias(dir) })
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(state.label(for: dir))
                }
                if let email = state.email(for: dir), email != state.label(for: dir) {
                    Text(email).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.isPaused(dir) {
                Text(strings.pausedBadge)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            }
            Button {
                state.setPaused(dir, !state.isPaused(dir))
            } label: {
                Image(systemName: state.isPaused(dir) ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(state.isPaused(dir) ? strings.resumeAccount : strings.pauseAccount)
            .accessibilityLabel(
                "\(state.isPaused(dir) ? strings.resumeAccount : strings.pauseAccount): "
                    + state.label(for: dir)
            )
            Button {
                if editingAlias == dir { commitAlias(dir) }
                else { editingAlias = dir; aliasDraft = state.alias(for: dir) ?? "" }
            } label: {
                Image(systemName: editingAlias == dir ? "checkmark" : "pencil")
            }
            .buttonStyle(.plain)
            .help(
                editingAlias == dir
                    ? strings.saveAccountAlias(state.label(for: dir))
                    : strings.editAccountAlias(state.label(for: dir))
            )
            .accessibilityLabel(
                editingAlias == dir
                    ? strings.saveAccountAlias(state.label(for: dir))
                    : strings.editAccountAlias(state.label(for: dir))
            )
            if state.registeredAccounts.contains(dir.standardizedFileURL.path) {
                Button { pendingRemoval = dir } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help(strings.removeAccountHelp)
                .accessibilityLabel(strings.removeAccount(state.label(for: dir)))
            }
        }
    }

    private func scheduleCountText(_ dir: URL) -> String {
        strings.activeScheduleCount(state.activeScheduleCount(for: dir))
    }

    private func affectedScheduleCount(for dir: URL) -> Int {
        let target = ProviderAccountContext.canonicalAccountDirectory(dir)
        return state.tasks.filter {
            state.intendedAccountDir(for: $0) == target
        }.count
    }

    private func commitAlias(_ dir: URL) {
        state.setAlias(dir, aliasDraft)
        editingAlias = nil
    }
}
