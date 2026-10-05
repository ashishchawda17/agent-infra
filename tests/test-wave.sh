#!/usr/bin/env bash
# test-wave.sh — the wave plugin's per-repo config contract.
#
# Wave runs in any repo, so everything project-specific comes from the target
# repo's .claude/wave/config.env (+ optional notes.md). This suite pins that:
# no config fails loudly; the worker prompt carries the configured tracker,
# states, base branch and project notes; the review/tiebreak paths it hands the
# worker are absolute and exist (a worker runs in another session, where a
# repo-relative path to a plugin script is empty); triage reads Jira JSON.
#
# Run:  bash tests/test-wave.sh   (from anywhere)
# No network, no Orca: only DRY_RUN and triage's no-model path are exercised.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
WAVE="$REPO_ROOT/wave/skills/wave"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL $1"
  shift
  local l
  for l in "$@"; do echo "     $l"; done
}
assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]" "actual:   [$3]"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: [$3]" "actual: [$2]"; fi
}
assert_not_contains() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: [$3]"; fi
}

if ! command -v python >/dev/null 2>&1; then
  echo "SKIP: no python on PATH — wave's scripts use it for JSON." >&2
  exit 0
fi

# A scratch repo whose origin/HEAD points at origin/trunk, with the given config.
new_sandbox() { # config-body
  BOX="$(mktemp -d "$TMPROOT/boxXXXXXX")"
  git -C "$BOX" init -q -b trunk
  git -C "$BOX" config user.email t@t.t
  git -C "$BOX" config user.name t
  git -C "$BOX" commit -q --allow-empty -m initial
  git -C "$BOX" update-ref refs/remotes/origin/trunk HEAD
  git -C "$BOX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  if [[ -n "$1" ]]; then
    mkdir -p "$BOX/.claude/wave"
    printf '%s\n' "$1" >"$BOX/.claude/wave/config.env"
  fi
}

JIRA_CONFIG="WAVE_TRACKER=jira
WAVE_JIRA_SITE=example.atlassian.net
WAVE_QUEUE='project = ABC AND labels = agent-ready'
WAVE_STATE_START='In Progress'
WAVE_STATE_DONE='Validate'
WAVE_FILE_TO='Jira project ABC'"

spawn_dry() { # extra-env...
  (cd "$BOX" && env DRY_RUN=1 "$@" bash "$WAVE/spawn.sh" ABC-7) >"$BOX/out.txt" 2>&1
  echo $?
}

echo "--- 1. no config fails loudly and names the file ---"
new_sandbox ""
st="$(spawn_dry)"
assert_eq "no-config/exit-1" "1" "$st"
assert_contains "no-config/names-file" "$(cat "$BOX/out.txt")" ".claude/wave/config.env"

echo "--- 2. a missing required key is named ---"
new_sandbox "WAVE_TRACKER=jira"
st="$(spawn_dry)"
assert_eq "missing-key/exit-1" "1" "$st"
assert_contains "missing-key/names-key" "$(cat "$BOX/out.txt")" "WAVE_QUEUE"

echo "--- 3. jira config drives the worker prompt ---"
new_sandbox "$JIRA_CONFIG"
st="$(spawn_dry AUTO_SUCCESSOR=1)"
out="$(cat "$BOX/out.txt")"
assert_eq "jira/exit-0" "0" "$st"
assert_contains "jira/tracker-ops" "$out" "Atlassian MCP Jira tools (site example.atlassian.net)"
assert_contains "jira/start-state" "$out" "In Progress"
assert_contains "jira/done-state" "$out" "set the issue Validate"
assert_contains "jira/base-from-origin-head" "$out" "PR against trunk"
assert_contains "jira/queue-in-refill" "$out" "project = ABC AND labels = agent-ready"
assert_contains "jira/file-to" "$out" "File follow-ups to Jira project ABC"
assert_not_contains "jira/no-linear-verbs" "$out" "orca linear"
assert_contains "jira/load-timeouts-not-gate-loop" "$out" "not a failure on the same command: do not gate-loop"
assert_contains "jira/no-vendor-feedback" "$out" "never to the host's or any vendor's feedback or bug-report channel"

