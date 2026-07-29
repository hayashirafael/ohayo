import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case english = "en"
    case portuguese = "pt-BR"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .english: return "en_US"
        case .portuguese: return "pt_BR"
        }
    }

    var pickerTitle: String {
        switch self {
        case .english: return "English"
        case .portuguese: return "Português"
        }
    }
}

struct L10n {
    let language: AppLanguage

    var settingsTitle: String { text(en: "Settings", pt: "Configurações") }
    var accounts: String { text(en: "Accounts", pt: "Contas") }
    var schedules: String { text(en: "Schedules", pt: "Agendamentos") }
    var history: String { text(en: "History", pt: "Histórico") }
    var accountsSubtitle: String {
        text(
            en: "Manage the local Claude and Codex accounts used by your schedules.",
            pt: "Gerencie as contas locais do Claude e Codex usadas pelos agendamentos."
        )
    }
    var noAccountsYet: String { text(en: "No accounts yet", pt: "Nenhuma conta ainda") }
    var noAccountsDescription: String {
        text(
            en: "Add a Claude Code or Codex config folder to target schedules to that account.",
            pt: "Adicione uma pasta de configuração do Claude Code ou Codex para direcionar agendamentos à conta."
        )
    }
    var schedulesSubtitle: String {
        text(
            en: "Choose what runs, for which account, and when.",
            pt: "Escolha o que será executado, em qual conta e quando."
        )
    }
    var historySubtitle: String {
        text(
            en: "Review completed, skipped, and failed runs.",
            pt: "Revise disparos concluídos, pulados e com falha."
        )
    }
    /// Chip de filtro por conta (deep-link do painel) nas abas Agendamentos/Histórico.
    func filteredBy(_ label: String) -> String {
        text(en: "Filtered: \(label)", pt: "Filtrando: \(label)")
    }
    var clearFilter: String { text(en: "Clear filter", pt: "Limpar filtro") }
    var general: String { text(en: "General", pt: "Geral") }
    var command: String { text(en: "Command", pt: "Comando") }
    var quit: String { text(en: "Quit", pt: "Sair") }
    var settingsShort: String { text(en: "Settings…", pt: "Ajustes…") }
    var pauseAccount: String { text(en: "Pause account", pt: "Pausar conta") }
    var resumeAccount: String { text(en: "Resume account", pt: "Retomar conta") }
    var pausedBadge: String { text(en: "paused", pt: "pausada") }
    var allAccountsPaused: String { text(en: "All accounts paused", pt: "Todas as contas pausadas") }
    var accountTasks: String {
        text(en: "Account schedules", pt: "Agendamentos da conta")
    }
    var accountHistory: String { text(en: "Account history", pt: "Histórico da conta") }
    var add: String { text(en: "Add", pt: "Adicionar") }
    var save: String { text(en: "Save", pt: "Salvar") }
    var cancel: String { text(en: "Cancel", pt: "Cancelar") }
    var ok: String { "OK" }
    var enabled: String { text(en: "Enabled", pt: "Habilitado") }
    var languageLabel: String { text(en: "Language", pt: "Idioma") }
    var launchAtLogin: String { text(en: "Launch at Login", pt: "Iniciar com o Mac") }
    var remainingInMenuBar: String { text(en: "Remaining time in menu bar", pt: "Tempo restante na barra") }
    var panelUpcomingCountLabel: String {
        text(en: "Upcoming runs in panel", pt: "Próximos disparos no painel")
    }
    var version: String { text(en: "Version", pt: "Versão") }
    var permissionGuideTitle: String { text(en: "Set Up Ohayo", pt: "Configurar o Ohayo") }
    var permissionGuideIntro: String {
        text(en: "Choose which system integrations you want to configure now.",
             pt: "Escolha quais integrações do sistema deseja configurar agora.")
    }
    var providerDoctorTitle: String {
        text(en: "Claude & Codex readiness", pt: "Prontidão do Claude e Codex")
    }
    var providerDoctorIntro: String {
        text(
            en: "Checks only CLI installation and login status. It never runs a prompt, consumes quota, or signs in.",
            pt: "Verifica apenas a instalação das CLIs e o status de login. Nunca executa prompt, consome cota ou faz login."
        )
    }
    var providerDoctorRefresh: String {
        text(en: "Refresh checks", pt: "Atualizar verificações")
    }
    var providerDoctorChecking: String {
        text(en: "Checking…", pt: "Verificando…")
    }
    var providerDoctorOptional: String {
        text(en: "Optional · not configured", pt: "Opcional · não configurado")
    }
    var providerDoctorCLIAvailable: String {
        text(en: "CLI installed", pt: "CLI instalada")
    }
    var providerDoctorCLIMissing: String {
        text(en: "CLI not found", pt: "CLI não encontrada")
    }
    var providerDoctorNativeAccount: String {
        text(en: "Native account", pt: "Conta nativa")
    }
    var providerDoctorCustomAccount: String {
        text(en: "Custom account", pt: "Conta customizada")
    }
    var providerDoctorAuthenticated: String {
        text(en: "Logged in", pt: "Logada")
    }
    var providerDoctorUnauthenticated: String {
        text(en: "Logged out", pt: "Deslogada")
    }
    var providerDoctorAuthUnknown: String {
        text(en: "Login status unknown", pt: "Status de login desconhecido")
    }
    var providerDoctorAuthNotChecked: String {
        text(en: "Not checked", pt: "Não verificado")
    }
    func providerDoctorInstallGuidance(_ provider: Provider) -> String {
        text(
            en: "Install the official \(provider.displayName) CLI, then refresh.",
            pt: "Instale a CLI oficial do \(provider.displayName) e atualize a verificação."
        )
    }
    func providerDoctorOptionalGuidance(_ provider: Provider) -> String {
        text(
            en: "To start using \(provider.displayName), sign in with:",
            pt: "Para começar a usar o \(provider.displayName), faça login com:"
        )
    }
    var providerDoctorLoginGuidance: String {
        text(
            en: "Sign in from Terminal, then refresh:",
            pt: "Faça login pelo Terminal e atualize a verificação:"
        )
    }
    var providerDoctorUnknownGuidance: String {
        text(
            en: "Ohayo could not verify this login. If needed, sign in again:",
            pt: "O Ohayo não conseguiu verificar este login. Se necessário, faça login novamente:"
        )
    }
    var notificationsPermissionTitle: String { text(en: "Notifications", pt: "Notificações") }
    var notificationsPermissionBody: String {
        text(en: "Receive run results and failure alerts.",
             pt: "Receba resultados de execuções e alertas de falha.")
    }
    var allowNotifications: String { text(en: "Allow Notifications", pt: "Permitir notificações") }
    var terminalAutomationTitle: String { text(en: "Terminal Automation", pt: "Automação do Terminal") }
    var terminalAutomationBody: String {
        text(en: "Allow Ohayo to open the interactive sessions you start.",
             pt: "Permita que o Ohayo abra as sessões interativas que você iniciar.")
    }
    var testTerminal: String { text(en: "Test Terminal", pt: "Testar Terminal") }
    var openSystemSettings: String {
        text(en: "Open System Settings", pt: "Abrir Ajustes do Sistema")
    }
    var configureLater: String { text(en: "Configure Later", pt: "Configurar depois") }
    var openSchedules: String { text(en: "Open Schedules", pt: "Abrir Agendamentos") }
    var permissionsSettingsButton: String { text(en: "Permissions…", pt: "Permissões…") }
    var optional: String { text(en: "Optional", pt: "Opcional") }
    var permissionNotConfigured: String { text(en: "Not configured", pt: "Não configurado") }
    var permissionAllowed: String { text(en: "Allowed", pt: "Permitido") }
    var permissionDenied: String { text(en: "Denied", pt: "Negado") }
    var permissionFailed: String { text(en: "Unavailable", pt: "Indisponível") }
    var remainingInMenuBarFooter: String {
        text(
            en: "The menu bar time shows the active provider window that ends first.",
            pt: "O tempo na barra mostra a Janela de uso ativa que termina primeiro."
        )
    }

