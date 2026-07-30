# Ohayo Agent Notes

`AGENTS.md` is the canonical repository workflow and invariant guide. This file
adds the detailed architecture map used by Claude Code; keep both aligned with
the current source.

## Overview

macOS menu bar app (Swift 5.9 + SwiftUI `MenuBarExtra`, macOS 13+, SPM, with
Sparkle as its external package dependency) that schedules Claude, Codex and
shell commands and can chain supported 5-hour usage windows per account.
Provider schedules are account-centered; shell schedules have no provider
account.

## Domain vocabulary

- **Account** — a native or custom Claude/Codex account resolved by
  `ProviderAccountContext`. Native Claude is deliberately different from
  `CLAUDE_CONFIG_DIR=~/.claude`: config/transcripts live under `~/.claude`,
  while identity/trust live in `~/.claude.json`, and the environment override
  must be absent. Custom Claude uses the override. Codex defaults to
  `~/.codex` and uses `CODEX_HOME`. Display label resolves alias → logged-in
  email → folder name. Existing directories resolve symlinks before they key
  pauses, aliases, queues, schedulers, cooldowns or conflict checks. Launching
  the app does not rewrite legacy task payloads merely to canonicalize them;
  the form normalizes their account selection when edited.
- **Window** — the plan's 5-hour usage block. Inferred passively from local
  transcripts. Evidence is fail-closed: Claude requires a non-synthetic,
  non-error assistant event with positive token usage; Codex requires a
  `token_count` event with positive `last_token_usage`. Auth/model/network
  errors and zero-token events do not open a fictional window.
- **Agendamento** (`ScheduledTask`) — the single unified concept: a command
  dispatched either **continuously** or on **fixed times**. Carries an embedded
  prompt (`command: Message`), an optional name, an `enabled` toggle, and a
  `repetition`:
  - `continuous` — arms at the end of the detected window and chains 5h windows
    24/7; driven by `RenewalEngine`, keyed by the account the command targets.
    New tasks persist `bootstrapWhenInactive` from an explicit UI choice;
    missing values identify legacy tasks and resolve fail-closed to `false`.
    Max one continuous agendamento per account (`AppState.hasContinuousConflict`).
  - `fixed` — fixed times × weekdays (`AgendaMath`), driven by `TaskScheduler`,
    with a single catch-up on wake.
  There is no `AppState.renewals` dict and no command library any more.
- **hi** — the dispatch that opens/renews a window.
- **Message** — the embedded content of an agendamento: a Claude prompt
  (configurable model, effort, safe-mode, working dir), a Codex prompt
  (configurable model, reasoning effort, account), or a raw shell command.
  Default message: `1+1` · Haiku · low effort · safe-mode (uid `…0001`,
  `AppState.defaultMessage`); Codex has its own minimal default
  (`AppState.defaultCodexMessage`, uid `…0002`). Codex with no explicit model
  omits `--model` (and reasoning) so the account's `config.toml` default wins.
  Claude/Codex default to an interactive Terminal hand-off; `runInTerminal:
  false` is batch. Batch timeout is configurable (`timeoutSeconds`), defaulting
  to 900s for providers and 300s for shell; Terminal is unsupervised and has no
  timeout.
  A Message can carry an optional skill (`skill: String?`), detected by
  `SkillCatalog` from account/user/repository scopes (plus Claude plugins and
  enabled Codex plugins) and prefixed at dispatch via `resolvedPromptText`
  (`/skill …` for Claude, `$skill …` for Codex); with a skill present,
  `resolvedSafeMode` is `false` because ignored Claude customizations would
  skip the skill.
- **Provider** — `claude` or `codex`, the axis that differentiates account
  discovery, window detection and dispatch (`Provider.swift`). Detected by
  folder *content*, not name (`Provider.detect(at:)`): `.claude.json` →
  claude; else `auth.json` → codex; else `projects/` → claude; else
  `sessions/` → codex; else no signature (`nil`). Each provider carries its
  own transcripts subpath (`projects`/`sessions`), account-environment rules
  (not merely an unconditional env var) and CLI binary name. The provider of a
  registered custom account is persisted and passed explicitly to quota
  consumers, so a missing or temporarily ambiguous folder cannot silently
  change provider.
## Architecture map

