#!/usr/bin/env bash
# test-suite-isolation.sh — every suite unsets the vault-resolving env (INNOV-343).
#
# Most brain scripts resolve the vault as $BRAIN_ROOT -> $CLAUDE_PROJECT_DIR ->
# cwd. CI has neither set, but a developer or worker shell often exports
# BRAIN_ROOT at the real vault, so a suite that runs a script from a fixture cwd
# without pinning it reads (or, on a write path, corrupts) the live vault. That
# happened in test-consolidate.sh (INNOV-288). The guard: each tests/test-*.sh
# has `unset BRAIN_ROOT CLAUDE_PROJECT_DIR` at top level, before its first
# `bash`/`node` call, so a local run sees the same env as CI. Per-call pins
# (`BRAIN_ROOT="$VAULT" bash ...`) still work after it. The *.test.mjs files run
# under their test-*.sh wrapper and inherit the unset.
#
# Run:  bash tests/test-suite-isolation.sh   (from anywhere)
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# Prints one line per suite in $1 that lacks the guard, or runs a script first.
unguarded() { # dir
  local f verdict
  for f in "$1"/test-*.sh; do
    [ -f "$f" ] || continue
    verdict=$(awk '
      { sub(/\r$/, "") }
      /^[[:space:]]*#/ { next }
      /^unset BRAIN_ROOT CLAUDE_PROJECT_DIR([[:space:]]|$)/ { v = "ok"; exit }
      /(^|[^[:alnum:]_])(bash|node)[[:space:]]/ { v = "runs a script at line " NR " before the unset"; exit }
      END { print (v == "" ? "no top-level unset BRAIN_ROOT CLAUDE_PROJECT_DIR" : v) }
    ' "$f")
    [ "$verdict" = ok ] || echo "$(basename "$f"): $verdict"
  done
}

# --- negative controls: the checker must catch each broken shape ----------
mk() { mkdir -p "$TMPROOT/$1"; printf '%b' "$3" >"$TMPROOT/$1/$2"; }
mk good test-a.sh '#!/usr/bin/env bash\n# runs bash later\nset -u\nunset BRAIN_ROOT CLAUDE_PROJECT_DIR\nbash x.sh\n'
mk crlf test-a.sh '#!/usr/bin/env bash\r\nset -u\r\nunset BRAIN_ROOT CLAUDE_PROJECT_DIR\r\nnode x.mjs\r\n'
mk missing test-a.sh '#!/usr/bin/env bash\nset -u\nbash x.sh\n'
mk partial test-a.sh '#!/usr/bin/env bash\nset -u\nunset CLAUDE_PROJECT_DIR\nnode x.mjs\n'
mk late test-a.sh '#!/usr/bin/env bash\nset -u\nout=$(node x.mjs)\nunset BRAIN_ROOT CLAUDE_PROJECT_DIR\n'
mk nested test-a.sh '#!/usr/bin/env bash\nset -u\nrun() { (\n  unset BRAIN_ROOT CLAUDE_PROJECT_DIR\n  bash x.sh\n); }\n'

[ -z "$(unguarded "$TMPROOT/good")" ] && pass "control/guarded-passes" || fail "control/guarded-passes" "$(unguarded "$TMPROOT/good")"
[ -z "$(unguarded "$TMPROOT/crlf")" ] && pass "control/crlf-passes" || fail "control/crlf-passes" "$(unguarded "$TMPROOT/crlf")"
for c in missing partial late nested; do
  [ -n "$(unguarded "$TMPROOT/$c")" ] && pass "control/$c-fails" || fail "control/$c-fails" "checker accepted it"
done

# --- the real suites ------------------------------------------------------
out=$(unguarded "$TEST_DIR")
[ -z "$out" ] && pass "every tests/test-*.sh unsets BRAIN_ROOT CLAUDE_PROJECT_DIR first" \
  || fail "suites read the ambient vault env" "$out"

echo
echo "passed: $PASSED  failed: $FAILED"
[ "$FAILED" -eq 0 ]