    func permissionStatus(_ status: PermissionAccessStatus) -> String {
        switch status {
        case .notConfigured: return permissionNotConfigured
        case .allowed: return permissionAllowed
        case .denied: return permissionDenied
        case .unavailable, .failed: return permissionFailed
        }
    }

    func settingsSectionTitle(_ section: SettingsSection) -> String {
        switch section {
        case .contas: return accounts
        case .horarios: return schedules
        case .historico: return history
        case .geral: return general
        }
    }

    func cliNotFound(_ provider: Provider) -> String {
        text(en: "\(provider.displayName) CLI not found",
             pt: "CLI do \(provider.displayName) não encontrado")
    }

    func installCLIWarning(_ provider: Provider) -> String {
        let cliName = provider == .claude ? "Claude Code" : "Codex CLI"
        return text(en: "\(provider.displayName) CLI not found - install \(cliName)",
                    pt: "CLI do \(provider.displayName) não encontrado — instale o \(cliName)")
    }

    func installCLIForAccount(_ provider: Provider) -> String {
        text(en: "\(provider.displayName) CLI not found - install it to run this account",
             pt: "CLI do \(provider.displayName) não encontrado — instale para disparar nesta conta")
    }

    var commandTimeout: String {
        text(en: "the command timed out",
             pt: "o comando excedeu o tempo limite")
    }

