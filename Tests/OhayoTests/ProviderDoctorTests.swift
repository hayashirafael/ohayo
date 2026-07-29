import XCTest
@testable import Ohayo

final class ProviderDoctorTests: XCTestCase {
    func testContaNativaECustomGeramComandosDeLoginSemExecutaLos() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let nativeClaude = ProviderDoctorAccount(
            provider: .claude,
            configDirectory: home.appendingPathComponent(".claude"),
            displayName: "Claude padrão",
            homeDirectory: home
        )
        let customClaude = ProviderDoctorAccount(
            provider: .claude,
            configDirectory: URL(fileURLWithPath: "/tmp/claude d'empresa"),
            displayName: "Empresa",
            homeDirectory: home
        )
        let nativeCodex = ProviderDoctorAccount(
            provider: .codex,
            configDirectory: home.appendingPathComponent(".codex"),
            displayName: "Codex padrão",
            homeDirectory: home
        )

        XCTAssertEqual(nativeClaude.kind, .native)
        XCTAssertEqual(nativeClaude.loginCommand, "claude auth login")
        XCTAssertEqual(customClaude.kind, .custom)
        XCTAssertEqual(
            customClaude.loginCommand,
            "CLAUDE_CONFIG_DIR='/tmp/claude d'\\''empresa' claude auth login"
        )
        XCTAssertEqual(nativeCodex.kind, .native)
        XCTAssertEqual(
            nativeCodex.loginCommand,
            "CODEX_HOME='/Users/tester/.codex' codex login"
        )
    }

    func testProviderSemContaSondaCLIComoOpcionalSemSondarAuth() async {
        let locator = DoctorLocatorSpy(result: URL(fileURLWithPath: "/bin/claude"))
        let auth = DoctorAuthFake(defaultStatus: .authenticated)
        let inspector = SystemProviderDoctorInspector(
            binaryLocator: locator.locate,
            authenticationChecker: auth
        )

        let report = await inspector.inspect(provider: .claude, accounts: [])

        XCTAssertEqual(report.provider, .claude)
        XCTAssertEqual(report.configurationStatus, .optional)
        XCTAssertEqual(report.cliStatus, .available)
        XCTAssertEqual(report.accounts, [])
        XCTAssertEqual(locator.providers, [.claude])
        let authCalls = await auth.calls
        XCTAssertEqual(authCalls, [])
    }

    func testCLIAusenteFicaSeparadaDoAuthDaContaConfigurada() async {
        let home = URL(fileURLWithPath: "/Users/tester")
        let account = ProviderDoctorAccount(
            provider: .codex,
            configDirectory: home.appendingPathComponent(".codex"),
            displayName: "Padrão",
            homeDirectory: home
        )
        let auth = DoctorAuthFake(defaultStatus: .authenticated)
        let inspector = SystemProviderDoctorInspector(
            binaryLocator: { _ in nil },
            authenticationChecker: auth
        )

        let report = await inspector.inspect(provider: .codex, accounts: [account])

        XCTAssertEqual(report.configurationStatus, .configured)
        XCTAssertEqual(report.cliStatus, .missing)
        XCTAssertEqual(report.accounts.first?.authenticationStatus, .notChecked)
        let authCalls = await auth.calls
        XCTAssertEqual(authCalls, [])
    }

    func testCLIDisponivelDistingueTodosOsEstadosDeAuthPorConta() async {
        let home = URL(fileURLWithPath: "/Users/tester")
        let accounts = [
            ProviderDoctorAccount(
                provider: .claude,
                configDirectory: home.appendingPathComponent(".claude"),
                displayName: "Padrão",
                homeDirectory: home),
            ProviderDoctorAccount(
                provider: .claude,
                configDirectory: URL(fileURLWithPath: "/tmp/empresa"),
                displayName: "Empresa",
                homeDirectory: home),
            ProviderDoctorAccount(
                provider: .claude,
                configDirectory: URL(fileURLWithPath: "/tmp/laboratorio"),
                displayName: "Laboratório",
                homeDirectory: home),
        ]
        let auth = DoctorMappedAuthFake(statuses: [
            accounts[0].configDirectory.path: .authenticated,
            accounts[1].configDirectory.path: .unauthenticated(log: "not logged in"),
            accounts[2].configDirectory.path: .unknown,
        ])
        let inspector = SystemProviderDoctorInspector(
            binaryLocator: { _ in URL(fileURLWithPath: "/bin/claude") },
            authenticationChecker: auth
        )

        let report = await inspector.inspect(provider: .claude, accounts: accounts)

        XCTAssertEqual(report.cliStatus, .available)
        XCTAssertEqual(
            report.accounts.map(\.authenticationStatus),
            [.authenticated, .unauthenticated, .unknown]
        )
        let calls = await auth.calls
        XCTAssertEqual(calls, accounts.map(\.configDirectory.path))
    }

    @MainActor
    func testModelRefreshExplicitoVerificaOsDoisProvidersEPublicaRelatorios() async {
        let home = URL(fileURLWithPath: "/Users/tester")
        let claude = ProviderDoctorAccount(
            provider: .claude,
            configDirectory: home.appendingPathComponent(".claude"),
            displayName: "Padrão",
            homeDirectory: home
        )
        let inspector = DoctorInspectorFake()
        let model = ProviderDoctorModel(inspector: inspector)
        XCTAssertEqual(model.reports.map(\.cliStatus), [.checking, .checking])

        await model.refresh(accounts: [claude])

        XCTAssertEqual(model.report(for: .claude)?.cliStatus, .available)
        XCTAssertEqual(model.report(for: .claude)?.configurationStatus, .configured)
        XCTAssertEqual(model.report(for: .claude)?.accounts.first?.account, claude)
        XCTAssertEqual(model.report(for: .codex)?.configurationStatus, .optional)
        XCTAssertEqual(model.report(for: .codex)?.cliStatus, .available)
        XCTAssertFalse(model.isRefreshing)
        let calls = await inspector.calls
        XCTAssertEqual(calls, [
            "claude:/Users/tester/.claude",
            "codex:",
        ])
    }

    @MainActor
    func testModelVerificaProvidersEmParaleloEMantemOrdemEstavel() async {
        let inspector = DoctorConcurrencyInspector()
        let model = ProviderDoctorModel(inspector: inspector)

        await model.refresh(accounts: [])

        let maximumConcurrentInspections = await inspector.maximumConcurrentInspections
        XCTAssertEqual(maximumConcurrentInspections, 2)
        XCTAssertEqual(model.reports.map(\.provider), [.claude, .codex])
    }

    func testAlvosIncluemContaNativaSoComEvidenciaOuUsoEIncluemCustom() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let native = home.appendingPathComponent(".claude")
        let custom = URL(fileURLWithPath: "/tmp/empresa")

        let optional = ProviderDoctorAccounts.configured(
            provider: .claude,
            discoveredAccounts: [native],
            providerInUse: false,
            homeDirectory: home,
            fileExists: { _ in false },
            label: { $0.lastPathComponent }
        )
        XCTAssertEqual(optional, [])

        let configured = ProviderDoctorAccounts.configured(
            provider: .claude,
            discoveredAccounts: [native, custom],
            providerInUse: true,
            homeDirectory: home,
            fileExists: { _ in false },
            label: { $0.lastPathComponent }
        )
        XCTAssertEqual(configured.map(\.kind), [.native, .custom])
        XCTAssertEqual(configured.map(\.configDirectory), [native, custom])
    }

    func testDoctorDeduplicaDefaultSymlinkEAlvoReal() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ohayo-doctor-alias-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let real = root.appendingPathComponent("claude-real")
        let alias = home.appendingPathComponent(".claude")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: real.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? fm.removeItem(at: root) }

        let accounts = ProviderDoctorAccounts.configured(
            provider: .claude,
            discoveredAccounts: [alias, real],
            providerInUse: true,
            homeDirectory: home,
            fileExists: { _ in true },
            label: { $0.lastPathComponent }
        )

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(
            accounts.first?.configDirectory,
            ProviderAccountContext.canonicalAccountDirectory(real)
        )
        XCTAssertEqual(accounts.first?.kind, .native)
    }

    func testDoctorTemOrientacaoPassivaEStatusLocalizados() {
        let english = L10n(language: .english)
        XCTAssertEqual(english.providerDoctorTitle, "Claude & Codex readiness")
        XCTAssertEqual(
            english.providerDoctorIntro,
            "Checks only CLI installation and login status. It never runs a prompt, consumes quota, or signs in."
        )
        XCTAssertEqual(english.providerDoctorOptional, "Optional · not configured")
        XCTAssertEqual(english.providerDoctorCLIAvailable, "CLI installed")
        XCTAssertEqual(english.providerDoctorCLIMissing, "CLI not found")
        XCTAssertEqual(english.providerDoctorNativeAccount, "Native account")
        XCTAssertEqual(english.providerDoctorCustomAccount, "Custom account")
        XCTAssertEqual(english.providerDoctorAuthenticated, "Logged in")
        XCTAssertEqual(english.providerDoctorUnauthenticated, "Logged out")
        XCTAssertEqual(english.providerDoctorAuthUnknown, "Login status unknown")

        let portuguese = L10n(language: .portuguese)
        XCTAssertEqual(portuguese.providerDoctorTitle, "Prontidão do Claude e Codex")
        XCTAssertEqual(
            portuguese.providerDoctorIntro,
            "Verifica apenas a instalação das CLIs e o status de login. Nunca executa prompt, consome cota ou faz login."
        )
        XCTAssertEqual(portuguese.providerDoctorOptional, "Opcional · não configurado")
        XCTAssertEqual(portuguese.providerDoctorCLIAvailable, "CLI instalada")
        XCTAssertEqual(portuguese.providerDoctorCLIMissing, "CLI não encontrada")
        XCTAssertEqual(portuguese.providerDoctorNativeAccount, "Conta nativa")
        XCTAssertEqual(portuguese.providerDoctorCustomAccount, "Conta customizada")
        XCTAssertEqual(portuguese.providerDoctorAuthenticated, "Logada")
        XCTAssertEqual(portuguese.providerDoctorUnauthenticated, "Deslogada")
        XCTAssertEqual(portuguese.providerDoctorAuthUnknown, "Status de login desconhecido")
    }
}

