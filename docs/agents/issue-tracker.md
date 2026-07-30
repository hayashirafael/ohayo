# Issue tracker: private GitHub repository

Issues and PRDs for Ohayo live in the private GitHub repository
`hayashirafael/ohayo-private-tracker`. Use the `gh` CLI for all operations and
always target that repository explicitly. The public `hayashirafael/ohayo`
repository hosts the source code and does not host the working issue backlog.

The private tracker is accessible only to the `hayashirafael` account. Before
tracker operations, verify `gh auth status --active`; if another account is
active, switch with
`gh auth switch --hostname github.com --user hayashirafael` and restore the
previous active account when finished.

## Conventions

- **Create an issue**: `gh issue create -R hayashirafael/ohayo-private-tracker --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> -R hayashirafael/ohayo-private-tracker --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list -R hayashirafael/ohayo-private-tracker --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> -R hayashirafael/ohayo-private-tracker --body "..."`
- **Apply / remove labels**: `gh issue edit <number> -R hayashirafael/ohayo-private-tracker --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> -R hayashirafael/ohayo-private-tracker --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.**

## When a skill says "publish to the issue tracker"

Create an issue in `hayashirafael/ohayo-private-tracker`.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> -R hayashirafael/ohayo-private-tracker --comments`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create -R hayashirafael/ohayo-private-tracker --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue. Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body.
- **Blocking**: use GitHub's native issue dependencies. Where dependencies aren't available, use a `Blocked by: #<n>` line at the top of the child body.
- **Claim**: `gh issue edit <n> -R hayashirafael/ohayo-private-tracker --add-assignee @me`.
- **Resolve**: comment with the answer, close the issue, then append a context pointer to the map's Decisions-so-far.
