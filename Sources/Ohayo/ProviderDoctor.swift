import Combine
import Foundation
import SwiftUI

enum ProviderDoctorAccountKind: Equatable {
    case native
    case custom
}

/// Conta que o Doctor pode verificar sem executar prompt nem alterar login.
struct ProviderDoctorAccount: Equatable, Identifiable {
    let provider: Provider
    let configDirectory: URL
    let displayName: String
    let kind: ProviderDoctorAccountKind

    init(
        provider: Provider,
        configDirectory: URL,
        displayName: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let context = ProviderAccountContext(
            provider: provider,
            configDirectory: configDirectory,
            homeDirectory: homeDirectory
        )
        self.provider = provider
        self.configDirectory = context.configDirectory
        self.displayName = displayName
        self.kind = context.isNative ? .native : .custom
    }

    var id: String { "\(provider.rawValue):\(configDirectory.path)" }

    /// Comando mostrado para a pessoa copiar. O Doctor nunca o executa.
    var loginCommand: String {
        let command = provider == .claude ? "claude auth login" : "codex login"
        if provider == .claude, kind == .native { return command }
        return "\(provider.envKey)=\(Self.shellQuote(configDirectory.path)) \(command)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum ProviderDoctorAccounts {
    /// Contas que já possuem algum sinal de configuração. A conta nativa é
    /// omitida num Mac limpo, a menos que uma tarefa já use o provider; contas
    /// custom cadastradas continuam visíveis mesmo se a pasta estiver ausente.
    static func configured(
        provider: Provider,
        discoveredAccounts: [URL],
        providerInUse: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        },
        label: (URL) -> String
    ) -> [ProviderDoctorAccount] {
        let nativeContext = ProviderAccountContext(
            provider: provider,
            configDirectory: nil,
            homeDirectory: homeDirectory
        )
        var candidates = Set(discoveredAccounts.map {
            ProviderAccountContext.canonicalAccountDirectory($0)
        })
        candidates.insert(
            ProviderAccountContext.canonicalAccountDirectory(
                nativeContext.configDirectory
            )
        )

        return candidates.compactMap { directory -> ProviderDoctorAccount? in
            let context = ProviderAccountContext(
                provider: provider,
                configDirectory: directory,
                homeDirectory: homeDirectory
            )
            if context.isNative,
               !providerInUse,
               !fileExists(context.configDirectory),
               !fileExists(context.identityFile) {
                return nil
            }
            return ProviderDoctorAccount(
                provider: provider,
                configDirectory: context.configDirectory,
                displayName: label(context.configDirectory),
                homeDirectory: homeDirectory
            )
        }
        .sorted {
            if $0.kind != $1.kind { return $0.kind == .native }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }
}

enum ProviderDoctorCLIStatus: Equatable {
    case checking
    case missing
    case available
}

enum ProviderDoctorConfigurationStatus: Equatable {
    case configured
    case optional
}

enum ProviderDoctorAuthenticationStatus: Equatable {
    case notChecked
    case authenticated
    case unauthenticated
    case unknown
}

struct ProviderDoctorAccountReport: Equatable, Identifiable {
    let account: ProviderDoctorAccount
    let authenticationStatus: ProviderDoctorAuthenticationStatus
    var id: String { account.id }
}

struct ProviderDoctorReport: Equatable, Identifiable {
    let provider: Provider
    let configurationStatus: ProviderDoctorConfigurationStatus
    let cliStatus: ProviderDoctorCLIStatus
    let accounts: [ProviderDoctorAccountReport]
    var id: Provider { provider }
}

protocol ProviderDoctorInspecting {
    func inspect(
        provider: Provider,
        accounts: [ProviderDoctorAccount]
    ) async -> ProviderDoctorReport
}

/// Doctor de leitura: localiza a CLI e usa apenas o comando de status de auth
/// encapsulado em `AuthenticationChecking`. Não executa prompt nem login.
struct SystemProviderDoctorInspector: ProviderDoctorInspecting {
    var binaryLocator: (Provider) -> URL? = { CommandRunner.locate($0) }
    var authenticationChecker: AuthenticationChecking?

    func inspect(
        provider: Provider,
        accounts: [ProviderDoctorAccount]
    ) async -> ProviderDoctorReport {
        let accounts = accounts.filter { $0.provider == provider }
        let configurationStatus: ProviderDoctorConfigurationStatus =
            accounts.isEmpty ? .optional : .configured
        guard let binary = binaryLocator(provider) else {
            return ProviderDoctorReport(
                provider: provider,
                configurationStatus: configurationStatus,
                cliStatus: .missing,
                accounts: accounts.map {
                    ProviderDoctorAccountReport(
                        account: $0,
                        authenticationStatus: .notChecked
                    )
                }
            )
        }
        guard !accounts.isEmpty else {
            return ProviderDoctorReport(
                provider: provider,
                configurationStatus: .optional,
                cliStatus: .available,
                accounts: []
            )
        }
        let checker: AuthenticationChecking
        if let authenticationChecker {
            checker = authenticationChecker
        } else {
            checker = CLIAuthenticationChecker(binaryLocator: { _ in binary })
        }
        var reports: [ProviderDoctorAccountReport] = []
        for account in accounts {
            let authenticationStatus: ProviderDoctorAuthenticationStatus
            switch await checker.status(for: ProviderAccountContext(
                provider: provider,
                configDirectory: account.configDirectory
            )) {
            case .authenticated:
                authenticationStatus = .authenticated
            case .unauthenticated:
                authenticationStatus = .unauthenticated
            case .unknown:
                authenticationStatus = .unknown
            }
            reports.append(ProviderDoctorAccountReport(
                account: account,
                authenticationStatus: authenticationStatus
            ))
        }
        return ProviderDoctorReport(
            provider: provider,
            configurationStatus: .configured,
            cliStatus: .available,
            accounts: reports
        )
    }
}

@MainActor
final class ProviderDoctorModel: ObservableObject {
    @Published private(set) var reports: [ProviderDoctorReport]
    @Published private(set) var isRefreshing = false

