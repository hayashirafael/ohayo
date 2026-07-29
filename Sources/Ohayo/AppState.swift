import Foundation

@MainActor
final class AppState: ObservableObject {
    /// Contas pausadas (path canônico). O pause é por conta e remove seus
    /// agendamentos dos engines; o FireController mantém um segundo guard para
    /// cobrir corridas com um disparo que já estava em andamento.
    @Published var pausedAccounts: Set<String> {
        didSet { defaults.set(Array(pausedAccounts), forKey: Keys.pausedAccounts) }
    }

    func isPaused(_ dir: URL) -> Bool {
        pausedAccounts.contains(
            ProviderAccountContext.canonicalAccountDirectory(dir).path
        )
    }

    func setPaused(_ dir: URL, _ on: Bool) {
        let key = ProviderAccountContext.canonicalAccountDirectory(dir).path
        if on { pausedAccounts.insert(key) } else { pausedAccounts.remove(key) }
    }

    /// Todas as contas agendadas pausadas (e existe ao menos uma) — esmaece o
    /// glifo da barra.
    var allScheduledAccountsPaused: Bool {
        let dirs = Set(
            tasks.filter(\.enabled).compactMap {
                intendedAccountDir(for: $0)
            }
        )
        return !dirs.isEmpty && dirs.allSatisfy { isPaused($0) }
    }

    static let historyLimit = 20

    @Published var history: [FireEvent] {
        didSet {
            if history.count > Self.historyLimit {
                history = Array(history.prefix(Self.historyLimit)) // didSet re-dispara e persiste
                return
            }
            defaults.set(try? JSONEncoder().encode(history), forKey: Keys.history)
        }
    }

    /// Último disparo — cabeçalho do menu.
    var lastEvent: FireEvent? { history.first }

    func recordEvent(_ event: FireEvent) {
        history.insert(event, at: 0)
        // Um disparo registrado também é sinal de vida: fecha a janela de até
        // 60s entre o último tick do heartbeat e um quit logo após o disparo
        // (evita falso "perdido" de ocorrência que na verdade executou).
        recordAlive(now: event.date)
    }

    /// Remove o histórico local e o blob persistido. Credenciais e
    /// agendamentos não são afetados.
    func clearHistory() {
        history.removeAll()
    }

    /// Cria um evento com um snapshot mínimo da identidade. A UI prefere os
    /// dados atuais da conta e usa o snapshot quando ela não existe mais.
    func makeEvent(date: Date, result: FireResult, message: Message,
                   origin: FireOrigin, response: String? = nil) -> FireEvent {
        let provider: Provider?
        let accountDir: URL?
        let modelName: String?
        switch message.kind {
        case .claude:
            provider = .claude
            accountDir = explicitOrDefaultAccount(for: message, provider: .claude)
            modelName = message.resolvedModel.label
        case .codex:
            provider = .codex
            accountDir = explicitOrDefaultAccount(for: message, provider: .codex)
            let model = message.codexModel?.trimmingCharacters(in: .whitespacesAndNewlines)
            modelName = model?.isEmpty == false ? model : nil
        case .shell:
            provider = nil
            accountDir = nil
            modelName = nil
        }
        return FireEvent(
            date: date, result: result, messageText: message.text,
            account: accountDir?.lastPathComponent, origin: origin, response: response,
            accountPath: accountDir?.standardizedFileURL.path, provider: provider,
            modelName: modelName,
            aliasSnapshot: accountDir.flatMap { alias(for: $0) },
            emailSnapshot: accountDir.flatMap { email(for: $0) }
        )
    }

    /// Identidade atual do evento, com fallback para o snapshot persistido.
    func identity(for event: FireEvent) -> EventIdentity {
        let dir = accountDir(for: event)
        let currentAlias = dir.flatMap { alias(for: $0) }
        let currentEmail = dir.flatMap { email(for: $0) }
        return EventIdentity(
            accountName: dir?.lastPathComponent ?? event.account,
            alias: currentAlias ?? event.aliasSnapshot,
            email: currentEmail ?? event.emailSnapshot,
            provider: event.provider ?? dir.map { provider(for: $0) },
            modelName: event.modelName
        )
    }

