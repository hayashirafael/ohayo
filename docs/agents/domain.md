# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repository root.

If it doesn't exist, proceed silently. Domain documentation is created lazily
when terms are resolved.

## File structure

This is a single-context repository:

/
├── CONTEXT.md
└── Sources/

## Use the glossary's vocabulary

When output names a domain concept—in an issue title, refactor proposal, hypothesis, or test name—use the term defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If a required concept isn't in the glossary, reconsider whether the language belongs to the project or note the gap for the domain-modeling workflow.
