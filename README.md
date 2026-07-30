# Ohayo

**English** | [Português](README.pt-br.md)

macOS menu bar automation control center for Claude, Codex, and shell commands.
It can chain supported 5-hour usage windows per account and run schedules
automatically. Swift + SwiftUI (`MenuBarExtra`), with Sparkle for secure in-app
updates.

## Why

Claude plans (Pro/Max) open a 5-hour usage window from your first prompt. If
you're a heavy user, you want that window already open when you sit down to
work — not to burn its first hour warming up. Ohayo renews each account on
its own, and a continuous schedule never runs redundantly while a window is
already active. The detector reads local Claude/Codex transcripts passively
and makes no provider API calls; Sparkle separately checks GitHub for signed
app updates.

## Features

- **Unified schedules** — one concept for everything scheduled. Each
  schedule carries an embedded command and a repetition: **Continuous**
  (chains 5-hour windows and starts automatically when no active-window
  evidence exists, unless you turn that behavior off) or **Fixed times**
  (times × weekdays). Managed in the **Schedules** section
- **Configurable commands** — a Claude prompt (model, effort, safe-mode,
  working directory), a Codex prompt (models and reasoning efforts discovered
  from the selected account, full access by default with folder-write and
  read-only alternatives, working directory), or any shell command — embedded
  directly in the schedule.
  Claude/Codex prompts open in Terminal.app by default so you can keep
  interacting in the same session; turn that off to run them in batch mode
- **Multi-account, Claude and Codex** — the default dirs (`~/.claude`,
  `~/.codex`) are picked up automatically when they exist; other `~/.claude*`
  dirs are detected once, on first launch, and from then on you add accounts
  anytime via "Add account…" — shows the logged-in email, supports custom
  aliases
- **History and response files** — recent runs with status and expandable
  response (Markdown is rendered when selected, while failure stdout/stderr
  remains available), including a distinct **Launched** state for interactive
  Terminal sessions. Batch Claude/Codex responses can be saved as `.md`
  (default) or `.txt` in a chosen folder, with favorite folders available for
  reuse
- **Private notifications by default** — macOS notifications hide prompt,
  response, error and account details unless you explicitly enable them in
  **General**
- **Provider Doctor** — first-run, read-only checks for CLI installation and
  login status for every configured Claude/Codex account; it never runs a
  prompt or consumes quota
- **Language** — English by default, with a Portuguese option in **General**
- **In-app updates** — checks the signed GitHub release feed automatically;
  install and relaunch without downloading a DMG manually
- Per-account **Pause/Resume**, in **Accounts**, and optional **Launch at
  Login**

## Requirements

- macOS 13+; published releases since v1.2.0 are universal for Apple Silicon
  and Intel
