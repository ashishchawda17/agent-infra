#!/usr/bin/env bash
# test-mirror-provenance.sh — sync-graph.sh refuses a mirror built off the
# reference branch (INNOV-353).
#
# WHY THIS EXISTS. A shared mirror reflected whichever commit the last person to
# sync happened to have checked out. graph.json carries `built_at_commit`, and
# nothing on the publish path read it: a team vault held one mirror 1,429 commits
# behind its trunk and another built from a feature branch, and both passed every
# check the plugin had. The gate: `built_at_commit` must be an ancestor of
# origin/<reference branch> in the source checkout, where the reference branch is
# `branch` in repos.json, else the checkout's detected default.
#
# THE CASES THAT MATTER MOST are the ones a naive gate gets wrong:
#   - a SQUASH-MERGED branch: its content is on the reference branch, its commit
#     never will be, so it must be refused (the monorepo squash-merges everything);
#   - an UNVERIFIABLE graph: SKIPPED, published, and never called OK;
#   - a DETECTED reference branch: the message must say it was detected, because
#     the local origin/HEAD is wrong often enough (INNOV-352) that a reader has to
#     be able to see which branch was actually checked.
#
# Run:  bash tests/test-mirror-provenance.sh   (from anywhere)
# No network, no real vault. One fixture repo is built once and reused: process
# spawn is the whole cost of a suite on Windows. `node` delegates resolve-repos.mjs
# to a real interpreter and no-ops the rest, so a real `node` on PATH is required.
set -uo pipefail
unset BRAIN_ROOT CLAUDE_PROJECT_DIR  # never the real vault; see test-suite-isolation.sh

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SYNC="$REPO_ROOT/brain/bin/sync-graph.sh"
RESOLVE="$REPO_ROOT/brain/bin/resolve-repos.mjs"

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
  if [[ "$2" == *"$3"* ]]; then fail "$1" "expected NOT to contain: [$3]" "actual: [$2]"; else pass "$1"; fi
}

REAL_NODE="$(command -v node || true)"
if [[ -z "$REAL_NODE" ]]; then
  echo "SKIP: no node on PATH — this suite exercises real node modules." >&2
  exit 0
fi

# --- stubs ------------------------------------------------------------------
# Same shape as test-repo-aliases.sh: a no-op scope audit reports UNKNOWN, which
# warns and publishes — deliberate, this suite is about provenance, not scope.
STUBS="$TMPROOT/stubs"
mkdir -p "$STUBS"
for prog in python python3; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$prog"
  chmod +x "$STUBS/$prog"
done
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do\n'
  printf '  case "$a" in\n'
  printf '    *resolve-repos.mjs) exec %q "$@" ;;\n' "$REAL_NODE"
  # the gate reads built_at_commit with an inline script
  printf '    -e)                 exec %q "$@" ;;\n' "$REAL_NODE"
  printf '  esac\n'
  printf 'done\n'
  printf 'exit 0\n'
} >"$STUBS/node"
chmod +x "$STUBS/node"

native_path() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
to_crlf() { local f="$1"; sed 's/$/\r/' "$f" >"$f.crlf" && mv "$f.crlf" "$f"; }
g() { git -c user.name=t -c user.email=t@t.t -c core.autocrlf=false "$@"; }

# --- the fixture: one origin, one checkout, every history shape --------------
#
#   main         M1 ── M2 (squash of `squashed`) ......... pushed
#   development  M1 ── D1 ................................ pushed
#   squashed     M1 ── S1   content landed on main as M2, S1 itself never will
#   feature      M2 ── F1   local only, AHEAD of main
#
# `app/frontend/` exists from M1 on, for the monorepo sub-path case.
BOX="$TMPROOT/box"
V="$BOX/vault"
APP="$BOX/repos/app"
mkdir -p "$BOX/seed/frontend" "$BOX/repos/plain/graphify-out" "$V/wiki"

commit_file() { # dir file message -> echoes the new sha
  printf '%s\n' "$3" >"$1/$2"
  g -C "$1" add -A >/dev/null 2>&1
  g -C "$1" commit -q -m "$3" >/dev/null 2>&1
  git -C "$1" rev-parse HEAD
}