    var accountFolderMissing: String {
        text(en: "account folder not found - the schedule will not run",
             pt: "pasta da conta não encontrada — o agendamento não dispara")
    }

    var accountFolderMissingEvent: String {
        text(en: "account folder not found",
             pt: "pasta da conta não encontrada")
    }

    var continuousShellInvalidEvent: String {
        text(
            en: "shell commands cannot use continuous scheduling",
            pt: "comandos shell não podem usar agendamento contínuo"
        )
    }

    var accountFolderMissingAccountTab: String {
        text(en: "folder not found - remove it from the list or restore the folder",
             pt: "pasta não encontrada — remova da lista ou restaure a pasta")
    }

    var providerLabel: String { text(en: "Provider", pt: "Provedor") }
    var folderLabel: String { text(en: "Folder", pt: "Pasta") }
    var addAccount: String { text(en: "Add account…", pt: "Adicionar conta…") }
    var accountAlias: String { text(en: "Alias", pt: "Apelido") }
    var removeAccountHelp: String {
        text(en: "Remove from the list. This does not delete anything from disk and disables the account schedules.",
             pt: "Remover da lista (não apaga nada do disco; desabilita os agendamentos da conta)")
    }
    func removeAccount(_ label: String) -> String {
        text(en: "Remove \(label)", pt: "Remover \(label)")
    }
    func removeAccountConfirmationTitle(_ label: String) -> String {
        text(en: "Remove \(label) from Ohayo?", pt: "Remover \(label) do Ohayo?")
    }
    func removeAccountConfirmationBody(scheduleCount: Int) -> String {
        let impact: String
        switch scheduleCount {
        case 0:
            impact = text(
                en: "No schedules will be affected.",
                pt: "Nenhum agendamento será afetado."
            )
        case 1:
            impact = text(
                en: "1 schedule that uses this account will be disabled.",
                pt: "1 agendamento que usa esta conta será desabilitado."
            )
        default:
            impact = text(
                en: "\(scheduleCount) schedules that use this account will be disabled.",
                pt: "\(scheduleCount) agendamentos que usam esta conta serão desabilitados."
            )
        }
        return text(
            en: "The folder and its files will stay on disk. \(impact)",
            pt: "A pasta e seus arquivos continuarão no disco. \(impact)"
        )
    }
    var accountsFooter: String {
        text(en: "Choose a config folder for a Claude Code or Codex account. The name is free; the type is inferred from its contents. Create commands in Schedules.",
             pt: "Aponte a pasta de config de uma conta (Claude Code ou Codex) — o nome é livre; o tipo é inferido pelo conteúdo. Crie comandos em Agendamentos.")
    }
    var invalidFolderTitle: String { text(en: "Invalid folder", pt: "Pasta inválida") }
    var invalidFolderMessage: String {
        text(en: "The selected folder does not look like a Claude Code or Codex config folder.",
             pt: "A pasta escolhida não parece uma pasta de config do Claude Code nem do Codex.")
    }

    func activeScheduleCount(_ count: Int) -> String {
        switch count {
        case 0: return text(en: "no active schedules", pt: "nenhum agendamento ativo")
        case 1: return text(en: "1 active schedule", pt: "1 agendamento ativo")
        default: return text(en: "\(count) active schedules", pt: "\(count) agendamentos ativos")
        }
    }