    private func explicitOrDefaultAccount(for message: Message, provider: Provider) -> URL {
        if let path = message.configDir, !path.isEmpty {
            return ProviderAccountContext.canonicalAccountDirectory(
                URL(fileURLWithPath: path)
            )
        }
        return ProviderAccountContext.canonicalAccountDirectory(
            defaultConfigDirectory(for: provider)
        )
    }

    private func defaultConfigDirectory(for provider: Provider) -> URL {
        ProviderAccountContext.defaultConfigDirectory(
            for: provider,
            homeDirectory: homeDirectory
        )
    }

    private func accountDir(for event: FireEvent) -> URL? {
        if let path = event.accountPath, !path.isEmpty {
            return ProviderAccountContext.canonicalAccountDirectory(
                URL(fileURLWithPath: path)
            )
        }
        return nil
    }

    /// Momento em que o app esteve vivo pela última vez ANTES deste launch;
    /// nil no primeiro launch de todos. Consumido (uma vez) por
    /// `recordMissedWhileClosed`.
    private(set) var previousAliveAt: Date?

    /// Heartbeat de vida do app — o AppEnvironment chama a cada statusTick.
    /// Não é @Published de propósito: nada na UI observa, e publicar a cada
    /// 60s re-renderizaria o menu à toa.
    func recordAlive(now: Date = Date()) {
        defaults.set(now, forKey: Keys.lastAliveAt)
    }

    /// Registra no histórico, no máximo uma vez por tarefa por launch, a
    /// última ocorrência fixa perdida enquanto o app esteve fechado. Não
    /// dispara nada — decisão de produto: catch-up retroativo entre launches
    /// seria rajada indesejada; o usuário só precisa saber o que não rodou.
    func recordMissedWhileClosed(now: Date = Date(), calendar: Calendar = .current) {
        guard let since = previousAliveAt else { return }
        previousAliveAt = nil // idempotente: um relatório por launch
        for task in tasks where task.enabled && task.repetition == .fixed {
            guard let occurrence = AgendaMath.lastMissedOccurrence(
                times: task.times, weekdays: task.weekdays,
                between: since, and: now, calendar: calendar) else { continue }
            recordEvent(makeEvent(date: now, result: .missed(occurrence: occurrence),
                                  message: task.resolvedCommand, origin: .agenda))
        }
    }

    /// CLI encontrado por provider. Começa true para o ícone de erro não piscar
    /// enquanto a sonda de launch resolve.
    @Published var cliFound: [Provider: Bool] = [.claude: true, .codex: true]

    /// CLIs ausentes que importam: somente providers com conta descoberta ou
    /// com algum agendamento habilitado. Um usuário Codex/shell não recebe um
    /// alerta de instalação do Claude sem nunca tê-lo configurado.
    var missingCLIs: [Provider] {
        Provider.allCases.filter { p in
            guard cliFound[p] == false else { return false }
            let expectedKind: Message.Kind = p == .claude ? .claude : .codex
            let usedByTask = tasks.contains {
                $0.enabled && $0.resolvedCommand.kind == expectedKind
            }
            let hasAccount = discoverAccounts().contains { provider(for: $0) == p }
            return usedByTask || hasAccount
        }
    }

    /// Pulso periódico de UI: o menu exibe horários calculados com `Date()` em
    /// computed properties (`nextTaskEntry`, `nextFire`, `remaining`), que só
    /// reexecutam quando algum `@Published` muta e dispara `objectWillChange`.
    /// O `statusTick` do AppEnvironment incrementa este contador a cada ciclo
    /// para forçar o menu/barra a recomputar contra o tempo atual, mesmo quando
    /// nenhum disparo real aconteceu.
    @Published private(set) var uiHeartbeat: Int = 0

    func pulseUI() { uiHeartbeat &+= 1 }

    /// Próximos disparos por tarefa (espelho do TaskScheduler, para a UI).
    @Published var nextTaskFires: [UUID: Date] = [:]

    /// Próxima tarefa a disparar (para o menu da barra).
    var nextTaskEntry: (task: ScheduledTask, date: Date)? {
        let future = nextTaskFires.filter { $0.value > Date() }
        guard let entry = future.min(by: { $0.value < $1.value }),
              let task = tasks.first(where: { $0.uid == entry.key }) else { return nil }
        return (task, entry.value)
    }

    /// Mostrar o tempo restante da janela ("3h12") ao lado do ícone da barra.
    @Published var showRemainingInBar: Bool {
        didSet { defaults.set(showRemainingInBar, forKey: Keys.showRemainingInBar) }
    }

