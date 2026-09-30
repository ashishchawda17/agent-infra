---
name: verify
description: "Work the judgment tier of the freshness queue with agents: re-check stale last_verified and low-confidence notes against their source: code, and repair dead [[wikilinks]] whose target exists under another name. One subagent per finding, one PR per batch. Never rewrites a fact, never invents an anchor, never raises confidence to high. Trigger: /brain:verify [--max N], or 'verify the stale notes' / 'work the freshness queue'."
---

# /brain:verify — work the judgment tier of the freshness queue

## Portable hosts and URL-backed vaults

In Codex, Grok Build, Grok Bot, or a project using a .brain/config.json binding, read [the shared workflow](../../references/portable.md) first and use its matching command flow. It supplies neutral configuration, isolated sessions, and host-specific adaptations. For legacy Claude projects, the workflow below remains supported.


Companion to `/brain:freshness` and `/brain:tidy`. Freshness produces the queue; tidy applies its **mechanical** tier; verify works the **judgment** tier that tidy leaves alone: stale `last_verified`, low `confidence`, and dead `[[wikilinks]]`. One subagent checks each finding against code, and the whole batch ships as **one PR**. The human reviews the PR, not each note. The only part they must read is the **could-not-tell** list.

Resolve the vault root as `$BRAIN_ROOT` (else the current project dir / cwd).