    private let inspector: ProviderDoctorInspecting

    init(inspector: ProviderDoctorInspecting = SystemProviderDoctorInspector()) {
        self.inspector = inspector
        self.reports = Provider.allCases.map {
            ProviderDoctorReport(
                provider: $0,
                configurationStatus: .optional,
                cliStatus: .checking,
                accounts: []
            )
        }
    }

    func report(for provider: Provider) -> ProviderDoctorReport? {
        reports.first { $0.provider == provider }
    }

    func refresh(accounts: [ProviderDoctorAccount]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        reports = Provider.allCases.map {
            ProviderDoctorReport(
                provider: $0,
                configurationStatus: .optional,
                cliStatus: .checking,
                accounts: []
            )
        }

        let inspector = inspector
        let claudeAccounts = accounts.filter { $0.provider == .claude }
        let codexAccounts = accounts.filter { $0.provider == .codex }
        async let claudeReport = inspector.inspect(
            provider: .claude,
            accounts: claudeAccounts
        )
        async let codexReport = inspector.inspect(
            provider: .codex,
            accounts: codexAccounts
        )
        let refreshed = await (claudeReport, codexReport)
        reports = [refreshed.0, refreshed.1]
        isRefreshing = false
    }
}

@MainActor
struct ProviderDoctorView: View {
    @ObservedObject var model: ProviderDoctorModel
    let accounts: [ProviderDoctorAccount]
    let strings: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(strings.providerDoctorIntro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    Task { await model.refresh(accounts: accounts) }
                } label: {
                    Label(strings.providerDoctorRefresh, systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }

            ForEach(model.reports) { report in
                providerCard(report)
            }
        }
        .task {
            await model.refresh(accounts: accounts)
        }
    }

    private func providerCard(_ report: ProviderDoctorReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProviderIcon(provider: report.provider, size: 15)
                Text(report.provider.displayName).font(.headline)
                Spacer()
                if report.configurationStatus == .optional {
                    Text(strings.providerDoctorOptional)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch report.cliStatus {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(strings.providerDoctorChecking)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .missing:
                Label(strings.providerDoctorCLIMissing,
                      systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        report.configurationStatus == .configured ? .orange : .secondary)
                Text(strings.providerDoctorInstallGuidance(report.provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if report.configurationStatus == .configured {
                    ForEach(report.accounts) { accountReport in
                        accountRow(accountReport)
                    }
                }
            case .available:
                Label(strings.providerDoctorCLIAvailable,
                      systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                if report.configurationStatus == .optional {
                    Text(strings.providerDoctorNativeAccount)
                        .font(.caption.weight(.medium))
                    Text(strings.providerDoctorOptionalGuidance(report.provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    commandText(nativeLoginCommand(for: report.provider))
                } else {
                    ForEach(report.accounts) { accountReport in
                        accountRow(accountReport)
                    }
                }
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func accountRow(_ report: ProviderDoctorAccountReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(report.account.displayName)
                    Text(report.account.kind == .native
                         ? strings.providerDoctorNativeAccount
                         : strings.providerDoctorCustomAccount)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(authenticationLabel(report.authenticationStatus))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(authenticationColor(report.authenticationStatus))
            }
            switch report.authenticationStatus {
            case .unauthenticated:
                Text(strings.providerDoctorLoginGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                commandText(report.account.loginCommand)
            case .unknown:
                Text(strings.providerDoctorUnknownGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                commandText(report.account.loginCommand)
            case .authenticated, .notChecked:
                EmptyView()
            }
        }
        .padding(.leading, 4)
    }

    private func authenticationLabel(
        _ status: ProviderDoctorAuthenticationStatus
    ) -> String {
        switch status {
        case .notChecked: return strings.providerDoctorAuthNotChecked
        case .authenticated: return strings.providerDoctorAuthenticated
        case .unauthenticated: return strings.providerDoctorUnauthenticated
        case .unknown: return strings.providerDoctorAuthUnknown
        }
    }

    private func authenticationColor(
        _ status: ProviderDoctorAuthenticationStatus
    ) -> Color {
        switch status {
        case .authenticated: return .green
        case .unauthenticated: return .orange
        case .unknown, .notChecked: return .secondary
        }
    }

    private func nativeLoginCommand(for provider: Provider) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ProviderDoctorAccount(
            provider: provider,
            configDirectory: ProviderAccountContext.defaultConfigDirectory(
                for: provider,
                homeDirectory: home
            ),
            displayName: provider.displayName,
            homeDirectory: home
        ).loginCommand
    }

    private func commandText(_ command: String) -> some View {
        Text(command)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}