    /// Conteúdo de prompts, respostas, erros e contas pode aparecer na tela
    /// bloqueada. O default é privado; a pessoa precisa optar pelos detalhes.
    @Published var showSensitiveNotificationDetails: Bool {
        didSet {
            defaults.set(
                showSensitiveNotificationDetails,
                forKey: Keys.showSensitiveNotificationDetails
            )
        }
    }

    /// Quantos próximos disparos o painel do menu mostra (1–5, padrão 1).
    @Published var panelUpcomingCount: Int {
        didSet { defaults.set(panelUpcomingCount, forKey: Keys.panelUpcomingCount) }
    }

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published private(set) var hasDismissedPermissionGuide: Bool

    func dismissPermissionGuide() {
        hasDismissedPermissionGuide = true
        defaults.set(true, forKey: Keys.hasDismissedPermissionGuide)
    }

    var strings: L10n { L10n(language: language) }

    /// Seção selecionada na janela de Configurações (deep-link a partir do menu).
    @Published var settingsSection: SettingsSection = .horarios

    /// Filtro de conta para as abas Tarefas/Histórico (deep-link do painel).
    @Published var accountFilter: URL?

    /// Pedido efêmero para apresentar o formulário de novo Agendamento após
    /// um deep-link (por exemplo, o CTA do painel da barra).
    @Published var newScheduleRequest: UUID?

    func matchesFilter(_ event: FireEvent) -> Bool {
        guard let filter = accountFilter else { return true }
        if let path = event.accountPath {
            return ProviderAccountContext.canonicalAccountDirectory(
                URL(fileURLWithPath: path)
            ) == ProviderAccountContext.canonicalAccountDirectory(filter)
        }
        return event.account == filter.lastPathComponent
    }

    func taskMatchesFilter(_ task: ScheduledTask) -> Bool {
        guard let filter = accountFilter else { return true }
        return intendedAccountDir(for: task)
            == ProviderAccountContext.canonicalAccountDirectory(filter)
    }