    var noActiveSchedules: String { text(en: "No active schedules", pt: "Nenhum agendamento ativo") }
    var noSchedulesYet: String { text(en: "No schedules yet", pt: "Nenhum agendamento ainda") }
    var noSchedulesDescription: String {
        text(en: "Schedules run commands continuously for each account's 5h window or at fixed times.",
             pt: "Agendamentos disparam comandos de forma contínua (a cada janela de 5h da conta) ou em horários fixos.")
    }
    var newSchedule: String { text(en: "New schedule…", pt: "Novo agendamento…") }
    var editSchedule: String { text(en: "Edit schedule", pt: "Editar agendamento") }
    var scheduleListFooter: String {
        text(
            en: "Continuous keeps the account's 5h window active 24/7 and skips redundant runs while it is active; fixed times always run on the selected times and days.",
            pt: "Contínuo mantém a Janela de uso de 5h da conta ativa 24/7 e pula Disparos redundantes enquanto ela está ativa; horários fixos sempre disparam nos horários e dias marcados."
        )
    }
    // Barra da tela Horários: filtros, ordenação e resumo.
    var filter: String { text(en: "Filter", pt: "Filtrar") }
    var allAccountsOption: String { text(en: "All", pt: "Todas") }
    var allOption: String { text(en: "All", pt: "Todos") }
    var statusLabel: String { "Status" }
    var activeOption: String { text(en: "Active", pt: "Ativos") }
    var inactiveOption: String { text(en: "Disabled", pt: "Desativados") }
    var clearFilters: String { text(en: "Clear filters", pt: "Limpar filtros") }
    var sortMenu: String { text(en: "Sort", pt: "Ordenar") }
    var sortDefault: String { text(en: "Default", pt: "Padrão") }
    var sortByNextFire: String { text(en: "Next run", pt: "Próximo disparo") }
    var sortByName: String { text(en: "Name", pt: "Nome") }
    var noFilterMatches: String {
        text(en: "No schedules match the filters",
             pt: "Nenhum agendamento corresponde aos filtros")
    }
    var runNow: String { text(en: "Run now", pt: "Executar agora") }
    var runningNow: String { text(en: "Running…", pt: "Executando…") }
    var viewDetails: String { text(en: "View details", pt: "Ver detalhes") }
    var edit: String { text(en: "Edit", pt: "Editar") }
    var delete: String { text(en: "Delete", pt: "Excluir") }
    var deleteScheduleConfirmTitle: String {
        text(en: "Delete this schedule?", pt: "Excluir este agendamento?")
    }

    /// "5 schedules · 3 active" / "5 agendamentos · 3 ativos".
    func scheduleSummary(total: Int, active: Int) -> String {
        let totalPart = total == 1
            ? text(en: "1 schedule", pt: "1 agendamento")
            : text(en: "\(total) schedules", pt: "\(total) agendamentos")
        let activePart = text(en: "\(active) active", pt: "\(active) ativos")
        return "\(totalPart) · \(activePart)"
    }

    /// "next: Sat 17:14" / "próximo: sáb 17:14" — já recebe a data formatada.
    func summaryNext(_ time: String) -> String {
        text(en: "next: \(time)", pt: "próximo: \(time)")
    }