**Hard limits. Never cross these, whatever a subagent concludes:**
- **Never rewrite a fact.** A claim the code contradicts gets a `status:` and a one-line reason. Its body is not edited. If the body should change, that is a draft for `/brain:promote`, not an edit here.
- **Never invent an anchor.** A note whose `source:` does not resolve to a file on this machine is skipped and listed. Do not guess a path, and do not re-anchor it (moved anchors are `/brain:tidy`'s job).
- **Never raise `confidence` to `high`.** Verification raises `low` to `medium` at most. `high` is a person's call (see `/brain:promote`).
- **Never delete or archive a note**, and never touch `wiki/_drafts/` notes' `last_verified` or `confidence`. Drafts are `/brain:promote`'s queue.
- Trusted-note edits land via branch + PR per the vault's `CLAUDE.md`. Trusted areas are deliberately outside `.saveinclude`, so this skill stages its notes explicitly (step 6), the same way `/brain:promote` and `/brain:tidy` do.

## What to do when invoked

Arguments: `--max N` caps the findings worked this run (default **25**), so a first run on a vault with 100+ findings produces a PR a person can actually review. The rest stay in the queue for the next run.

### 0. Open a session record, before any file work

On the vault's protected/default branch, `--start` **creates the working branch**, so it must run before anything is read or written. It also publishes that this session is live, so it cannot collide with a concurrent `/brain:save`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --start verify   # from the vault root, or with BRAIN_ROOT=<vault> set
```

- **Exit `0`, first line `SESSION: OK` →** recorded, and you are on a working branch. Keep the second line (`pin: <branch>:<sha>`); step 6 checks it. Go on to step 1.
- **Exit `0`, first line `SESSION: WARN` →** proceed, but **another session is live against this vault.** Relay the script's `SESSION: WARN` line to the user **verbatim**. It names the other session's branch and pid, so do not paraphrase or re-derive it.
- **Exit `1`, first line `SESSION: REFUSED` →** **stop here and change nothing.** Relay the script's `SESSION: REFUSED` line to the user **verbatim** (it names the reason and the remedy), and **do not work around it with a raw `git checkout` / `git switch`.**

### 1. Scan fresh, as data

Never work from an old report: a finding in yesterday's `logs/freshness-*.md` may already be fixed.

```bash
F="$(mktemp)"
node "${CLAUDE_PLUGIN_ROOT}/bin/freshness.mjs" --json > "$F"   # writes no logs/ report
```

Keep only the three judgment kinds. Drop `wiki/_drafts/` notes from `stale` and `low-confidence`, and drop notes already marked `status: superseded` or `falsified` (they already say what is wrong). Group by note: a note that is both stale and low-confidence gets **one** check, not two. Order: dead links first (cheapest), then stale notes oldest first, then low-confidence. Take the first `--max` findings. Use `node -e`, not `jq`, which is not assumed:

```bash
node -e '
  const fs = require("fs"), path = require("path");
  const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const frontmatter = (n) => fs.readFileSync(path.join(process.argv[3], n), "utf8").split("---")[1] || "";
  const marked = (n) => /^status: *(superseded|falsified)/m.test(frontmatter(n));
  const skip = (n) => n.startsWith("wiki/_drafts/") || marked(n);
  const dead = a.filter((f) => f.kind === "dead-link");
  const stale = a.filter((f) => f.kind === "stale" && !skip(f.note)).sort((x, y) => y.age - x.age);
  const low = a.filter((f) => f.kind === "low-confidence" && !skip(f.note));
  for (const f of [...dead, ...stale, ...low].slice(0, Number(process.argv[2]) || 25)) console.log(JSON.stringify(f));
' "$F" 25 "${BRAIN_ROOT:-$PWD}"
```

Nothing left → report "judgment queue empty", close the session (step 7), stop.

### 2. Resolve anchors first; skip what cannot resolve

For every stale or low-confidence note, run the shared anchor gate:

```bash
node "${CLAUDE_PLUGIN_ROOT}/bin/check-anchors.mjs" <note.md> [...]
node "${CLAUDE_PLUGIN_ROOT}/bin/resolve-repos.mjs" --print-paths      # repo name<TAB>local checkout
```

A note whose anchor is **broken**, **unverifiable** (no checkout, unknown prefix, unfetched pinned rev, git-ignored), **external** (PR/URL), or absent goes straight to **could-not-tell** with the gate's reason. Do not dispatch a subagent for it. `check-anchors.mjs` is the same resolver freshness uses, so do not second-guess its verdict by reading the path yourself.

**Read code on the reference branch, never a working tree.** The reference branch is the repo's `branch` in `repos.json` when that field is present, else the checkout's detected default (`git symbolic-ref refs/remotes/origin/HEAD`, and when that is missing, check the host with `gh repo view --json defaultBranchRef`). `git fetch` it first, then read with `git -C <checkout> show origin/<branch>:<path>` and search with `git -C <checkout> grep <pattern> origin/<branch> -- <path>`. Another session may have that checkout dirty or on a feature branch.

### 3. Check for open PRs touching the same notes

```bash
git fetch --prune
for n in $(gh pr list --json number --jq '.[].number'); do
  echo "--- #$n"; gh pr diff "$n" --name-only
done
```

A note an open PR already edits is dropped from this batch and listed as blocked, with the PR number. `gh` missing, unauthed or offline → one line saying the check was skipped, then continue.

### 4. Dispatch one subagent per finding

Subagents are **read-only**: they return a verdict and never edit a file. This session applies every write (step 5), so the vault and its git index have exactly one writer. Dispatch in parallel. Each gets the note's path, its `source:` anchor, the resolved checkout and reference branch, and one of these briefs:

- **Stale / low-confidence note:** "Read the note. Read the anchored code on `origin/<branch>` with `git show` / `git grep`. Decide whether each factual claim the note makes still holds. Return exactly one JSON object: `{\"note\": \"...\", \"verdict\": \"holds\" | \"superseded\" | \"falsified\" | \"cannot-tell\", \"reason\": \"<one line citing file:line on origin/<branch>>\"}`. `holds` only if every claim holds. `superseded` means the code once said this and has since changed. `falsified` means the code does not and did not say this. `cannot-tell` means the code does not settle it either way. When in doubt, answer `cannot-tell`."
- **Dead link:** "Note `<note>` links `[[<target>]]`, which resolves to nothing. Search `wiki/**/*.md` (including `wiki/_drafts/`) for a note that is plainly the same subject under another name: a renamed basename, an `aliases:` entry, a heading, an `id:`. Return `{\"note\": \"...\", \"target\": \"...\", \"verdict\": \"found\" | \"none\", \"replacement\": \"<basename>\", \"reason\": \"<one line>\"}`. Only `found` with one unambiguous candidate. Two plausible candidates is `none`."

### 5. Show the plan, then apply

Show the full plan compactly as the four-part table (step 6's format) plus blocked and skipped notes. **Wait for a yes.** If the user pre-authorized ("just verify them"), proceed. Then apply, **frontmatter and link text only**:

| Verdict | Edit | Nothing else changes |
| --- | --- | --- |
| `holds` (stale) | `last_verified:` → today (`date +%F`) | body, `confidence`, `status` |
| `holds` (low-confidence) | `confidence: low` → `medium`, and `last_verified:` → today | body, `status` |
| `superseded` / `falsified` | add or set `status: <verdict>`. Insert **one line** immediately after the closing `---`: `> **Status (<today>, /brain:verify):** <verdict>: <reason>` | `last_verified` (**not** bumped: the note was not confirmed), `confidence`, the rest of the body |
| `cannot-tell` | none. List it | everything |
| dead link `found` | rewrite `[[<target>` → `[[<replacement>` in that note (keep any `\|alias` / `#heading`) | everything else |
| dead link `none` | none. List it | everything |

Preserve each file's line endings (vault notes are often CRLF) and any trailing YAML comment on an edited line. Then **re-run the scan** (`freshness.mjs --json`): the fixed findings must be gone, and no new dead link may appear. A typo'd replacement creates one, so fix it before shipping.

### 6. Commit and open one PR

Confirm HEAD is still the branch on step 0's `pin:` line (`git rev-parse --abbrev-ref HEAD`). If it moved, **stop**: another session switched the checkout, and committing here lands on a branch you never chose. Then stage **only** the notes you edited, and check the index holds nothing else (it is shared with every session in this checkout):

```bash
git add -- <each edited note>
git diff --cached --name-only        # must list exactly those notes, and nothing more
git commit -m "verify: <V> verified, <C> status set, <L> links fixed (<date>)"
git push -u origin HEAD && gh pr create --title "brain:verify <date>" --body-file <body.md>
```

Anything else staged → unstage your notes, stop, and report the stray paths. Never commit someone else's staged work.

The PR body carries one table in four parts. The **could-not-tell** part is the one a person must read:

```markdown
| Part | Note | Result | Evidence |
| --- | --- | --- | --- |
| Verified (bumped) | wiki/x.md | last_verified 2026-06-01 → <today>; confidence low → medium | repo/src/a.ts:42 on origin/main |
| Changed (status set) | wiki/y.md | status: superseded: retry limit is now 5, not 3 | repo/src/b.ts:10 on origin/main |
| Fixed links | wiki/z.md | [[old-name]] → [[new-name]] | renamed 2026-08-02 |
| Could not tell | wiki/w.md | anchor unverifiable: repo `foo` not checked out | check-anchors.mjs |
```

Add the before/after judgment-queue counts, the blocked notes (open-PR overlap), and how many findings were left in the queue by `--max`.

### 7. Close the session record

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/session.sh" --end   # from the vault root, or with BRAIN_ROOT=<vault> set
```

Run it once the PR is open, or on any early exit (empty queue, no approval, a refused commit).

## Notes

- Idempotent: a re-run skips everything it verified (no longer stale) and everything it gave a `status:` (step 1 drops marked notes), and re-lists could-not-tell.
- `last_verified` means "re-checked against source". Bumping it without reading the code is the one failure this skill exists to prevent. A `cannot-tell` is a correct answer, and a bump for a claim the code contradicts is not.
- Writes are limited to trusted notes' frontmatter, one status line per changed note, `[[link]]` text, and the vault git branch. No `logs/` report is written.