    // nonisolated: valores imutáveis usados fora do ator (ex.:
    // `ScheduledTask.resolvedCommand`, que é um tipo não-isolado).
    nonisolated static let defaultMessage = Message(
        text: "1+1", kind: .claude,
        uid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    /// Hi mínimo Codex — análogo ao defaultMessage, para contas Codex.
    nonisolated static let defaultCodexMessage = Message(
        text: "1+1", kind: .codex,
        uid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    /// Hi padrão embutido do provider (o "1+1" de cada mundo).
    static func defaultHi(for provider: Provider) -> Message {
        provider == .codex ? defaultCodexMessage : defaultMessage
    }

    /// Agendamentos (seção Horários) — a lista unificada.
    @Published var tasks: [ScheduledTask] {
        didSet {
            defaults.set(try? JSONEncoder().encode(tasks), forKey: Keys.tasks)
            var live: [String: ScheduledTask] = [:]
            for task in tasks {
                if let key = continuousKey(for: task), live[key] == nil {
                    live[key] = task
                }
            }
            var oldByUID: [UUID: ScheduledTask] = [:]
            for task in oldValue where oldByUID[task.uid] == nil {
                oldByUID[task.uid] = task
            }
            renewalRecoveryStates = renewalRecoveryStates.filter { key, state in
                guard let task = live[key] else { return false }
                if state.bootstrapOrigin,
                   !task.resolvedBootstrapWhenInactive {
                    return false
                }
                // Uma edição explícita é a oportunidade de corrigir um estado
                // needs-attention/retry. Não carrega o bloqueio para um payload
                // que a pessoa acabou de alterar.
                if let previous = oldByUID[task.uid],
                   previous.renewalRevision != task.renewalRevision {
                    // Cooldown não é outcome da revisão anterior: é uma lease
                    // conservadora de que um hand-off pode já ter chegado ao
                    // CLI. Na mesma UID/conta ela precisa sobreviver à edição
                    // para não duplicar o disparo após restart.
                    if case .cooldown = state {
                        return true
                    }
                    return false
                }
                return true
            }
        }
    }

    /// Janela da persistência legada de tentativas de bootstrap. Mantida
    /// somente para migrar o blob antigo ao recovery tipado.
    private static let legacyBootstrapCooldown: TimeInterval = 5 * 3600

    private var renewalRecoveryStates: [String: RenewalRecoveryState] {
        didSet {
            defaults.set(
                try? JSONEncoder().encode(renewalRecoveryStates),
                forKey: Keys.renewalRecoveryStates
            )
        }
    }

    func renewalRecoveryState(
        for task: ScheduledTask
    ) -> RenewalRecoveryState? {
        guard let key = continuousKey(for: task) else { return nil }
        return renewalRecoveryStates[key]
    }

    func setRenewalRecoveryState(
        _ recovery: RenewalRecoveryState?,
        for task: ScheduledTask
    ) {
        guard let key = continuousKey(for: task) else { return }
        if let recovery,
           recovery.bootstrapOrigin,
           !task.resolvedBootstrapWhenInactive {
            renewalRecoveryStates[key] = nil
            return
        }
        renewalRecoveryStates[key] = recovery
    }

    private func continuousKey(for task: ScheduledTask) -> String? {
        guard task.enabled,
              task.repetition == .continuous else {
            return nil
        }
        // Recovery acompanha o alvo pretendido mesmo se um volume custom
        // estiver temporariamente offline. A elegibilidade de execução segue
        // usando `accountDir(for:)`, que corretamente exige a pasta presente.
        guard let account = intendedAccountDir(for: task) else { return nil }
        return "\(task.uid.uuidString)|\(ProviderAccountContext.canonicalAccountDirectory(account).path)"
    }

    /// Diretório de config padrão do Claude Code (`~/.claude`).
    static var defaultConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// Diretório de config padrão do Codex (`~/.codex`).
    static var defaultCodexConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Cache de sessão do provider por conta (detect toca o disco; UI re-renderiza).
    private var providerCache: [String: Provider] = [:]

    /// Provider persistido de contas custom. Sem isso, uma conta Codex cuja
    /// pasta sumiu seria reinterpretada como Claude no próximo launch.
    private var registeredAccountProviders: [String: String] = [:] {
        didSet {
            defaults.set(registeredAccountProviders, forKey: Keys.registeredAccountProviders)
        }
    }

    /// Provider da conta pela assinatura do conteúdo, depois pelo cadastro
    /// persistido. O fallback só vale para uma pasta realmente desconhecida.
    func provider(for dir: URL) -> Provider {
        let canonical = ProviderAccountContext.canonicalAccountDirectory(dir)
        let key = canonical.path
        if let cached = providerCache[key] { return cached }
        if let raw = registeredAccountProviders[key],
           let persisted = Provider(rawValue: raw) {
            providerCache[key] = persisted
            return persisted
        }
        if let detected = Provider.detect(at: canonical) {
            providerCache[key] = detected
            if registeredAccounts.contains(key),
               registeredAccountProviders[key] != detected.rawValue {
                registeredAccountProviders[key] = detected.rawValue
            }
            return detected
        }
        let nativeCodex = ProviderAccountContext.canonicalAccountDirectory(
            ProviderAccountContext.defaultConfigDirectory(
                for: .codex,
                homeDirectory: homeDirectory
            )
        ).path
        let value: Provider = key == nativeCodex ? .codex : .claude
        providerCache[key] = value
        return value
    }

    /// Contas cadastradas pelo usuário (paths padronizados). Os defaults
    /// (~/.claude, ~/.codex) nunca entram aqui — são auto-detectados.
    @Published var registeredAccounts: [String] {
        didSet { defaults.set(registeredAccounts, forKey: Keys.registeredAccounts) }
    }

    /// Contas exibidas: defaults somente quando existem; cadastradas sempre
    /// (se a pasta sumiu, a UI avisa em vez de esconder). Ordenado por provider
    /// (Claude primeiro) e rótulo.
    func discoverAccounts() -> [URL] {
        let claudeDefault = ProviderAccountContext.canonicalAccountDirectory(
            ProviderAccountContext.defaultConfigDirectory(
                for: .claude, homeDirectory: homeDirectory
            )
        )
        let codexDefault = ProviderAccountContext.canonicalAccountDirectory(
            ProviderAccountContext.defaultConfigDirectory(
                for: .codex, homeDirectory: homeDirectory
            )
        )
        var found: Set<URL> = []
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: claudeDefault.path, isDirectory: &isDirectory
        ), isDirectory.boolValue {
            found.insert(claudeDefault)
        }
        if Provider.detect(at: codexDefault) == .codex {
            found.insert(codexDefault)
        }
        for path in registeredAccounts {
            found.insert(ProviderAccountContext.canonicalAccountDirectory(
                URL(fileURLWithPath: path)
            ))
        }
        return found.sorted { a, b in
            let (pa, pb) = (provider(for: a), provider(for: b))
            if pa != pb { return pa == .claude } // Claude primeiro
            return label(for: a).localizedCaseInsensitiveCompare(label(for: b)) == .orderedAscending
        }
    }

    /// Descoberta única do primeiro launch: perfis Claude adicionais pela
    /// convenção `~/.claude*` que já tenham `projects/`. O resultado é
    /// persistido em `registeredAccounts`; launches posteriores não revarrem o
    /// home e contas removidas continuam visíveis para diagnóstico.
    private static func initialClaudeAccountScan(home: URL) -> [String] {
        let fm = FileManager.default
        let native = ProviderAccountContext.canonicalAccountDirectory(
            home.appendingPathComponent(".claude")
        )
        guard let names = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }
        var discovered: Set<URL> = []
        for name in names.sorted() {
            guard name.hasPrefix(".claude") else { continue }
            let directory = ProviderAccountContext.canonicalAccountDirectory(
                home.appendingPathComponent(name)
            )
            guard directory != native else { continue }
            var isDirectory: ObjCBool = false
            let projects = directory.appendingPathComponent("projects")
            guard fm.fileExists(atPath: projects.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            discovered.insert(directory)
        }
        return discovered.map(\.path).sorted()
    }

    /// Contas de um provider, na ordem de discoverAccounts.
    func accounts(for provider: Provider) -> [URL] {
        discoverAccounts().filter { self.provider(for: $0) == provider }
    }

    /// Cadastra uma pasta de conta apontada pelo usuário. Retorna o provider
    /// inferido pela assinatura, ou nil (pasta inválida — nada é persistido).
    @discardableResult
    func registerAccount(_ dir: URL) -> Provider? {
        let canonical = ProviderAccountContext.canonicalAccountDirectory(dir)
        guard let detected = Provider.detect(at: canonical) else { return nil }
        let key = canonical.path
        providerCache[key] = detected
        let defaultPaths = Set(Provider.allCases.map {
            ProviderAccountContext.canonicalAccountDirectory(
                ProviderAccountContext.defaultConfigDirectory(
                    for: $0,
                    homeDirectory: homeDirectory
                )
            ).path
        })
        if !registeredAccounts.contains(key), !defaultPaths.contains(key) {
            registeredAccounts.append(key)
            registeredAccountProviders[key] = detected.rawValue
        }
        return detected
    }

    /// Remove uma conta cadastrada da lista — não toca o disco; limpa o
    /// apelido e desabilita os agendamentos que miravam a conta.
    func unregisterAccount(_ dir: URL) {
        let key = ProviderAccountContext.canonicalAccountDirectory(dir).path
        registeredAccounts.removeAll { $0 == key }
        registeredAccountProviders[key] = nil
        providerCache[key] = nil
        aliases[key] = nil
        AgendamentoEditor(state: self).apply(
            .disableAccount(URL(fileURLWithPath: key))
        )
    }

    /// Apelido opcional por conta (chave = path padronizado). Independente da
    /// renovação estar ligada.
    @Published var aliases: [String: String] {
        didSet { defaults.set(aliases, forKey: Keys.aliases) }
    }

    /// Conta que um agendamento mira: o configDir do comando (se a pasta ainda
    /// existe), senão a conta padrão do provider. nil para shell (não mira
    /// conta) e para configDir cuja pasta sumiu (a UI avisa; nada dispara).
    func accountDir(for task: ScheduledTask) -> URL? {
        let cmd = task.resolvedCommand
        guard cmd.kind != .shell else { return nil }
        if let path = cmd.configDir, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return ProviderAccountContext.canonicalAccountDirectory(url)
        }
        return ProviderAccountContext.canonicalAccountDirectory(
            defaultConfigDirectory(for: cmd.kind == .codex ? .codex : .claude)
        )
    }