private final class DoctorLocatorSpy {
    let result: URL?
    private(set) var providers: [Provider] = []

    init(result: URL?) { self.result = result }

    func locate(_ provider: Provider) -> URL? {
        providers.append(provider)
        return result
    }
}

private actor DoctorAuthFake: AuthenticationChecking {
    let defaultStatus: AuthenticationStatus
    private(set) var calls: [String] = []

    init(defaultStatus: AuthenticationStatus) {
        self.defaultStatus = defaultStatus
    }

    func status(
        for account: ProviderAccountContext
    ) async -> AuthenticationStatus {
        calls.append(
            "\(account.provider.rawValue):\(account.configDirectory.path)"
        )
        return defaultStatus
    }
}

private actor DoctorMappedAuthFake: AuthenticationChecking {
    let statuses: [String: AuthenticationStatus]
    private(set) var calls: [String] = []

    init(statuses: [String: AuthenticationStatus]) {
        self.statuses = statuses
    }

    func status(
        for account: ProviderAccountContext
    ) async -> AuthenticationStatus {
        calls.append(account.configDirectory.path)
        return statuses[account.configDirectory.path] ?? .unknown
    }
}

private actor DoctorInspectorFake: ProviderDoctorInspecting {
    private(set) var calls: [String] = []

    func inspect(
        provider: Provider,
        accounts: [ProviderDoctorAccount]
    ) async -> ProviderDoctorReport {
        calls.append(
            "\(provider.rawValue):\(accounts.map(\.configDirectory.path).joined(separator: ","))"
        )
        if accounts.isEmpty {
            return ProviderDoctorReport(
                provider: provider,
                configurationStatus: .optional,
                cliStatus: .available,
                accounts: []
            )
        }
        return ProviderDoctorReport(
            provider: provider,
            configurationStatus: .configured,
            cliStatus: .available,
            accounts: accounts.map {
                ProviderDoctorAccountReport(
                    account: $0,
                    authenticationStatus: .authenticated
                )
            }
        )
    }
}

private actor DoctorConcurrencyInspector: ProviderDoctorInspecting {
    private var activeInspections = 0
    private(set) var maximumConcurrentInspections = 0
    private var firstInspection: CheckedContinuation<Void, Never>?

    func inspect(
        provider: Provider,
        accounts: [ProviderDoctorAccount]
    ) async -> ProviderDoctorReport {
        activeInspections += 1
        maximumConcurrentInspections = max(
            maximumConcurrentInspections,
            activeInspections
        )
        if let firstInspection {
            self.firstInspection = nil
            firstInspection.resume()
        } else {
            await withCheckedContinuation {
                firstInspection = $0
            }
        }
        activeInspections -= 1
        return ProviderDoctorReport(
            provider: provider,
            configurationStatus: .optional,
            cliStatus: .available,
            accounts: []
        )
    }
}