    /// "2 visible" / "2 visíveis" quando algum filtro está ativo.
    func visibleCount(_ count: Int) -> String {
        count == 1
            ? text(en: "1 visible", pt: "1 visível")
            : text(en: "\(count) visible", pt: "\(count) visíveis")
    }
    var fixedTimes: String { text(en: "Fixed times", pt: "Horários fixos") }
    var continuousWindow: String { text(en: "Continuous (5h window)", pt: "Contínua (janela de 5h)") }
    var continuous: String { text(en: "continuous", pt: "contínua") }
    var continuousBadge: String { text(en: "Continuous", pt: "Contínua") }
    var fixedContinuousDescription: String {
        text(
            en: "Runs at the end of each detected 5h account window to keep it active.",
            pt: "Executa ao fim de cada Janela de uso de 5h detectada para mantê-la ativa."
        )
    }
    var bootstrapWhenInactive: String {
        text(en: "Try to start when no active window is detected",
             pt: "Tentar iniciar quando não houver janela ativa")
    }
    var bootstrapWhenInactiveHelp: String {
        text(
            en: "After saving, Ohayo tries to start this enabled schedule. Terminal sessions may require confirmation; the command can consume provider quota.",
            pt: "Após salvar, o Ohayo tenta iniciar este agendamento habilitado. Sessões no Terminal podem exigir confirmação; o comando pode consumir cota do provedor."
        )
    }
    var continuousConflict: String {
        text(en: "This account already has a continuous schedule.",
             pt: "Esta conta já tem um agendamento contínuo.")
    }
    var continuousConflictTitle: String {
        text(en: "Continuous schedule conflict", pt: "Conflito de agendamento contínuo")
    }
    var overlappingWindows: String {
        text(en: "Times fall within the same 5h window", pt: "Horários caem na mesma janela de 5h")
    }
    var repetition: String { text(en: "Repetition", pt: "Repetição") }
    var time: String { text(en: "Time", pt: "Horário") }
    var addTime: String { text(en: "Add time", pt: "Adicionar horário") }
    func editTime(_ time: String) -> String {
        text(en: "Edit \(time)", pt: "Editar \(time)")
    }
    func removeTime(_ time: String) -> String {
        text(en: "Remove \(time)", pt: "Remover \(time)")
    }
    var generateChain: String { text(en: "Generate every 5h…", pt: "Gerar a cada 5h…") }
    var chainAnchor: String { text(en: "Starting at", pt: "A partir de") }
    var generate: String { text(en: "Generate", pt: "Gerar") }
    var days: String { text(en: "Days", pt: "Dias") }
    var type: String { text(en: "Type", pt: "Tipo") }
    var messageSection: String { text(en: "Command", pt: "Comando") }
    var scheduleSection: String { text(en: "Schedule", pt: "Agendamento") }
    var nameOptional: String { text(en: "Name (optional)", pt: "Nome (opcional)") }
    var messageOrCommand: String { text(en: "Prompt or command", pt: "Prompt ou comando") }
    var none: String { text(en: "None", pt: "Nenhum") }
    var executionMode: String { text(en: "Execution", pt: "Execução") }
    var advancedOptions: String {
        text(en: "Advanced options", pt: "Opções avançadas")
    }
    var runInBackground: String {
        text(en: "Run in background", pt: "Executar em segundo plano")
    }
    var runInBackgroundDescription: String {
        text(
            en: "Runs quietly without saving the command output.",
            pt: "Executa sem abrir janelas e sem salvar a saída do comando."
        )
    }
    var showResponseDescription: String {
        text(
            en: "Runs in background and saves the response in History.",
            pt: "Executa em segundo plano e salva a resposta no Histórico."
        )
    }
    var runInTerminalDescription: String {
        text(
            en: "Opens an interactive session you can follow in Terminal.",
            pt: "Abre uma sessão interativa para você acompanhar no Terminal."
        )
    }
    var showResponse: String {
        text(en: "Show response (history + notification)",
             pt: "Mostrar resposta (histórico + notificação)")
    }
    var notifyOnSuccess: String {
        text(en: "Notify on macOS when this schedule runs",
             pt: "Notificar no macOS quando este agendamento for executado")
    }
    var notifyOnSuccessUnavailableInTerminal: String {
        text(
            en: "Unavailable for interactive Terminal sessions because Ohayo cannot observe their completion.",
            pt: "Indisponível em sessões interativas do Terminal, pois o Ohayo não acompanha sua conclusão."
        )
    }
    var timeout: String { text(en: "Timeout", pt: "Tempo limite") }
    var runInTerminal: String {
        text(en: "Open in Terminal (interactive)",
             pt: "Abrir no Terminal (interativo)")
    }
    var model: String { text(en: "Model", pt: "Modelo") }
    var effort: String { text(en: "Effort", pt: "Esforço") }
    var safeMode: String {
        text(en: "Ignore Claude customizations (not a sandbox)",
             pt: "Ignorar customizações do Claude (não é sandbox)")
    }
    var skillLabel: String {
        text(en: "Skill (expands context)", pt: "Skill (amplia o contexto)")
    }
    var noSkill: String { text(en: "None", pt: "Nenhuma") }
    var skillNotFound: String {
        text(en: "Skill not found in this account", pt: "Skill não encontrada nesta conta")
    }
    var skillDisablesSafeMode: String {
        text(
            en: "Selecting a skill expands context and requires Claude customizations",
            pt: "Selecionar uma skill amplia o contexto e exige as customizações do Claude"
        )
    }
    var reasoning: String { text(en: "Reasoning", pt: "Raciocínio") }
    var accountDefaultReasoning: String {
        text(en: "Account default", pt: "Padrão da conta")
    }
    var account: String { text(en: "Account", pt: "Conta") }
    var globalDefault: String { text(en: "Default (global)", pt: "Padrão (global)") }
    var codexDefault: String { text(en: "Default (~/.codex)", pt: "Padrão (~/.codex)") }
    var accountDefaultModel: String { text(en: "Model (account default)", pt: "Modelo (padrão da conta)") }
    var workingDirectoryDefault: String {
        text(en: "Directory (~ by default)", pt: "Diretório (~ por padrão)")
    }
    var chooseDirectory: String { text(en: "Choose", pt: "Escolher") }
    var clearWorkingDirectory: String {
        text(en: "Clear directory", pt: "Limpar diretório")
    }

    func taskKind(_ kind: Message.Kind) -> String {
        switch kind {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .shell: return text(en: "command", pt: "comando")
        }
    }