- `AppRuntimeProfile.swift` — resolve produção somente para o bundle ID
  oficial. `Ohayo Dev.app` e `swift run Ohayo` compartilham identidade de
  desenvolvimento, preferências, Application Support e políticas isoladas.
- `AppState.swift` — central observable state and UserDefaults persistence for
  unified agendamentos. Pause is per account: `pausedAccounts: Set<String>`
  (canonical paths, persisted). Typed renewal recovery
  (`cooldown`/`retry`/`needsAttention`) is keyed by task UID + intended
  canonical account and persisted across restarts. It remains attached while
  a custom folder is offline and across a downgrade that cannot decode a
  future task; corrupt entries fail closed rather than enabling another
  bootstrap. `renewalSnapshot` (not persisted) publishes the typed continuous
  lifecycle per task/account; its quota-unavailable and needs-attention
  projections keep fail-closed detection distinct from an inactive window.
  `accountFilter: URL?` is the deep-link the menu panel sets to scope the
  Schedules/History sections to one account
  (`taskMatchesFilter`/`matchesFilter`), with a clear-filter chip in both.
  Account-provider registrations, notification privacy and the bounded history
  are persisted; `clearHistory()` deletes the local history blob.
- `AppEnvironment.swift` — composition root; wires both engines ↔ controller,
  observes sleep/wake and `$tasks` (single `reconfigureSchedules`: continuous
  agendamentos feed `RenewalEngine`, fixed ones `TaskScheduler`).
  A 60-second `statusTick()` synchronizes continuous lifecycle, rearms fixed
  schedules, records the heartbeat and pulses the UI. Runner/auth dependencies
  are injectable so composition tests never depend on the developer's real
  CLIs/login.
- `RenewalEngine.swift` — accounts with a continuous agendamento; per-account
  timers armed at the detected window end. When no valid window exists, it
  bootstraps only with explicit consent. A delivered attempt creates a
  persisted five-hour cooldown across restarts; a scheduled hand-off keeps its
  recovery independently from bootstrap consent, and real transcript evidence
  replaces either timer. Transient failures retry with bounded exponential
  backoff measured from the returned failure and a fresh transcript check.
  `needsAttention` blocks without a periodic alert/cooldown until evidence
  appears or the executable task payload changes. Consent is revalidated
  immediately before and after the async dispatch.
- `SessionDetector.swift` — typed window state from transcripts:
  `active(until:)`, conclusively `inactive`, or fail-closed
  `unavailable(reason:)`. Production callers pass the persisted/request
  provider explicitly; folder inference exists only as a legacy/test adapter.
- `FireController.swift` — orchestrates one dispatch: only continuous renewal
  skips when a window is already active; fixed/manual runs always execute.
  It returns typed `DispatchOutcome` values (`completed`, `launched`, `skipped`,
  `paused`, `retryableFailure`, `needsAttention`). Runs are FIFO per
  provider/account, while different accounts may advance concurrently; jobs
  are never discarded by a global busy flag. Terminal hand-off records
  `.launched`, never `.success`. Notification details are private by default
  and only include prompt/response/error/account after explicit opt-in.
- `Provider.swift` — the claude/codex axis: folder-content detection,
  transcripts subpath, usage-window duration, environment key, CLI binary name,
  display name.
- `CommandRunner.swift` — subprocess: `claude -p --model … --effort …
  [--safe-mode]`, `codex exec [--model …] --sandbox read-only …
  [-c model_reasoning_effort=…]` (model/reasoning flags omitted when unset →
  account default), or login-shell command. Claude/Codex prompts come from
  stdin, not argv; shell remains `-l -c`. `ProviderAccountContext` applies the
  correct native/custom environment. Timeouts come from the message, output is
  capped as UTF-8-safe head + tail, and timeout termination targets only
  positive PIDs observed in the process tree (SIGTERM then best-effort
  SIGKILL).
- `TerminalLauncher.swift` — disparo interativo (`message.resolvedRunInTerminal`):
  abre uma sessão no Terminal.app via AppleScript rodando um `.sh` temporário
  privado (0600, traps de auto-`rm`, limpeza de resíduos antigos); aplica o
  contexto de conta correto e faz `cd` para o working dir
  (default `~/Library/Application Support/Ohayo/workspace` — nunca o home, cujo
  trust não persiste). `seedTrust` pré-grava apenas esse workspace controlado
  pelo Ohayo em `projects[<dir>]` no `.claude.json`, somente com
  `hasTrustDialogAccepted`; diretórios escolhidos/importados ficam intactos e
  deixam o Claude controlar o prompt de trust no Terminal quando necessário.
  Nunca pré-aprova imports externos de `CLAUDE.md`; esse consentimento também
  permanece visível. Usa o
  mesmo `resolvedPromptText` do batch; só Claude toca no `.claude.json`, Codex
  nunca.