g -C "$BOX/seed" init -q >/dev/null 2>&1
g -C "$BOX/seed" checkout -q -b main >/dev/null 2>&1
printf 'fe\n' >"$BOX/seed/frontend/index.txt"
M1="$(commit_file "$BOX/seed" a.txt "m1")"
g clone -q --bare "$BOX/seed" "$BOX/origin.git" >/dev/null 2>&1
g clone -q "$BOX/origin.git" "$APP" >/dev/null 2>&1
git -C "$APP" remote set-head origin main >/dev/null 2>&1

g -C "$APP" checkout -q -b development >/dev/null 2>&1
D1="$(commit_file "$APP" dev.txt "d1")"
g -C "$APP" push -q origin development >/dev/null 2>&1

g -C "$APP" checkout -q -b squashed main >/dev/null 2>&1
S1="$(commit_file "$APP" sq.txt "s1")"
g -C "$APP" checkout -q main >/dev/null 2>&1
g -C "$APP" merge -q --squash squashed >/dev/null 2>&1
g -C "$APP" commit -q -m "m2 (squash of s1)" >/dev/null 2>&1
M2="$(git -C "$APP" rev-parse HEAD)"
g -C "$APP" push -q origin main >/dev/null 2>&1

g -C "$APP" checkout -q -b feature >/dev/null 2>&1
F1="$(commit_file "$APP" feat.txt "f1")"

if [[ -z "$M1" || -z "$D1" || -z "$S1" || -z "$M2" || -z "$F1" || "$M2" == "$S1" ]] ||
  ! git -C "$APP" rev-parse --verify --quiet refs/remotes/origin/development >/dev/null; then
  fail "harness/fixture-built" "the fixture repo did not build" "M1=$M1 D1=$D1 S1=$S1 M2=$M2 F1=$F1"
  echo
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi
pass "harness/fixture-built"

# Put the vault and the checkout back to "one stale mirror, no identity file".
# $1 is the commit the rebuilt graph claims (empty = the key is absent, as in a
# graph from an older graphify); $2 the mirror name; $3 the checkout dir.
reset_case() { # built_at_commit [mirror] [checkout]
  local sha="${1:-}" name="${2:-app}" dir="${3:-$APP}" key=""
  rm -rf "$V/graphify" "$V/repos.json" "$V/repos.local.json"
  mkdir -p "$V/graphify/$name" "$dir/graphify-out"
  : >"$V/wiki/log.md"
  printf '{"nodes":["old"],"links":[]}\n' >"$V/graphify/$name/graph.json"
  [[ -n "$sha" ]] && key="$(printf ',"built_at_commit":"%s"' "$sha")"
  printf '{"nodes":["old","REBUILT"],"links":[]%s}\n' "$key" >"$dir/graphify-out/graph.json"
}

# repos.json with no `remote`: resolveRepos then trusts the cached path as-is,
# which keeps identity out of the way of what is under test.
write_identity() { # repos_json_body  (repos.local.json always maps app -> $APP)
  printf '{\n  "repos": %s\n}\n' "$1" >"$V/repos.json"
  printf '{"app":"%s","app-fe":"%s"}\n' "$(native_path "$APP")" "$(native_path "$APP/frontend")" >"$V/repos.local.json"
}

run_sync() { # [args...] -> echoes exit status; output in $BOX/out.txt, $BOX/err.txt
  (
    PATH="$STUBS:$PATH"
    BRAIN_ROOT="$V" REPOS_DIR="$BOX/repos" bash "$SYNC" --no-commit "$@"
  ) >"$BOX/out.txt" 2>"$BOX/err.txt"
  echo $?
}
err() { cat "$BOX/err.txt"; }
mirror() { cat "$V/graphify/${1:-app}/graph.json" 2>/dev/null; }

echo "--- A. --print-branches: the configured reference branch ---"