    /// Identidade pretendida da conta, independente de ela estar montada
    /// agora. Usada por recovery, filtros e detecção de conflitos; execução
    /// continua exigindo `accountDir(for:)`.
    func intendedAccountDir(for task: ScheduledTask) -> URL? {
        let command = task.resolvedCommand
        guard command.kind != .shell else { return nil }
        let provider: Provider =
            command.kind == .codex ? .codex : .claude
        return explicitOrDefaultAccount(
            for: command,
            provider: provider
        )
    }

    /// Agendamentos habilitados que miram a conta — o "N agendamentos ativos"
    /// da aba Contas.
    func activeScheduleCount(for dir: URL) -> Int {
        let key = ProviderAccountContext.canonicalAccountDirectory(dir)
        return tasks.filter {
            $0.enabled && intendedAccountDir(for: $0) == key
        }.count
    }

    /// uids de contínuos com pasta ausente já reportados — evita duplicar o
    /// evento a cada reconfigure.
    private var reportedMissingContinuous: Set<UUID> = []

    /// Grava no histórico, uma vez por agendamento, a falha "pasta não
    /// encontrada" de cada contínuo habilitado cujo configDir aponta para uma
    /// pasta que sumiu. Paridade com o caminho de horários fixos
    /// (`taskScheduler.onFire`), que já registra essa falha ao disparar.
    func recordMissingFolderContinuous() {
        var stillMissing: Set<UUID> = []
        for task in tasks where task.enabled && task.repetition == .continuous {
            let cmd = task.resolvedCommand
            guard cmd.kind != .shell, let path = cmd.configDir, !path.isEmpty,
                  accountDir(for: task) == nil else { continue }
            stillMissing.insert(task.uid)
            if !reportedMissingContinuous.contains(task.uid) {
                recordEvent(makeEvent(
                    date: Date(), result: .failure(message: strings.accountFolderMissingEvent),
                    message: cmd, origin: .renewal))
            }
        }
        reportedMissingContinuous = stillMissing
    }