    var waitingForWindow: String { text(en: "waiting for window", pt: "aguardando janela") }
    var dispatchingRenewal: String {
        text(en: "dispatching renewal", pt: "disparando renovação")
    }
    var invalidContinuousConfiguration: String {
        text(en: "invalid continuous configuration", pt: "configuração contínua inválida")
    }
    var quotaUnavailable: String {
        text(en: "quota unavailable", pt: "cota indisponível")
    }
    var needsAttention: String {
        text(en: "needs attention", pt: "requer atenção")
    }
    var ready: String { text(en: "Ready", pt: "Tudo pronto") }
    var noSchedulesPanelTitle: String {
        text(en: "No active schedules", pt: "Nenhum agendamento ativo")
    }
    var noSchedulesPanelDescription: String {
        text(
            en: "Create a schedule to have a command ready when you need it.",
            pt: "Crie um agendamento para ter um comando pronto quando precisar."
        )
    }
    var allSchedulesDisabledPanelTitle: String {
        text(
            en: "All schedules are disabled",
            pt: "Todos os agendamentos estão desativados"
        )
    }
    var allSchedulesDisabledPanelDescription: String {
        text(
            en: "Review your schedules and enable one to restore upcoming runs.",
            pt: "Revise seus agendamentos e ative um para restaurar os próximos disparos."
        )
    }
    var allPausedPanelDescription: String {
        text(
            en: "Resume an account to restore its upcoming runs.",
            pt: "Retome uma conta para restaurar seus próximos disparos."
        )
    }
    var quotaUnavailablePanelDescription: String {
        text(
            en: "Ohayo could not verify provider quota, so no command was sent.",
            pt: "O Ohayo não conseguiu verificar a cota do provedor, então nenhum comando foi enviado."
        )
    }
    var needsAttentionPanelDescription: String {
        text(
            en: "Review the affected schedule before the next run.",
            pt: "Revise o agendamento afetado antes do próximo disparo."
        )
    }
    var waitingForWindowPanelDescription: String {
        text(
            en: "Continuous schedules are waiting for reliable window data.",
            pt: "Agendamentos contínuos aguardam dados confiáveis da janela."
        )
    }
    var reviewAccounts: String { text(en: "Review Accounts", pt: "Revisar Contas") }
    var reviewSchedules: String {
        text(en: "Review Schedules", pt: "Revisar Agendamentos")
    }
    var reviewSetup: String { text(en: "Review Setup", pt: "Revisar configuração") }
    var quotaUnavailablePanelTitle: String {
        text(en: "Quota unavailable", pt: "Cota indisponível")
    }
    var needsAttentionPanelTitle: String {
        text(en: "Schedule needs attention", pt: "Agendamento requer atenção")
    }
    var waitingForWindowPanelTitle: String {
        text(en: "Waiting for the next window", pt: "Aguardando a próxima janela")
    }
    var moreActions: String { text(en: "More actions", pt: "Mais ações") }
    var quitOhayo: String { text(en: "Quit Ohayo", pt: "Sair do Ohayo") }
    var quotaUnavailableEvent: String {
        text(
            en: "Quota could not be verified; no command was sent.",
            pt: "Não foi possível verificar a cota; nenhum comando foi enviado."
        )
    }
    var renewalFallbackName: String {
        text(en: "continuous schedule", pt: "agendamento contínuo")
    }
    func renewsAt(_ time: String) -> String {
        text(en: "next run \(time)", pt: "próximo disparo \(time)")
    }
    func retriesAt(_ time: String) -> String {
        text(en: "retries \(time)", pt: "tenta novamente \(time)")
    }
    func mayTryAt(_ time: String) -> String {
        text(en: "may try \(time)", pt: "pode tentar \(time)")
    }
    func nextAt(_ time: String) -> String { text(en: "next \(time)", pt: "próxima \(time)") }