- `AgendaMath.swift` — pure functions for the fixed cycle (times × weekdays):
  `nextOccurrence`, `lastMissedOccurrence` (single catch-up on wake), and
  `date(bySettingMinutes:ofDay:calendar:)`.
- `TaskScheduler.swift` — per-agendamento timers (fixed ones) driven by
  `AgendaMath`. Transient failures preserve the occurrence and retry with
  bounded exponential backoff; needs-attention/paused/launched outcomes do not
  become hot loops. Dedupe is by fired-occurrence identity (never a wall-clock
  window — adjacent-minute occurrences must both fire); creating/editing a
  task advances a catch-up floor and never counts as a fire.
- `ProviderDoctor.swift` — passive first-run readiness model/view. It separates
  optional vs configured provider, CLI availability and per-account auth for
  native/custom accounts. Checks run Claude/Codex in parallel, preserve stable
  display order and never execute a prompt or login.
- `SkillCatalog.swift` — effective local skills from account/plugin roots plus
  repository ancestors (`.claude/skills` or `.agents/skills`) and Codex user
  `$HOME/.agents/skills`; ascent stops safely at the filesystem root.
- `CodexPluginCatalog.swift` — read-only `codex plugin list --json` inventory
  for the selected `CODEX_HOME`; only installed, enabled, local plugin roots
  with matching manifests are exposed as `plugin:skill`. Responses are
  generation-guarded in the form so an old account lookup cannot overwrite a
  newer selection.
- `SingleInstanceLock.swift` — `flock` por perfil em
  `~/Library/Application Support/Ohayo/instance.lock` ou
  `~/Library/Application Support/Ohayo Dev/instance.lock`. Uma segunda
  instância do mesmo perfil alerta e sai antes de `AppEnvironment` existir;
  produção e desenvolvimento podem coexistir.