reset_case "$M2"
write_identity '{"app":{"branch":"development"},"plain":{},"bad":{"branch":"-x y"},"num":{"branch":7}}'
out="$(node "$RESOLVE" --vault "$V" --print-branches 2>/dev/null)"
assert_eq "print-branches/only-configured-entries" "app	development" "$out"

to_crlf "$V/repos.json"
out="$(node "$RESOLVE" --vault "$V" --print-branches 2>/dev/null | tr -d '\r')"
assert_eq "print-branches/crlf-repos-json" "app	development" "$out"

rm -f "$V/repos.json"
out="$(node "$RESOLVE" --vault "$V" --print-branches 2>/dev/null)"
assert_eq "print-branches/no-repos-json/exit-0-and-empty" "0:" "$?:$out"

echo "--- B. built on the reference branch: publishes as before ---"

reset_case "$M2"
st="$(run_sync)"
assert_eq "on-branch/exit-0" "0" "$st"
assert_contains "on-branch/published" "$(mirror)" "REBUILT"
assert_contains "on-branch/says-ok" "$(err)" "PROVENANCE: OK app"
assert_contains "on-branch/names-the-branch" "$(err)" "origin/main"
# No repos.json => the branch was DETECTED, and the line has to say so.
assert_contains "on-branch/says-detected-not-configured" "$(err)" "detected"

# An OLDER commit on the branch is still on the branch. How far behind is
# INNOV-354's question, not this gate's.
reset_case "$M1"
st="$(run_sync)"
assert_contains "on-branch/older-ancestor-published" "$(mirror)" "REBUILT"

echo "--- C. built off the reference branch: refused ---"

# A feature branch AHEAD of main: unmerged code does not belong in the shared graph.
reset_case "$F1"
st="$(run_sync)"
assert_eq "ahead/exit-1" "1" "$st"
assert_not_contains "ahead/NOT-published" "$(mirror)" "REBUILT"
assert_contains "ahead/says-refused" "$(err)" "REFUSED app"
assert_contains "ahead/names-the-commit" "$(err)" "${F1:0:12}"
assert_contains "ahead/names-the-branch" "$(err)" "origin/main"
assert_contains "ahead/says-detected-not-configured" "$(err)" "detected default, not configured"
assert_contains "ahead/gives-the-remedy" "$(err)" "rebuild"
assert_eq "ahead/no-log-line-written" "" "$(cat "$V/wiki/log.md")"

# THE SQUASH-MERGE CASE. S1's content is on main (as M2); S1 is not, and never
# will be. Indistinguishable from an abandoned branch, so it is refused.
reset_case "$S1"
st="$(run_sync)"
assert_eq "squash-merged/exit-1" "1" "$st"
assert_not_contains "squash-merged/NOT-published" "$(mirror)" "REBUILT"
assert_contains "squash-merged/names-the-commit" "$(err)" "${S1:0:12}"

# Only the ROOT built_at_commit counts. A node that happens to carry an attribute
# of the same name, naming a commit that IS on main, must not vouch for the graph.
reset_case "$F1"
printf '{"nodes":[{"id":"REBUILT","built_at_commit":"%s"}],"links":[],"built_at_commit":"%s"}\n' "$M2" "$F1" \
  >"$APP/graphify-out/graph.json"
st="$(run_sync)"
assert_eq "nested-key/root-commit-decides/exit-1" "1" "$st"
assert_not_contains "nested-key/NOT-published" "$(mirror)" "REBUILT"
assert_contains "nested-key/names-the-root-commit" "$(err)" "${F1:0:12}"

# A refusal is THAT MIRROR ONLY: a second mirror in the same run still syncs.
reset_case "$F1"
mkdir -p "$V/graphify/plain"
printf '{"nodes":["old"],"links":[]}\n' >"$V/graphify/plain/graph.json"
printf '{"nodes":["old","PLAIN-REBUILT"],"links":[]}\n' >"$BOX/repos/plain/graphify-out/graph.json"
st="$(run_sync)"
assert_eq "mixed/exit-1" "1" "$st"
assert_not_contains "mixed/refused-mirror-untouched" "$(mirror)" "REBUILT"
assert_contains "mixed/other-mirror-synced" "$(mirror plain)" "PLAIN-REBUILT"
assert_contains "mixed/summary-names-the-refused-mirror" "$(err)" "REFUSED 1 mirror(s): app"