    var noHistory: String { text(en: "No runs recorded yet.", pt: "Sem disparos registrados ainda.") }
    var noHistoryDescription: String {
        text(en: "Runs from your schedules will appear here with account and model details.",
             pt: "Os disparos dos seus agendamentos aparecerão aqui com detalhes da conta e do modelo.")
    }
    var noFilteredHistory: String {
        text(
            en: "No runs match your filters.",
            pt: "Nenhum disparo corresponde aos filtros."
        )
    }
    var searchHistory: String {
        text(en: "Search runs", pt: "Buscar disparos")
    }
    var historySuccess: String { text(en: "Success", pt: "Sucesso") }
    var historyLaunched: String { text(en: "Launched", pt: "Iniciado") }
    var historyFailure: String { text(en: "Failed", pt: "Falhou") }
    var historySkipped: String { text(en: "Skipped", pt: "Pulado") }
    var historyMissed: String { text(en: "Missed", pt: "Perdido") }
    var historyUnknownAccount: String { text(en: "Unknown account", pt: "Conta desconhecida") }
    var historyUnknownProvider: String { text(en: "Unknown provider", pt: "Provedor desconhecido") }
    var historyUnknownCommand: String { text(en: "Command not recorded", pt: "Comando não registrado") }
    var historyAccountDefaultModel: String { text(en: "Account default", pt: "Padrão da conta") }
    var historyResponse: String { text(en: "Response", pt: "Resposta") }
    var historyDetails: String { text(en: "Details", pt: "Detalhes") }
    var clearHistory: String { text(en: "Clear history", pt: "Limpar histórico") }
    var clearHistoryConfirmationTitle: String {
        text(en: "Clear all history?", pt: "Limpar todo o histórico?")
    }
    var clearHistoryConfirmationBody: String {
        text(
            en: "This permanently removes every recorded run.",
            pt: "Isso remove permanentemente todas as execuções registradas."
        )
    }
    var clearHistoryAction: String { text(en: "Clear", pt: "Limpar") }
    func authenticationRequired(_ provider: Provider, configDir: URL) -> String {
        let escapedPath = configDir.path.replacingOccurrences(of: "'", with: "'\\''")
        let loginCommand: String
        switch provider {
        case .claude:
            loginCommand = "CLAUDE_CONFIG_DIR='\(escapedPath)' claude auth login"
        case .codex:
            loginCommand = "CODEX_HOME='\(escapedPath)' codex login"
        }
        return text(
            en: "\(provider.displayName) is not logged in for this account. Run `\(loginCommand)` and try again.",
            pt: "O \(provider.displayName) não está logado nesta conta. Execute `\(loginCommand)` e tente novamente."
        )
    }
    var historyExecutedSuccessfully: String {
        text(en: "Executed successfully", pt: "Executado com sucesso")
    }
    var historyTerminalLaunched: String {
        text(en: "Interactive session opened in Terminal",
             pt: "Sessão interativa aberta no Terminal")
    }
    func historyWindowActive(until: String) -> String {
        text(en: "Active window until \(until)", pt: "Janela ativa até \(until)")
    }
    func historyMissedOccurrence(_ occurrence: String) -> String {
        text(en: "Missed at \(occurrence) while the app was closed",
             pt: "Perdido em \(occurrence) enquanto o app estava fechado")
    }
    func historyFooter(limit: Int) -> String {
        text(en: "Last \(limit) runs, newest first.",
             pt: "Últimos \(limit) disparos, mais recentes primeiro.")
    }
    func skippedUntil(_ time: String, _ until: String) -> String {
        text(en: "\(time) - skipped (window until \(until))",
             pt: "\(time) — pulado (janela até \(until))")
    }
    func failed(_ time: String, _ message: String) -> String {
        text(en: "\(time) - failed: \(message)",
             pt: "\(time) — falhou: \(message)")
    }
    func missedWhileClosed(_ time: String, _ occurrence: String) -> String {
        text(en: "\(time) - missed \(occurrence) (app was closed)",
             pt: "\(time) — perdido \(occurrence) (app estava fechado)")
    }
    var alreadyRunningTitle: String {
        text(en: "Ohayo is already running", pt: "O Ohayo já está aberto")
    }
    var alreadyRunningBody: String {
        text(en: "Another instance owns the schedules. This one will quit to avoid duplicate dispatches.",
             pt: "Outra instância já cuida dos agendamentos. Esta vai encerrar para evitar disparos duplicados.")
    }
    func succeeded(_ time: String, _ message: String) -> String {
        text(en: "\(time) - \(message)", pt: "\(time) — \(message)")
    }
    func origin(_ origin: FireOrigin) -> String? {
        switch origin {
        case .manual: return text(en: "manual", pt: "manual")
        case .renewal: return text(en: "continuous", pt: "contínuo")
        case .agenda: return text(en: "fixed time", pt: "horário fixo")
        case .scheduled: return nil
        }
    }

    var notificationFailureTitle: String { text(en: "Ohayo: run failed", pt: "Ohayo: disparo falhou") }
    func notificationResponseTitle(_ messageText: String) -> String { "Ohayo: \(messageText)" }
    func notificationSuccessTitle(_ name: String) -> String { "Ohayo: \(name)" }
    /// Corpo curto "conta · HH:MM · resultado"; sem segmento de conta para shell.
    func notificationSuccessBody(account: String?, time: String) -> String {
        let result = text(en: "ran successfully", pt: "executada com sucesso")
        return [account, time, result].compactMap { $0 }.joined(separator: " · ")
    }
    var showSensitiveNotificationDetails: String {
        text(
            en: "Show sensitive details in notifications",
            pt: "Mostrar detalhes sensíveis nas notificações"
        )
    }
    var genericNotificationFailureTitle: String {
        text(en: "Ohayo schedule failed", pt: "Agendamento do Ohayo falhou")
    }
    var genericNotificationFailureBody: String {
        text(
            en: "Open History in Ohayo to see the error details.",
            pt: "Abra o Histórico no Ohayo para ver os detalhes do erro."
        )
    }
    var genericNotificationResponseTitle: String {
        text(en: "Ohayo response ready", pt: "Resposta do Ohayo pronta")
    }
    var genericNotificationResponseBody: String {
        text(
            en: "Open History in Ohayo to read the response.",
            pt: "Abra o Histórico no Ohayo para ler a resposta."
        )
    }
    var genericNotificationSuccessTitle: String {
        text(en: "Ohayo schedule completed", pt: "Agendamento do Ohayo concluído")
    }
    var genericNotificationSuccessBody: String {
        text(
            en: "Open History in Ohayo to see the run details.",
            pt: "Abra o Histórico no Ohayo para ver os detalhes da execução."
        )
    }

