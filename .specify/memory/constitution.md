# agent-infra Constitution

> The single per-project contract that AI agents and humans follow in this repo.
> The **Stack Profile** below is the only section that must change between
> projects — everything else is meant to be portable. The workflow skills
> (`/preflight`, `/onboard`, `/standup`) read the Stack Profile so they stay
> language-agnostic across Flutter, Next, Nest, Java, etc.

## Stack Profile

| Key | Value |
|-----|-------|
| Language / runtime | Bash 3.2-portable shell + Node 20 (ESM `.mjs`, no dependencies) |
| Package manager | none |
| Install deps | none |
| Test | Only the suites mapped to the files you changed, run one at a time: `brain/bin/<name>.{sh,mjs}` → `bash tests/test-<name>.sh`. Never the whole `tests/` set locally and never in parallel — on Windows/Git Bash that takes hours (see `.claude/wave/notes.md`). |
| Lint / static analysis | `bash tests/test-bash32-portability.sh` whenever any `.sh` changed |
| Format | none |
| Build | none |
| Version check | `bash tools/check-version-bump.sh origin/main`. A behaviour change adds a `.bumps/<plugin>/<TICKET>` fragment; never edit a `version` field on a branch. |
| Run / dev | none (plugins are loaded by Claude Code) |
| **CI gate** (all must pass before merge) | Local: the mapped Test suites + Lint + Version check. Full: GitHub Actions `CI` — every `tests/test-*.sh` on ubuntu and windows, plus `version-bump`. CI is the authority on the full suite. |

## Core Principles

### I. Test-First (NON-NEGOTIABLE)
Write the test before the implementation. Red → green → refactor. The suite
stays green; run the Test command before every commit.

### II. Conventions over cleverness
Match the surrounding code's patterns, naming, and structure. Read the project
docs (CLAUDE.md / README) before introducing a new pattern. Delete unused code
rather than leaving compat shims.

### III. Small, reversible changes
Prefer the smallest diff that solves the problem. One concern per PR. Don't
refactor unrelated code inside a feature PR.

### IV. Readable by default
Code should explain itself; comment only the non-obvious *why*. No dead code, no
speculative abstraction (YAGNI).

### V. Resource & correctness awareness
Respect the project's runtime constraints (memory, latency, money/precision).
Handle errors explicitly; never swallow failures silently.

## Branch & PR Conventions
- **Branch names:** any topic branch off `main`. Worktree branches are
  `<github-user>/innov-<n>`, as wave workers and Orca create them; otherwise
  `feat/`, `feature/` or `fix/` + a short ticket-or-topic slug. A personal
  handle prefix is fine. Never commit to `main` directly.
- **Commits:** imperative and scoped, e.g. `fix(verify): … (INNOV-123)`.
- **PRs:** target `main`, link the INNOV ticket, summarize what changed and why,
  include test evidence, and confirm the CI gate passed.

## Quality Gates (enforced by `/preflight`)
1. All Stack Profile CI commands pass (test, lint, version check).
2. Branch name matches the conventions above.
3. No debug leftovers or new TODOs without a ticket.
4. Docs updated if behavior or contracts changed.

## Governance
This constitution supersedes ad-hoc practice. Amend it by editing this file with
a version bump and a one-line rationale. Detailed, repo-specific gotchas live in
the project's CLAUDE.md and `.claude/wave/notes.md`, and are binding extensions
of Principle II.

**Version**: 1.0.0 | **Ratified**: 2026-09-30 | **Last Amended**: 2026-09-30