echo "--- D. unverifiable: SKIPPED with the reason, published, never OK ---"

assert_skipped() { # label reason_fragment
  assert_eq "$1/exit-0" "0" "$st"
  assert_contains "$1/published" "$(mirror)" "REBUILT"
  assert_contains "$1/says-skipped" "$(err)" "PROVENANCE: SKIPPED app"
  assert_contains "$1/gives-the-reason" "$(err)" "$2"
  assert_not_contains "$1/never-says-ok" "$(err)" "PROVENANCE: OK"
}

reset_case ""
st="$(run_sync)"
assert_skipped "no-built-at-commit" "no built_at_commit"

# ...and a nested one is not a root one: this graph states no build commit.
reset_case ""
printf '{"nodes":[{"id":"REBUILT","built_at_commit":"%s"}],"links":[]}\n' "$F1" >"$APP/graphify-out/graph.json"
st="$(run_sync)"
assert_skipped "nested-key-only" "no built_at_commit"

reset_case "$M2"
printf '{"nodes":["REBUILT"' >"$APP/graphify-out/graph.json"   # truncated write
st="$(run_sync)"
assert_skipped "unparsable-graph" "could not be read"

reset_case "0123456789abcdef0123456789abcdef01234567"
st="$(run_sync)"
assert_skipped "unknown-commit" "not in this checkout"

reset_case "$M2"
write_identity '{"app":{"branch":"no-such-branch"}}'
st="$(run_sync)"
assert_skipped "branch-not-on-origin" "origin/no-such-branch"
assert_contains "branch-not-on-origin/says-configured" "$(err)" "configured"

# Not a git checkout at all (the `plain` dir), reached as the only mirror.
reset_case "$M2" plain "$BOX/repos/plain"
st="$(run_sync)"
assert_eq "not-a-git-checkout/exit-0" "0" "$st"
assert_contains "not-a-git-checkout/published" "$(mirror plain)" "REBUILT"
assert_contains "not-a-git-checkout/says-skipped" "$(err)" "PROVENANCE: SKIPPED plain"
assert_contains "not-a-git-checkout/gives-the-reason" "$(err)" "not a git checkout"
rm -f "$BOX/repos/plain/graphify-out/graph.json"

# No origin/HEAD and nothing configured: there is no branch to check against.
# (`gh` cannot answer for a local-path remote, so detection comes up empty.)
reset_case "$M2"
git -C "$APP" remote set-head origin -d >/dev/null 2>&1
st="$(run_sync)"
assert_skipped "no-reference-branch" "no reference branch"
git -C "$APP" remote set-head origin main >/dev/null 2>&1

echo "--- E. the reference branch is not always main ---"

# DETECTED default is `development` (the tray-pos-flutter shape).
git -C "$APP" remote set-head origin development >/dev/null 2>&1
reset_case "$D1"
st="$(run_sync)"
assert_eq "detected-development/exit-0" "0" "$st"
assert_contains "detected-development/published" "$(mirror)" "REBUILT"
assert_contains "detected-development/names-the-branch" "$(err)" "origin/development"
reset_case "$M2"
st="$(run_sync)"
assert_eq "detected-development/main-only-commit-refused" "1" "$st"
git -C "$APP" remote set-head origin main >/dev/null 2>&1

# CONFIGURED `development` while the default is `main` (the hub shape).
# Negative control first: with nothing configured, D1 is checked against the
# detected `main`, where it is not — so it is the config that lets it through.
reset_case "$D1"
st="$(run_sync)"
assert_eq "configured/control-without-branch-refused" "1" "$st"
assert_not_contains "configured/control-NOT-published" "$(mirror)" "REBUILT"

reset_case "$D1"
write_identity '{"app":{"branch":"development"}}'
st="$(run_sync)"
assert_eq "configured/exit-0" "0" "$st"
assert_contains "configured/published" "$(mirror)" "REBUILT"
assert_contains "configured/names-the-branch" "$(err)" "origin/development"
assert_contains "configured/says-configured" "$(err)" "configured in repos.json"
assert_not_contains "configured/does-not-say-detected" "$(err)" "detected"