    func daysSummary(_ weekdays: Set<Int>) -> String {
        let validWeekdays = Set(weekdays.filter { (1...7).contains($0) })
        if validWeekdays.isEmpty {
            return text(en: "no valid days", pt: "nenhum dia válido")
        }
        if validWeekdays == Set(1...7) { return text(en: "every day", pt: "todos os dias") }
        if validWeekdays == [2, 3, 4, 5, 6] { return text(en: "Mon to Fri", pt: "seg a sex") }
        if validWeekdays == [1, 7] { return text(en: "weekend", pt: "fim de semana") }
        let names: [String]
        switch language {
        case .english: names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        case .portuguese: names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
        }
        return validWeekdays.sorted().map { names[$0 - 1] }.joined(separator: " · ")
    }

    var dayLetters: [String] {
        switch language {
        case .english: return ["S", "M", "T", "W", "T", "F", "S"]
        case .portuguese: return ["D", "S", "T", "Q", "Q", "S", "S"]
        }
    }

    /// Nome completo do dia (1 = domingo) — desambigua as letras únicas nos
    /// botões de dia (help/accessibilityLabel).
    func dayName(_ weekday: Int) -> String {
        guard (1...7).contains(weekday) else {
            return text(en: "Invalid day", pt: "Dia inválido")
        }
        let names: [String]
        switch language {
        case .english:
            names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        case .portuguese:
            names = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"]
        }
        return names[weekday - 1]
    }

    // Motivos do botão Salvar desabilitado (tooltip do form de agendamento).
    var saveNeedsMessage: String {
        text(en: "Enter a prompt or command", pt: "Digite um prompt ou comando")
    }
    var saveNeedsTime: String {
        text(en: "Add at least one time", pt: "Adicione ao menos um horário")
    }
    var saveNeedsDay: String {
        text(en: "Select at least one day", pt: "Selecione ao menos um dia")
    }
    var scheduleCouldNotSave: String {
        text(
            en: "The schedule could not be saved",
            pt: "Não foi possível salvar o agendamento"
        )
    }
    var scheduleNoLongerExists: String {
        text(
            en: "This schedule no longer exists. Close the editor and try again.",
            pt: "Este agendamento não existe mais. Feche o editor e tente novamente."
        )
    }
    var scheduleChangedWhileEditing: String {
        text(
            en: "This schedule changed while it was open. Close the editor and review the latest version.",
            pt: "Este agendamento mudou enquanto estava aberto. Feche o editor e revise a versão mais recente."
        )
    }

    var expandSchedule: String {
        text(en: "Show schedule details", pt: "Mostrar detalhes do agendamento")
    }
    var collapseSchedule: String {
        text(en: "Hide schedule details", pt: "Ocultar detalhes do agendamento")
    }
    func scheduleEnabled(_ name: String) -> String {
        text(en: "Enable \(name)", pt: "Habilitar \(name)")
    }
    func editAccountAlias(_ label: String) -> String {
        text(en: "Edit alias for \(label)", pt: "Editar apelido de \(label)")
    }
    func saveAccountAlias(_ label: String) -> String {
        text(en: "Save alias for \(label)", pt: "Salvar apelido de \(label)")
    }
    var menuBarAccessibilityLabel: String {
        text(en: "Ohayo status", pt: "Status do Ohayo")
    }
    var menuBarStatusProblem: String {
        text(en: "Needs attention", pt: "Requer atenção")
    }
    var menuBarStatusPaused: String {
        text(en: "All accounts paused", pt: "Todas as contas pausadas")
    }
    func menuBarStatusActive(_ remaining: String) -> String {
        text(
            en: "Active provider window, \(remaining) remaining",
            pt: "Janela do provedor ativa, \(remaining) restantes"
        )
    }
    var menuBarStatusIdle: String {
        text(en: "No active provider window", pt: "Nenhuma janela ativa do provedor")
    }

    private func text(en: String, pt: String) -> String {
        language == .portuguese ? pt : en
    }
}