- UI: `MenuBarLabel.swift` (just the bar glyph — filled while any account has
  an active window, `!` on error, faded when every scheduled account is
  paused; optional remaining-time text) + `MenuPanel.swift` (the
  `MenuBarExtra` content, `.menuBarExtraStyle(.window)`: the next N tasks to
  fire across all accounts, N = `AppState.panelUpcomingCount` (1–5, default 1,
  a stepper in Ajustes › Geral), ordered by time — paused accounts are
  skipped, so the panel only shows what will actually run. The first event is
  a highlight card, the rest compact rows; each shows provider icon · account
  label · event name · time. Empty states distinguish no schedules, all
  disabled, all paused, lifecycle conflict, missing account, invalid
  configuration, unavailable quota, needs-attention and normal waiting.
  Clicking a card/row opens Ohayo › Schedules filtered to that account (the
  `accountFilter` deep-link);
  no per-account hover actions, no 5h-window remaining, no status dot anymore.
  Plus a header (missing-CLI warning, Quit) + footer (Schedules · History ·
  Settings); pure logic (`upcomingEvents`, `emptyState`, `eventName`) lives in
  `MenuPanelLogic.swift`, testable without UI. Replaces the old native menu
  (`MenuContent.swift`). `AppWindowActions` temporarily adopts regular
  activation while a standard window is visible, then returns to accessory
  mode; `OhayoCommands` preserves `⌘,` for Geral/General. `SettingsView.swift`
  (central Ohayo window sidebar: Agendamentos · Contas · Histórico · Geral;
  the `horarios` case/rawValue is unchanged for persistence, only its displayed
  title is Agendamentos/Schedules) →
  `ContasView` (per-account pause/resume now lives here, alongside
  provider/folder/active-schedule count),
  `HorariosView` (unified agendamento list: fixed header bar with summary ·
  filters (account/provider/status/type) · sort · new-task button; compact
  rows expand on click; per-row manual "run now" via
  `AppEnvironment.fireNow`, origin `.manual`; list logic in the pure
  `HorariosListModel`; also scoped by the menu panel's `AppState.accountFilter`
  deep-link, with a clear-filter chip) + `AgendamentoFormSheet`
  (fixed times as chips via `TimeChipsEditor`, 5h chain generator, day
  presets, next-fire preview), `HistoryTab` (also filterable by
  `accountFilter`, distinguishes Terminal `.launched`, and clears all local
  history behind a destructive confirmation), `GeneralTab` (including the
  default-off sensitive-notification-details toggle). The first-run
  `PermissionSetupView` embeds the passive Provider Doctor before the macOS
  permission controls.

## Commands

```bash
swift build                     # must always compile between changes
swift test                      # full suite
swift test --filter <Class>     # focused
swift run Ohayo                 # run the menu bar app locally
./scripts/make-app.sh           # build/Ohayo.app (ad-hoc unless Developer ID env is set)
./scripts/make-dev-app.sh       # build/Ohayo Dev.app with isolated runtime identity
open "build/Ohayo Dev.app" --args --ui-testing # expose central window for Computer Use
./scripts/make-dmg.sh           # build/Ohayo-<version>.dmg
```

Public tag releases are fail-closed: all Developer ID + notary secrets are
required, tag version must match `Info.plist`, the app is signed with hardened
runtime and the Apple Events entitlement, and the app is universal
(`arm64` + `x86_64`) with deployment target macOS 13. The DMG is
verified/mounted, then notarized and stapled; the mounted distributed app must
pass Gatekeeper and a launch smoke before upload. Local ad-hoc builds remain
supported but are not Gatekeeper-ready. Set
`OHAYO_UNIVERSAL_BUILD=1` to reproduce the universal build locally.

## Observability

`os_log` no subsystem `io.github.hayashirafael.Ohayo` (categorias
`agenda`/`fire`/`env`) marca só decisões e mudanças de estado — fila por conta,
outcome tipado, bootstrap e retry/backoff — mantendo prompt como private. Ao
vivo:

```bash
log stream --predicate 'subsystem == "io.github.hayashirafael.Ohayo"' --level debug
```

## Conventions

- UI strings and code comments in Português (Brasil) with correct accents.
- XCTest; test classes are `@MainActor` when touching `AppState`/engines.
- TDD: write the failing test first. Tests use fakes (`Clock`,
  `SessionDetecting`) — never real timers or sleeps. Exceção:
  `AppEnvironmentTests` exercita a composição real com launcher/notifier/auth
  injetados e um `TaskScheduler` que arma `NSTimer` reais, então datas fake
  DEVEM ficar bem no futuro (ano 2099). O teste de composição de `CODEX_HOME`
  também usa um `CommandRunner` real contra um script controlado, com timeout
  máximo de 5s, para cobrir a borda que um spy de `CommandRunning` não observa.
  Exceção separada e exclusiva a `CommandRunnerTests`: testes de contrato do
  subprocesso real podem bloquear um processo para validar timeout,
  SIGTERM/SIGKILL e encerramento da árvore de PIDs, comportamentos do Darwin que
  um `Clock` fake não reproduz. Devem injetar timeout de no máximo 1s, limitar
  qualquer observação pós-SIGKILL a 2s e nunca dormir para aguardar estado do
  app.
- Commit prefixes: `feat:` / `fix:` / `refactor:` / `docs:` / `test:`.
- READMEs: `README.md` is English, `README.pt-br.md` is Portuguese (there is
  no `README.en.md`); keep them in sync and verify every behavioral claim
  against the source before writing it.
- SourceKit/LSP diagnostics go stale after files change (false "no member"
  errors); trust `swift build` / `swift test`, not the diagnostics.

## Repo hygiene

`CONTEXT.md`, `docs/` and `.superpowers/` are local working notes — never
commit them (they are gitignored). Do not add session trailers or AI-process
footers to commits or PRs in this repo.

## Release flow

Do not create or propose a release for a narrow commit/push request. Create one
only when the user explicitly requests it, using the existing flow:

1. Confirm the next semantic version.
2. Update `scripts/Info.plist` if the app version changes.
3. Commit the changes with the repo-local Git identity.
4. Create and push a `vX.Y.Z` tag.
5. Verify the `release` GitHub Actions workflow finishes successfully.
6. Verify the Homebrew tap cask is updated and `brew upgrade --cask ohayo`
   can see the new version.

Do not assume that pushing `main` updates users. Homebrew users only receive an
update after a new tag/release updates `hayashirafael/homebrew-tap`.