- [Claude Code](https://claude.com/claude-code) installed and logged in
  (only if you use Claude schedules)
- [Codex CLI](https://github.com/openai/codex) installed and logged in
  (optional, only for Codex accounts/commands)
- To build from source: Swift 5.9+ (Xcode or Command Line Tools)

Ohayo checks the selected Claude or Codex account immediately before each
scheduled run. If the account is not logged in, the run is recorded without
opening a session; the history shows the exact login command with the selected
account directory. If a CLI fails for another reason, the history details
preserve stdout and stderr when available.

## Install

### Homebrew

```bash
brew tap hayashirafael/tap
brew trust --cask hayashirafael/tap/ohayo
brew install --cask ohayo
```

Homebrew installs the latest published release. Installations older than v1.2.0
need one final `brew upgrade --cask ohayo`; after that, future releases can
also be installed from **Ohayo → General → About → Check for Updates…**.

### DMG

Download `Ohayo-<version>.dmg` from the
[latest release](../../releases/latest) and drag **Ohayo** onto
**Applications**.

> Published releases since v1.2.0 are universal for Apple Silicon and Intel.
> Existing ad-hoc tester builds can lose macOS privacy authorization after an
> update because their code identity is not stable. New public releases from
> this revision are blocked unless they are signed with Developer ID, hardened,
> notarized, and stapled. Local source builds remain ad-hoc and can therefore
> ask for protected-folder access again after each rebuild.

### From source

```bash
git clone https://github.com/hayashirafael/ohayo.git
cd ohayo
swift test            # test suite
./scripts/make-app.sh # build/Ohayo.app (ad-hoc signed)
./scripts/make-dmg.sh # build/Ohayo-<version>.dmg (needs `brew install create-dmg`)
open build/Ohayo.app
```

For an isolated local build that can run alongside the DMG-installed app:

```bash
./scripts/make-dev-app.sh
open "build/Ohayo Dev.app"
orca computer get-app-state --app io.github.hayashirafael.Ohayo.dev --json
```

If Computer Use cannot inspect the menu bar surface directly, expose the
central app window in the development channel with:

```bash
open "build/Ohayo Dev.app" --args --ui-testing
```

`Ohayo Dev.app` uses the `io.github.hayashirafael.Ohayo.dev` bundle identifier,
`~/Library/Application Support/Ohayo Dev`, a separate single-instance lock and
preferences domain. In-app updates and Launch at Login are unavailable in this
channel. Its blue icon carries a visible **DEV** badge so it remains distinct
from production in the Dock and app switcher. Development starts without
copying accounts, schedules, history or preferences from the production app.

### Updates

Version 1.2.0 introduced the updater. Installations without Sparkle need one
final manual Homebrew/DMG upgrade. Releases from 1.2.0 onward check the signed
feed daily and offer **Install and Relaunch** in-app. Use **Ohayo → General →
About → Check for Updates…** to check immediately.

Release archives and the feed are cryptographically validated by Sparkle's
separate EdDSA key. The GitHub release workflow now fails closed unless all
Developer ID, notarization, and Sparkle credentials are present; it publishes
the notarized DMG and signed `appcast.xml` together.

## Quick start

1. Open Ohayo and complete or dismiss the non-blocking setup guide.
2. In **Accounts**, confirm the Claude/Codex accounts you want to use.
3. In **Schedules**, choose **New Schedule…** and configure its command.
4. Select **Continuous** to chain detected usage windows, or **Fixed times** for
   specific times and weekdays.
5. Use the menu bar panel for upcoming runs and **History** for outcomes and
   captured failure details.

## Usage

Ohayo lives in the menu bar with no permanent Dock icon. macOS shows a Dock
icon only while a standard Ohayo window is open so that window can receive
focus. The menu bar icon is filled while any account has an active window,
shows `!` on error, and fades when every scheduled account is paused;
optionally it also shows the time until the soonest window expires.

Clicking the icon opens a panel with the next scheduled runs across all
accounts — how many is configurable in **General** (1–5, default 1) —
ordered by time; paused accounts are skipped, so it only shows what will
actually run. The first is a highlight card, the rest compact rows: provider
icon, account label, schedule name, and time. If there's nothing to show, the
panel explains why (no active schedules, every account paused, or just
waiting for the next window/time). Clicking a card or row opens
**Ohayo → Schedules** filtered to that account. The footer has **Schedules**,
**History** and **Settings…**. A missing CLI becomes an actionable setup
warning; Settings, Permissions, and **Quit Ohayo** are grouped under the
secondary actions menu.

The central **Ohayo** window opens on **Schedules** and has a sidebar with four
sections:

- **Accounts** — for each account, the logged-in identity / alias, provider
  with its icon, local folder, how many active schedules target it, and
  per-account **Pause/Resume**. Add or remove accounts here
- **Schedules** — the single list of schedules. Each has a name, a type
  (Claude / Codex / shell command) with its own config, an account, and a
  repetition — **Continuous** (chains 5-hour windows, max one per account)
  or **Fixed times** (times × weekdays). One form creates or edits any of them;
  new schedules start with an empty command field. Jumping in from a schedule in
  the menu panel filters this list to that account, with a chip to clear the
  filter
  - **Optional skill:** for Claude/Codex schedules, pick a skill installed in
    the target account, user scope, or selected repository. Ohayo resolves
    Claude account/plugin skills plus ancestor `.claude/skills`, and Codex
    account skills plus `$HOME/.agents/skills`, ancestor `.agents/skills`, and
    skills exposed by plugins that the selected account reports as installed
    and enabled through `codex plugin list --json`. The inventory check is
    read-only and never runs a prompt. Each run prefixes the skill to the
    command (`/skill command` for Claude, `$skill command` for Codex). Selecting
    a skill loads Claude customizations; the UI makes clear that this expands
    context and is not a filesystem sandbox
- **History** — recent runs as cards with status, provider icon, model,
  account alias/email, command, rendered Markdown response, saved-file link
  and error details; filterable by account the same way as Schedules
- **General** — Launch at Login, time remaining in the menu bar, sensitive
  notification details (off by default), how many upcoming runs the menu panel
  shows (1–5), Language (English or Portuguese), system access, the app
  version, and **Check for Updates…**. Open it from **Settings…** or with `⌘,`

### First-run permissions

The packaged app opens a non-blocking setup guide once. Its Provider Doctor
checks which Claude/Codex CLIs and configured accounts are ready, and shows the
correct login command when attention is needed. These checks are read-only:
they never execute a prompt, start a login, or consume quota. You can also
allow notifications, test the Terminal automation used for interactive
sessions, and optionally enable Launch at Login. Closing the guide does not
disable the app; reopen it from the menu panel’s secondary actions or
**Ohayo → General → System Access → Permissions…**.

If notifications or Terminal automation were denied, change them in **System
Settings → Notifications → Ohayo** or **System Settings → Privacy & Security →
Automation**, then reopen the guide to refresh or test the integration.

When you save a Claude schedule with **Trust this folder for Claude** enabled,
or a Codex schedule using **Full access** or **Folder write**, Ohayo checks
access immediately. For a folder protected by macOS, such as Documents, choose
**Allow** in the system prompt. A Developer ID-signed Ohayo keeps that
authorization across updates; an ad-hoc local/test rebuild has a different
code identity and macOS may ask again. The app cannot click or grant this
privacy permission on your behalf.

## How it works

To maintain Continuous Repetitions, Ohayo streams the account's local transcripts
(`<account>/projects/**.jsonl` for Claude, `sessions/**.jsonl` for Codex,
ordered by `mtime`) and reconstructs the current 5-hour window. It accepts only
positive usage evidence: a real, non-error Claude assistant event with token
usage, or a Codex `token_count` event with positive `last_token_usage`.
Synthetic/auth/model/network failures and zero-token events do not create a
fictional window. Unreadable transcripts or an unknown usage schema become an
explicit unavailable state and never trigger a bootstrap. If a window is
active, only a redundant continuous run is skipped; fixed-time schedules
always run.

A Claude run launches:

```
claude -p --model <model> --effort <effort> [--safe-mode]
```

The prompt is written to stdin rather than exposed in the process argument
list. The native Claude account deliberately runs with
`CLAUDE_CONFIG_DIR` unset, because exporting `~/.claude` changes Claude Code's
account semantics; custom Claude profiles receive the override. Codex receives
the selected `CODEX_HOME`, defaulting to `~/.codex`. Shell schedules receive
neither provider variable.

If the schedule has a skill, the prompt is prefixed before the run (`/skill
command` for Claude, `$skill command` for Codex). For Claude this requires
customizations to be loaded; “ignore Claude customizations” is not presented
as a sandbox.

By default, Claude/Codex open in Terminal.app without `-p` / `exec`, so the
interactive session stays open. Opening Terminal is recorded as **Launched**,
not as a completed run: Ohayo cannot observe that session's final exit status.
A fixed-time interactive schedule still opens at its scheduled time when an
account has an active window. With no working directory, interactive and batch
provider runs use `~/Library/Application Support/Ohayo/workspace` instead of
your home directory (or the isolated `Ohayo Dev/workspace` equivalent). The
private temporary launch script is mode `0600`, removes itself on exit/signals,
and stale crash residues are cleaned up.

After you choose a working directory, Ohayo can request folder access when the
schedule is saved. Claude keeps a dedicated **Trust this folder for Claude**
option, enabled by default, which records only basic project trust. Codex uses
one **Access** control with three explicit modes: **Full access** (default,
without sandbox or approval prompts), **Folder write** (trusted folder with a
`workspace-write` sandbox), and **Read-only** (no pre-authorized folder trust).
Interactive trusted Codex sessions receive an ephemeral official
`projects.<path>.trust_level="trusted"` override; Ohayo never rewrites
`config.toml`. External `CLAUDE.md` imports are never pre-approved, so their
separate consent remains visible.

The built-in Claude defaults — Haiku, low effort, ignored customizations and
`1+1` — provide a minimal command for Continuous Repetition. Ohayo reads the
selected Codex account's `models_cache.json` to offer only listed models and
their supported reasoning efforts, with a current built-in fallback when that
cache is unavailable. A batch Codex run launches `codex exec [--model <model>]`
with `--dangerously-bypass-approvals-and-sandbox` for **Full access**,
`--sandbox workspace-write` for **Folder write**, or `--sandbox read-only` for
**Read-only**, followed by `--skip-git-repo-check --color never` and an optional
reasoning override. The same access mode applies to interactive Terminal
sessions, and the batch prompt always comes from stdin. When model or reasoning
is set to **Account default**, Ohayo omits the corresponding flag so
`config.toml` wins.

When **Show response** is enabled for a batch Claude/Codex schedule, the full
captured response is saved atomically as Markdown (default) or plain text in
the selected folder; the default is
`~/Library/Application Support/Ohayo/Responses` (or the isolated
`Ohayo Dev/Responses` equivalent). Favorite folders are stored locally for
reuse. History keeps a bounded preview, renders Markdown, and links to the
saved file. Batch duration limits are optional per schedule and disabled by
default. Enable **Limit duration** and enter any positive whole number of
minutes; interactive Terminal sessions are not supervised by a timeout.
Captured process output is bounded while preserving both its beginning and
error-bearing tail.

Only one Ohayo instance runs at a time. Within it, runs are FIFO per
provider/account instead of being silently discarded by one global lock;
different accounts can advance concurrently. Transient failures retry with
bounded exponential backoff, while missing authentication/CLI or Terminal
permission becomes a needs-attention state rather than an alert loop.

Which account is Claude vs. Codex is inferred from folder content, not name,
in this order: a `.claude.json` means Claude; else an `auth.json` means Codex;
else a `projects/` subfolder means Claude; else a `sessions/` subfolder means
Codex. The provider of a registered custom account is also persisted, so a
temporarily missing or ambiguous folder is not reinterpreted as another
provider; run and quota checks receive that identity explicitly.
Existing account folders use their canonical filesystem path as identity.
Registering or selecting a symlink to the same Claude/Codex account therefore
does not create another queue, schedule, pause state or quota cooldown.

A new **Continuous** schedule tries to start automatically when no active-window
evidence exists. This is also the compatibility default for continuous
schedules created by older Ohayo versions. Turn off **Try to start when no
active window is detected** to keep a schedule waiting instead. The form warns
that the command may consume provider quota.
After a delivered bootstrap attempt, Ohayo waits up to five hours before
trying another one for that schedule, including across app restarts; if a real
window appears first, its transcript replaces the cooldown. Known transient
failures retain their shorter exponential retry, measured after the failure
returns. A scheduled hand-off keeps its own crash-recovery cooldown even when
automatic start has been explicitly turned off. Authentication, CLI,
permission or configuration errors stop in a needs-attention state instead of
becoming another cooldown. Pausing the account or turning the option off
cancels bootstrap work.
After a window is detected, Ohayo arms at its end and chains the next one; a
redundant attempt is skipped while the account window is active.
A **Fixed times** schedule always runs at its times × weekdays, in either batch
or interactive mode. On wake, fixed times runs at most once to catch up the
most recent occurrence missed — a long sleep never triggers a burst of
backlogged runs, and launch itself never replays occurrences missed before it.