    private struct EmailCacheEntry {
        let modificationDate: Date?
        let value: String?
    }

    /// Cache do e-mail por conta, invalidado quando o arquivo de autenticação
    /// muda (inclusive após relogin numa conta padrão).
    private var emailCache: [String: EmailCacheEntry] = [:]

    /// E-mail logado na conta (oauthAccount.emailAddress), com cache.
    func email(for dir: URL) -> String? {
        let canonical = ProviderAccountContext.canonicalAccountDirectory(dir)
        let key = canonical.path
        let provider = provider(for: canonical)
        let identityFile = AccountIdentity.identityFile(
            forConfigDir: canonical,
            provider: provider,
            homeDirectory: homeDirectory
        )
        let modificationDate = try? identityFile.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cached = emailCache[key], cached.modificationDate == modificationDate {
            return cached.value
        }
        let value = AccountIdentity.email(
            forConfigDir: canonical,
            provider: provider,
            homeDirectory: homeDirectory
        )
        emailCache[key] = EmailCacheEntry(modificationDate: modificationDate, value: value)
        return value
    }

    func alias(for dir: URL) -> String? {
        let a = aliases[
            ProviderAccountContext.canonicalAccountDirectory(dir).path
        ]
        return (a?.isEmpty ?? true) ? nil : a
    }

    func setAlias(_ dir: URL, _ alias: String?) {
        let key = ProviderAccountContext.canonicalAccountDirectory(dir).path
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { aliases[key] = trimmed } else { aliases[key] = nil }
    }

    /// Rótulo exibido: apelido → e-mail → nome da pasta.
    func label(for dir: URL) -> String {
        alias(for: dir) ?? email(for: dir) ?? dir.lastPathComponent
    }

    /// Estado coerente de todo o lifecycle contínuo. A UI não precisa mais
    /// combinar mapas publicados em momentos diferentes.
    @Published var renewalSnapshot = RenewalSnapshot()

    private let defaults: UserDefaults
    private let homeDirectory: URL
    var dispatchHomeDirectory: URL { homeDirectory }

    private enum Keys {
        static let pausedAccounts = "pausedAccounts"
        static let history = "history"
        static let showRemainingInBar = "showRemainingInBar"
        static let showSensitiveNotificationDetails = "showSensitiveNotificationDetails"
        static let panelUpcomingCount = "panelUpcomingCount"
        static let aliases = "aliases"
        static let registeredAccounts = "registeredAccounts"
        static let registeredAccountProviders = "registeredAccountProviders"
        static let tasks = "tasks"
        static let renewalRecoveryStates = "renewalRecoveryStates"
        /// Migração de builds que persistiam somente a data do bootstrap.
        static let bootstrapAttempts = "bootstrapAttempts"
        static let language = "language"
        static let lastAliveAt = "lastAliveAt"
        static let hasDismissedPermissionGuide = "hasDismissedPermissionGuide"
    }

