# Ohayo — Repository Guidance

## Product and scope

Ohayo is a macOS 13+ menu-bar automation control center built with Swift 5.9,
SwiftUI `MenuBarExtra`, Swift Package Manager, and Sparkle. It schedules Claude,
Codex, and shell commands, manages multiple provider accounts, passively
detects supported usage windows from local transcripts, and records outcomes.

Use the domain vocabulary consistently:

- **Account / Conta** belongs to one Provider and is native or custom.
- **Provider / Provedor** is Claude or Codex.
- **Schedule / Agendamento** combines one Command, one Account when applicable,
  and either Continuous or Fixed-times repetition.
- **Usage Window / Janela de uso** exists only with positive evidence.
- **Run / Disparo** is a traceable execution occurrence.

Avoid reviving the legacy product terms “HiClaude”, “renewal”, “message”,
“task”, or “hi” in user-facing copy when the canonical terms above apply.

## Sources of truth

1. Current source and tests are authoritative for behavior.
2. This `AGENTS.md` is authoritative for repository workflow.
3. `CLAUDE.md` is a detailed architecture map and must remain aligned with this
   file and the source.
4. `README.md` is English and `README.pt-br.md` is Portuguese; keep them
   semantically synchronized.
5. `PESQUISA-UI-UX-MACOS-2026-07-29.md` is historical research. Its explicit
   later product decisions override the original recommendations.

If documentation and implementation disagree, verify the implementation and
update both language variants in the same change.

## Architecture invariants

- `AppEnvironment` is the composition root and the single owner of schedule
  reconfiguration, wake handling, and the status timer.
- `AppState` owns persisted user state. Preserve fail-closed decoding and
  canonical account-path identity.
- `AgendamentoEditor` is the schedule-mutation seam. Do not mutate persisted
  schedule collections through parallel ad-hoc paths.
- `DispatchIntent` → `DispatchPreparer` → `PreparedDispatch` is the canonical
  account-aware dispatch path.
- `CLIProcessRuntime` is the only production owner of `Foundation.Process`,
  bounded stdout/stderr capture, timeout, cancellation, stdin closure, and
  process-tree termination.
- Native Claude must run without forcing `CLAUDE_CONFIG_DIR=~/.claude`; custom
  Claude accounts use their override. Codex receives the selected `CODEX_HOME`.
- Provider identity is persisted and passed explicitly. Do not silently
  reinterpret an unavailable custom account as another provider or as the
  default account.
- Transcript parsing and quota detection fail closed. Unknown schemas,
  unreadable data, authentication errors, and zero-token events never create a
  fictional usage window.
- Interactive Terminal hand-off records `launched`, never `success`.
- Continuous recovery is represented by `RenewalSnapshot` and durable typed
  recovery state. Fixed schedules remain independent in `TaskScheduler`.
- Usage-window duration belongs to `Provider`; do not introduce another global
  production assumption.

## UI and macOS behavior

- The app normally runs as an `LSUIElement` menu-bar app. A Dock icon may appear
  only while a standard Ohayo window is open so macOS can focus it.
- The central Ohayo window contains Schedules, Accounts, History, and General.
  Preserve the standard `⌘,` shortcut for General.
- Keep the menu-bar panel compact and use localized, non-wrapping footer labels.
- UI strings and source comments are Portuguese (Brazil) with correct accents;
  every user-facing string must have English and Portuguese coverage through
  `L10n`.
- Automated tests do not prove VoiceOver, Full Keyboard Access, Light/Dark
  Mode, Increase Contrast, focus/Spaces behavior, or macOS 13 compatibility.
  Report those checks separately when they were not exercised manually.

## Development workflow

Use test-driven development for behavior changes:

1. Add or update the focused failing test.
2. Implement the smallest coherent production change.
3. Run the focused tests.
4. Run the full suite.
5. Validate packaging when UI, resources, entitlements, Sparkle, scripts, or
   release behavior changed.

Primary commands:

```bash
swift build
swift test
swift test --filter <TestClass>
swift run Ohayo
./scripts/make-app.sh
OHAYO_UNIVERSAL_BUILD=1 ./scripts/make-app.sh
./scripts/make-dmg.sh
```

Tests use injected clocks, detectors, runners, authentication, launchers, and
notifiers. Do not depend on real provider credentials or execute real prompts.
Avoid sleeps and real timers except in the existing narrowly documented
subprocess and composition tests.

After code or documentation changes, run:

```bash
swift test
git diff --check
```

For packaged-app validation, also run:

```bash
./scripts/make-app.sh
plutil -lint build/Ohayo.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 build/Ohayo.app
```

## Documentation

- Keep README headings, feature lists, navigation labels, requirements, update
  behavior, and installation instructions equivalent in both languages.
- Prefer durable statements such as “releases since v1.2.0” over duplicating a
  latest-version number that will immediately drift.
- Distinguish passive provider-window detection from Sparkle’s GitHub network
  access.
- Treat an optional skill as schedule configuration, not as a sidebar section.
- Update `CLAUDE.md` whenever architecture names, ownership, navigation, or
  validation commands change.

## Git, CI, and releases

- Preserve unrelated working-tree changes and inspect status before editing.
- Commit prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, or `test:`.
- Do not add AI/session trailers to commits or pull requests.
- A request to commit and push does not authorize a PR, tag, release, app
  installation, or Homebrew publication.
- Create a release only when explicitly requested. Then verify version parity
  with `scripts/Info.plist`, the release workflow, signed `appcast.xml`,
  universal architectures, and the Homebrew cask update.

## Repository hygiene

`CONTEXT.md`, `.superpowers/`, and `docs/` outside `docs/agents/` are ignored
local working notes. Do not add them to commits. `docs/agents/` is tracked
configuration for the engineering skills. Never expose credentials, provider
auth files, account transcripts, prompts, or personal account paths in tests,
logs, documentation, screenshots, commits, or pull requests.