# ...and a commit that is only on `main` is refused against it.
reset_case "$M2"
write_identity '{"app":{"branch":"development"}}'
st="$(run_sync)"
assert_eq "configured/main-only-commit-refused" "1" "$st"
assert_contains "configured/refusal-names-configured-branch" "$(err)" "origin/development"

# CRLF: the vault is autocrlf, so repos.json arrives with \r\n on Windows.
reset_case "$D1"
write_identity '{"app":{"branch":"development"}}'
to_crlf "$V/repos.json"
st="$(run_sync)"
assert_eq "configured-crlf/exit-0" "0" "$st"
assert_contains "configured-crlf/published" "$(mirror)" "REBUILT"
assert_contains "configured-crlf/names-the-branch" "$(err)" "origin/development (configured"

echo "--- F. a mirror at a sub-path of a monorepo checkout ---"

reset_case "$F1" app-fe "$APP/frontend"
write_identity '{"app-fe":{"subPath":"frontend","branch":"main"}}'
st="$(run_sync)"
assert_eq "subpath/off-branch-exit-1" "1" "$st"
assert_not_contains "subpath/off-branch-NOT-published" "$(mirror app-fe)" "REBUILT"
assert_contains "subpath/refusal-names-the-mirror" "$(err)" "REFUSED app-fe"

reset_case "$M2" app-fe "$APP/frontend"
write_identity '{"app-fe":{"subPath":"frontend","branch":"main"}}'
st="$(run_sync)"
assert_eq "subpath/on-branch-exit-0" "0" "$st"
assert_contains "subpath/on-branch-published" "$(mirror app-fe)" "REBUILT"
rm -rf "$APP/frontend/graphify-out"

echo "--- G. the refusal follows the history, not the fixture ---"

# NEGATIVE CONTROL for part C: the same F1 that was refused publishes once it IS
# on origin/main. If the gate refused for any reason other than ancestry, this
# still fails.
g -C "$APP" push -q origin feature:main >/dev/null 2>&1
reset_case "$F1"
st="$(run_sync)"
assert_eq "merged/exit-0" "0" "$st"
assert_contains "merged/published" "$(mirror)" "REBUILT"

# A SHALLOW clone cuts history, so "not an ancestor" there proves nothing: the
# commit is present, its link to the branch tip is what was truncated.
SH="$BOX/repos/shallow"
ORIGIN_URL="$(native_path "$BOX/origin.git")"   # --depth needs a URL, not a path
ORIGIN_URL="file:///${ORIGIN_URL#/}"
g clone -q --depth 1 "$ORIGIN_URL" "$SH" >/dev/null 2>&1
OLD_TIP="$(git -C "$SH" rev-parse HEAD 2>/dev/null)"
g -C "$APP" checkout -q main >/dev/null 2>&1
g -C "$APP" merge -q --ff-only origin/main >/dev/null 2>&1
commit_file "$APP" later.txt "m3" >/dev/null
g -C "$APP" push -q origin main >/dev/null 2>&1
g -C "$SH" fetch -q --depth 1 origin main >/dev/null 2>&1
if [[ "$(git -C "$SH" rev-parse --is-shallow-repository 2>/dev/null)" == "true" &&
  "$(git -C "$SH" rev-parse refs/remotes/origin/main 2>/dev/null)" != "$OLD_TIP" ]]; then
  reset_case "$OLD_TIP" shallow "$SH"
  st="$(run_sync)"
  assert_eq "shallow/exit-0" "0" "$st"
  assert_contains "shallow/published" "$(mirror shallow)" "REBUILT"
  assert_contains "shallow/says-skipped" "$(err)" "PROVENANCE: SKIPPED shallow"
  assert_contains "shallow/gives-the-reason" "$(err)" "shallow clone"
else
  fail "harness/shallow-fixture" "could not build a shallow clone whose origin/main moved"
fi

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