echo "--- 4. worker script paths are absolute and exist ---"
review_path="$(grep -o 'bash "[^"]*/review.sh"' <<<"$out" | head -1 | sed 's/^bash "//; s/"$//')"
assert_eq "paths/review-absolute" "/" "${review_path:0:1}"
if [[ -f "$review_path" ]]; then pass "paths/review-exists"; else fail "paths/review-exists" "not a file: [$review_path]"; fi

echo "--- 5. notes.md is appended as project rules ---"
printf 'Never touch the shared Supabase.\n' >"$BOX/.claude/wave/notes.md"
spawn_dry >/dev/null
assert_contains "notes/appended" "$(cat "$BOX/out.txt")" "Never touch the shared Supabase."

echo "--- 6. linear config uses orca linear, no successor by default ---"
new_sandbox "WAVE_TRACKER=linear
WAVE_QUEUE='team SPO, label agent-ready'
WAVE_STATE_START='In Progress'
WAVE_STATE_DONE=Done
WAVE_FILE_TO='team SPO'
WAVE_BASE=origin/development"
spawn_dry >/dev/null
out="$(cat "$BOX/out.txt")"
assert_contains "linear/tracker-ops" "$out" "orca linear"
assert_contains "linear/base-override" "$out" "PR against development"
assert_contains "linear/no-successor" "$out" "Do NOT spawn a successor"

echo "--- 7. triage reads a saved Jira search result ---"
new_sandbox "$JIRA_CONFIG"
cat >"$BOX/issues.json" <<'EOF'
{"issues":{"nodes":[{"key":"ABC-1","fields":{"summary":"First thing","description":"no refs here","labels":["agent-ready"]}},
{"key":"ABC-2","fields":{"summary":"Second thing","description":"still none"}}]}}
EOF
out="$(cd "$BOX" && bash "$WAVE/triage.sh" --json issues.json 2>&1)"
assert_contains "triage/row-1" "$out" "| ABC-1 | - | no file:line cited | First thing |"
assert_contains "triage/row-2" "$out" "| ABC-2 | - | no file:line cited | Second thing |"

echo "--- 8. triage refuses to shell-fetch jira ids ---"
out="$(cd "$BOX" && bash "$WAVE/triage.sh" ABC-1 2>&1)"; st=$?
assert_eq "triage-jira-ids/exit-2" "2" "$st"
assert_contains "triage-jira-ids/says-json" "$out" "--json"

echo "--- 9. TIER sizes the review: normal is the default and keeps the loop ---"
new_sandbox "$JIRA_CONFIG"
st="$(spawn_dry)"
out="$(cat "$BOX/out.txt")"
assert_eq "tier-normal/exit-0" "0" "$st"
assert_contains "tier-normal/header" "$out" "tier normal"
assert_contains "tier-normal/loop" "$out" "Stop after 3 review rounds"
assert_not_contains "tier-normal/no-plan" "$out" "plan-review.sh"
assert_contains "tier-normal/tier-line" "$out" "Its first line is TIER: normal"

echo "--- 10. TIER=quick runs one round and escalates on a risk trigger ---"
st="$(spawn_dry TIER=quick)"
out="$(cat "$BOX/out.txt")"
assert_eq "tier-quick/exit-0" "0" "$st"
assert_contains "tier-quick/one-round" "$out" "one Codex Terra correctness round, no loop"
assert_contains "tier-quick/escalates" "$out" "TIER: quick -> normal"
assert_not_contains "tier-quick/no-plan" "$out" "plan-review.sh"

echo "--- 11. TIER=risk reviews the plan before code, then always adds Grok ---"
st="$(spawn_dry TIER=risk)"
out="$(cat "$BOX/out.txt")"
assert_eq "tier-risk/exit-0" "0" "$st"
plan_path="$(grep -o 'bash "[^"]*/plan-review.sh"' <<<"$out" | head -1 | sed 's/^bash "//; s/"$//')"
if [[ -f "$plan_path" ]]; then pass "tier-risk/plan-review-exists"; else fail "tier-risk/plan-review-exists" "not a file: [$plan_path]"; fi
assert_contains "tier-risk/plan-tiebreak" "$out" "tiebreak.sh\" --plan ABC-7"
assert_contains "tier-risk/always-grok" "$out" "Tier risk: Codex Terra correctness plus Grok"
plan_line="$(grep -n '^1.5 Tier risk' <<<"$out" | cut -d: -f1)"
code_line="$(grep -n '^2. Work it' <<<"$out" | cut -d: -f1)"
if [[ -n "$plan_line" && -n "$code_line" && "$plan_line" -lt "$code_line" ]]; then
  pass "tier-risk/plan-before-code"
else
  fail "tier-risk/plan-before-code" "plan line [$plan_line], code line [$code_line]"
fi

echo "--- 12. an unknown TIER fails loudly ---"
st="$(spawn_dry TIER=huge)"
assert_eq "tier-bad/exit-1" "1" "$st"
assert_contains "tier-bad/names-tiers" "$(cat "$BOX/out.txt")" "quick, normal, or risk"

echo "--- 13. plan-review and tiebreak --plan refuse without their inputs ---"
out="$(cd "$BOX" && bash "$WAVE/plan-review.sh" ABC-7 2>&1)"; st=$?
assert_eq "plan-review-no-plan/exit-1" "1" "$st"
assert_contains "plan-review-no-plan/says" "$out" "NO PLAN REVIEW"
out="$(cd "$BOX" && bash "$WAVE/tiebreak.sh" --plan ABC-7 2>&1)"; st=$?
assert_eq "tiebreak-plan-no-logs/exit-1" "1" "$st"
assert_contains "tiebreak-plan-no-logs/says" "$out" "NO ASTRA TIE-BREAK: requires completed Codex, Grok, and plan logs"

echo "--- 14. guard_readonly fails a reviewer that edits the worktree ---"
printf 'tracked\n' >"$BOX/kept.txt"
git -C "$BOX" add kept.txt && git -C "$BOX" commit -q -m kept
guard() { (cd "$BOX" && . "$WAVE/lib.sh" && wave_exclude '.wave-review.*' && guard_readonly "$@"); echo $?; }
assert_eq "guard/read-only-passes" "0" "$(guard grep -q tracked kept.txt)"
assert_eq "guard/reviewer-status-kept" "7" "$(guard sh -c 'exit 7')"
assert_eq "guard/edit-tracked" "3" "$(guard sh -c 'echo changed >> kept.txt')"
git -C "$BOX" checkout -q -- kept.txt
assert_eq "guard/new-untracked" "3" "$(guard sh -c 'echo x > stray.txt')"
rm -f "$BOX/stray.txt"
assert_eq "guard/own-log-is-not-an-edit" "0" "$(guard sh -c 'echo log > .wave-review.grok.log')"
# negative control: an untracked file that already existed, edited in place
printf 'a\n' >"$BOX/pre.txt"
assert_eq "guard/edit-untracked" "3" "$(guard sh -c 'echo b >> pre.txt')"
rm -f "$BOX/pre.txt"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