    private static func canonicalPath(_ path: String) -> String {
        ProviderAccountContext.canonicalAccountDirectory(
            URL(fileURLWithPath: path)
        ).path
    }

    private static func canonicalizedMap(
        _ map: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        // Uma entrada já canônica vence um alias legado em caso de colisão.
        for (path, value) in map where path == canonicalPath(path) {
            result[path] = value
        }
        for (path, value) in map {
            let canonical = canonicalPath(path)
            if result[canonical] == nil { result[canonical] = value }
        }
        return result
    }

    private static func canonicalizedRecoveryStates(
        _ map: [String: RenewalRecoveryState]
    ) -> [String: RenewalRecoveryState] {
        var result: [String: RenewalRecoveryState] = [:]
        // A chave já canônica vence um alias legado em caso de colisão.
        for (key, state) in map where key == canonicalRecoveryKey(key) {
            result[key] = state
        }
        for (key, state) in map {
            let canonical = canonicalRecoveryKey(key)
            if result[canonical] == nil { result[canonical] = state }
        }
        return result
    }

    private static func decodedRecoveryStates(
        from data: Data
    ) -> (
        states: [String: RenewalRecoveryState],
        topLevelCorrupt: Bool
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let entries = object as? [String: Any] else {
            return ([:], true)
        }
        var states: [String: RenewalRecoveryState] = [:]
        let decoder = JSONDecoder()
        for (key, value) in entries {
            let entryData = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed]
            )
            if let entryData,
               let state = try? decoder.decode(
                   RenewalRecoveryState.self,
                   from: entryData
               ) {
                states[key] = state
            } else {
                // Uma case de build futura ou um item corrompido não pode
                // liberar execução. Preserva as demais entradas e bloqueia
                // somente esta conta até uma edição explícita da tarefa.
                states[key] = .needsAttention(bootstrapOrigin: false)
            }
        }
        return (canonicalizedRecoveryStates(states), false)
    }

    private static func canonicalRecoveryKey(_ key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return key }
        return "\(parts[0])|\(canonicalPath(String(parts[1])))"
    }

    private static func migratedBootstrapAttempts(
        _ map: [String: Date]
    ) -> [String: RenewalRecoveryState] {
        var result: [String: RenewalRecoveryState] = [:]
        for (key, attemptDate) in map {
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let canonical = "\(parts[0])|\(canonicalPath(String(parts[1])))"
            let state = RenewalRecoveryState.cooldown(
                notBefore: attemptDate.addingTimeInterval(
                    legacyBootstrapCooldown
                ),
                bootstrapOrigin: true
            )
            if case .cooldown(let existing, _) = result[canonical],
               existing >= attemptDate.addingTimeInterval(
                   legacyBootstrapCooldown
               ) {
                continue
            }
            result[canonical] = state
        }
        return result
    }

    init(defaults: UserDefaults = .standard,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.homeDirectory = home.standardizedFileURL
        self.previousAliveAt = defaults.object(forKey: Keys.lastAliveAt) as? Date
        let loadedRecoveryStates: [String: RenewalRecoveryState]
        let recoveryBlobWasCorrupt: Bool
        if let data = defaults.data(forKey: Keys.renewalRecoveryStates) {
            let decoded = Self.decodedRecoveryStates(from: data)
            loadedRecoveryStates = decoded.states
            recoveryBlobWasCorrupt = decoded.topLevelCorrupt
        } else {
            loadedRecoveryStates = Self.migratedBootstrapAttempts(
                defaults.dictionary(forKey: Keys.bootstrapAttempts)
                    as? [String: Date] ?? [:]
            )
            recoveryBlobWasCorrupt = false
        }
        self.renewalRecoveryStates = loadedRecoveryStates
        let normalizedPausedAccounts = Set(
            ((defaults.array(forKey: Keys.pausedAccounts) as? [String]) ?? [])
                .map(Self.canonicalPath)
        )
        self.pausedAccounts = normalizedPausedAccounts
        defaults.set(Array(normalizedPausedAccounts), forKey: Keys.pausedAccounts)
        if let data = defaults.data(forKey: Keys.history),
           let decoded = try? JSONDecoder().decode([FailableDecodable<FireEvent>].self, from: data) {
            // Decode lossy (como `tasks`): um evento corrompido some, o resto do
            // histórico sobrevive — em vez de o array inteiro lançar e o app
            // perder tudo.
            self.history = decoded.compactMap(\.value)
        } else {
            self.history = []
        }
        self.showRemainingInBar = defaults.bool(forKey: Keys.showRemainingInBar)
        self.showSensitiveNotificationDetails = defaults.bool(
            forKey: Keys.showSensitiveNotificationDetails
        )
        let storedUpcoming = defaults.integer(forKey: Keys.panelUpcomingCount)
        self.panelUpcomingCount = storedUpcoming == 0 ? 1 : min(max(storedUpcoming, 1), 5)
        if let rawLanguage = defaults.string(forKey: Keys.language),
           let language = AppLanguage(rawValue: rawLanguage) {
            self.language = language
        } else {
            self.language = .english
        }
        self.hasDismissedPermissionGuide = defaults.bool(forKey: Keys.hasDismissedPermissionGuide)
        let normalizedAliases = Self.canonicalizedMap(
            (defaults.dictionary(forKey: Keys.aliases) as? [String: String]) ?? [:]
        )
        self.aliases = normalizedAliases
        defaults.set(normalizedAliases, forKey: Keys.aliases)
        var loadedTasks: [ScheduledTask] = []
        if let data = defaults.data(forKey: Keys.tasks),
           let decoded = try? JSONDecoder().decode([FailableDecodable<ScheduledTask>].self, from: data) {
            // Decode lossy: um item ilegível (ex.: raw value de uma build
            // futura após downgrade) some, mas os demais agendamentos
            // sobrevivem — em vez de o array inteiro lançar e a primeira
            // mutação persistir [] por cima do blob antigo.
            loadedTasks = decoded.compactMap(\.value)
        }
        self.tasks = loadedTasks
        if let stored = defaults.array(forKey: Keys.registeredAccounts) as? [String] {
            let normalizedRegisteredAccounts = Array(
                Set(stored.map(Self.canonicalPath))
            ).sorted()
            self.registeredAccounts = normalizedRegisteredAccounts
            defaults.set(
                normalizedRegisteredAccounts,
                forKey: Keys.registeredAccounts
            )
        } else {
            self.registeredAccounts = Self.initialClaudeAccountScan(home: home)
            defaults.set(self.registeredAccounts, forKey: Keys.registeredAccounts)
        }
        let normalizedProviders = Self.canonicalizedMap(
            (defaults.dictionary(forKey: Keys.registeredAccountProviders)
                as? [String: String]) ?? [:]
        )
        self.registeredAccountProviders = normalizedProviders
        defaults.set(
            normalizedProviders,
            forKey: Keys.registeredAccountProviders
        )
        // Migração de cadastros antigos enquanto a assinatura ainda existe.
        for path in self.registeredAccounts
        where self.registeredAccountProviders[path] == nil {
            let url = URL(fileURLWithPath: path)
            if let detected = Provider.detect(at: url) {
                self.registeredAccountProviders[path] = detected.rawValue
            }
        }
        var liveTasks: [String: ScheduledTask] = [:]
        for task in self.tasks {
            if let key = self.continuousKey(for: task),
               liveTasks[key] == nil {
                liveTasks[key] = task
            }
        }
        if recoveryBlobWasCorrupt {
            // Sem chaves recuperáveis, o único comportamento seguro é
            // bloquear todos os contínuos existentes. Editar o payload remove
            // o needs-attention pela regra de revisão em `tasks.didSet`.
            for key in liveTasks.keys {
                self.renewalRecoveryStates[key] =
                    .needsAttention(bootstrapOrigin: false)
            }
        }
        self.renewalRecoveryStates = self.renewalRecoveryStates.filter {
            key, state in
            // Um downgrade pode não decodificar uma task de build futura.
            // Preserva seu sidecar; a próxima mutação explícita de `tasks`
            // fará a limpeza normal em `didSet`.
            guard let task = liveTasks[key] else { return true }
            return !state.bootstrapOrigin
                || task.resolvedBootstrapWhenInactive
        }
    }
}
