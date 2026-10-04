#!/usr/bin/env bash
# test-revise.sh — gate for brain/bin/revise.mjs (INNOV-373).
#
# Contract under test:
#   - queue keeps only cannot-tell line-drift / side-claim records, flags a note
#     changed since its verdict as stale, lists superseded/falsified as skipped,
#     and honours --note
#   - apply (drift) rewrites exactly the cited path:line refs, everything else
#     byte-identical, CRLF kept: :620 is not :62, a range is refused, a ref
#     cited with its repo prefix dropped still matches, a moved source: says so
#   - apply (claim) replaces a `from` that occurs exactly once, nothing else
#   - apply refuses a stale blob, a status-marked note, a draft; --dry-run
#     writes nothing
#   - bump sets last_verified to today, keeps CRLF and a trailing comment,
#     leaves confidence alone, refuses drafts and status-marked notes
#
# Run:  bash tests/test-revise.sh   (from anywhere; needs node)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
VF="$REPO_ROOT/brain/bin/verify-findings.mjs"
RV="$REPO_ROOT/brain/bin/revise.mjs"

PASSED=0
FAILED=0
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT" 2>/dev/null || true; }
trap cleanup EXIT
pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() {
  FAILED=$((FAILED + 1)); echo "FAIL $1"; shift
  local line; for line in "$@"; do echo "     $line"; done
}
check() { # check <name> <cond-exit> <detail>
  if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "$3"; fi
}

VAULT="$TMPROOT/vault"
mkdir -p "$VAULT/wiki/_drafts" "$VAULT/logs"
TODAY="$(date +%F)"
# mk <path> <crlf:0|1>  — stdin (LF) → file, CRLF when asked
mk() { node -e 'const [f,c]=process.argv.slice(1);let t=require("fs").readFileSync(0,"utf8");
  if(c==="1")t=t.replace(/\n/g,"\r\n");require("fs").writeFileSync(f,t)' "$1" "$2"; }

mk "$VAULT/wiki/drift.md" 1 <<'EOF'
---
id: drift
source: sm/lib/utils.ts
last_verified: 2020-01-01  # checked by hand
confidence: medium
---
# drift
Sanitized at `lib/utils.ts:62`, again at lib/utils.ts:62.
Unrelated: lib/utils.ts:620 and xlib/utils.ts:62 stay.
Prefixed in the record: lib/a.ts:10.
EOF
mk "$TMPROOT/drift.expected" 1 <<'EOF'
---
id: drift
source: sm/lib/utils.ts
last_verified: 2020-01-01  # checked by hand
confidence: medium
---
# drift
Sanitized at `lib/utils.ts:65`, again at lib/utils.ts:65.
Unrelated: lib/utils.ts:620 and xlib/utils.ts:62 stay.
Prefixed in the record: lib/a.ts:12.
EOF
mk "$VAULT/wiki/moved.md" 0 <<'EOF'
---
id: moved
source: .github/workflows/test.yml:108
last_verified: 2020-01-01
confidence: low
---
The pin lives at .github/workflows/test.yml:108.
EOF
mk "$VAULT/wiki/range.md" 0 <<'EOF'
---
last_verified: 2020-01-01
---
See lib/b.ts:62-70 for the loop.
EOF
mk "$VAULT/wiki/side.md" 1 <<'EOF'
---
id: side
last_verified: 2020-01-01
confidence: medium
---
RLS is server-only. Nothing imports lib/supabase.ts.
Second paragraph stays.
EOF
mk "$TMPROOT/side.expected" 1 <<'EOF'
---
id: side
last_verified: 2020-01-01
confidence: medium
---
RLS is server-only. Only lib/upload-service.ts imports lib/supabase.ts.
Second paragraph stays.
EOF
mk "$VAULT/wiki/twice.md" 0 <<'EOF'
---
last_verified: 2020-01-01
---
Nothing imports it. Nothing imports it.
EOF
mk "$VAULT/wiki/gone.md" 0 <<'EOF'
---
status: superseded
last_verified: 2020-01-01
---
Retry limit is lib/c.ts:3.
EOF
mk "$VAULT/wiki/ext.md" 0 <<'EOF'
---
last_verified: 2020-01-01
---
Dashboard says so.
EOF
mk "$VAULT/wiki/_drafts/dr.md" 0 <<'EOF'
---
last_verified: 2020-01-01
---
Draft at lib/d.ts:1.
EOF

# Verdicts go in through verify's own store, so the blobs are the real ones.
cat >"$TMPROOT/v.jsonl" <<'EOF'
{"note":"wiki/drift.md","kind":"claim","verdict":"cannot-tell","subtype":"line-drift","drift":[{"old":"lib/utils.ts:62","new":"lib/utils.ts:65"},{"old":"sm/lib/a.ts:10","new":"sm/lib/a.ts:12"}],"reason":"moved","evidence":{"refs":["sm/lib/utils.ts:65"],"branch":"main","sha":"abc1234"}}
{"note":"wiki/moved.md","kind":"claim","verdict":"cannot-tell","subtype":"line-drift","drift":[{"old":".github/workflows/test.yml:108","new":".github/workflows/rls-tests.yml:59"}],"reason":"job moved"}
{"note":"wiki/range.md","kind":"claim","verdict":"cannot-tell","subtype":"line-drift","drift":[{"old":"lib/b.ts:62","new":"lib/b.ts:64"}],"reason":"moved"}
{"note":"wiki/side.md","kind":"claim","verdict":"cannot-tell","subtype":"side-claim","reason":"lib/upload-service.ts:2 imports it"}
{"note":"wiki/twice.md","kind":"claim","verdict":"cannot-tell","subtype":"side-claim","reason":"x"}
{"note":"wiki/gone.md","kind":"claim","verdict":"cannot-tell","subtype":"line-drift","drift":[{"old":"lib/c.ts:3","new":"lib/c.ts:4"}],"reason":"moved"}
{"note":"wiki/ext.md","kind":"claim","verdict":"cannot-tell","subtype":"external-claim","reason":"dashboard"}
EOF
echo '[]' >"$TMPROOT/scan.json"
BRAIN_ROOT="$VAULT" node "$VF" record "$TMPROOT/scan.json" "$TMPROOT/v.jsonl" >"$TMPROOT/r.txt" 2>&1 \
  || { echo "setup: verify-findings record failed: $(cat "$TMPROOT/r.txt")"; exit 1; }

rv() { BRAIN_ROOT="$VAULT" node "$RV" "$@" >"$TMPROOT/out.txt" 2>&1; }
qline() { grep "\"note\":\"$1\"" "$TMPROOT/q.txt"; }

# --- 1. queue ----------------------------------------------------------------
BRAIN_ROOT="$VAULT" node "$RV" queue >"$TMPROOT/q.txt" 2>&1; rc=$?
check "queue/runs" "$rc" "$(cat "$TMPROOT/q.txt")"
check "queue/drops-external-claim" "$([[ -z "$(qline wiki/ext.md)" ]]; echo $?)" "q: [$(cat "$TMPROOT/q.txt")]"
check "queue/drift-shape" "$([[ "$(qline wiki/drift.md)" == *'"kind":"drift"'*'"stale":false'* ]]; echo $?)" "line: [$(qline wiki/drift.md)]"
check "queue/side-claim-shape" "$([[ "$(qline wiki/side.md)" == *'"kind":"claim"'*'"subtype":"side-claim"'* ]]; echo $?)" "line: [$(qline wiki/side.md)]"
check "queue/skips-superseded" "$([[ "$(qline wiki/gone.md)" == *'"skip":"status: superseded"'* ]]; echo $?)" "line: [$(qline wiki/gone.md)]"
BRAIN_ROOT="$VAULT" node "$RV" queue --note wiki/side.md >"$TMPROOT/q1.txt" 2>&1
check "queue/--note" "$([[ "$(wc -l <"$TMPROOT/q1.txt" | tr -d ' ')" == 1 ]] && grep -q 'wiki/side.md' "$TMPROOT/q1.txt"; echo $?)" "q: [$(cat "$TMPROOT/q1.txt")]"
BRAIN_ROOT="$VAULT" node "$RV" queue --note wiki/nope.md >"$TMPROOT/q1.txt" 2>&1
check "queue/--note-without-record" "$(grep -q '"norecord":true' "$TMPROOT/q1.txt"; echo $?)" "q: [$(cat "$TMPROOT/q1.txt")]"

edits() { # edits <note> → that note's queue line, as an edit
  qline "$1" >"$TMPROOT/e.jsonl"
}

# --- 2. drift: dry run writes nothing, apply rewrites exactly the refs --------
cp "$VAULT/wiki/drift.md" "$TMPROOT/drift.before"
edits wiki/drift.md
rv apply "$TMPROOT/e.jsonl" --dry-run; rc=$?
check "drift/dry-run-proposes" "$([[ $rc -eq 0 ]] && grep -q '^PROPOSED wiki/drift.md' "$TMPROOT/out.txt" && grep -q '^+ .*lib/utils.ts:65' "$TMPROOT/out.txt"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"
check "drift/dry-run-writes-nothing" "$(cmp -s "$VAULT/wiki/drift.md" "$TMPROOT/drift.before"; echo $?)" "file changed on --dry-run"
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "drift/applied" "$([[ $rc -eq 0 ]] && grep -q '^APPLIED wiki/drift.md' "$TMPROOT/out.txt"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"
check "drift/exact-bytes-crlf" "$(cmp -s "$VAULT/wiki/drift.md" "$TMPROOT/drift.expected"; echo $?)" "got: [$(od -c "$VAULT/wiki/drift.md" | head -20)]"
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "drift/stale-blob-refused" "$([[ $rc -ne 0 ]] && grep -q '^REFUSED wiki/drift.md: .*changed since' "$TMPROOT/out.txt" && cmp -s "$VAULT/wiki/drift.md" "$TMPROOT/drift.expected"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"
BRAIN_ROOT="$VAULT" node "$RV" queue --note wiki/drift.md >"$TMPROOT/q1.txt" 2>&1
check "queue/stale-after-edit" "$(grep -q '"stale":true' "$TMPROOT/q1.txt"; echo $?)" "q: [$(cat "$TMPROOT/q1.txt")]"

edits wiki/moved.md
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "drift/moved-file" "$([[ $rc -eq 0 ]] && [[ "$(grep -c 'rls-tests.yml:59' "$VAULT/wiki/moved.md")" == 2 ]] && ! grep -q 'test.yml' "$VAULT/wiki/moved.md"; echo $?)" "file: [$(cat "$VAULT/wiki/moved.md")]"
check "drift/source-changed-flag" "$(grep -q '^SOURCE-CHANGED wiki/moved.md' "$TMPROOT/out.txt"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"

cp "$VAULT/wiki/range.md" "$TMPROOT/range.before"
edits wiki/range.md
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "drift/range-refused" "$([[ $rc -ne 0 ]] && grep -q '^REFUSED wiki/range.md: .*range' "$TMPROOT/out.txt" && cmp -s "$VAULT/wiki/range.md" "$TMPROOT/range.before"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"

printf '%s\n' "$(qline wiki/side.md | node -e 'const l=JSON.parse(require("fs").readFileSync(0,"utf8"));
  console.log(JSON.stringify({note:l.note,kind:"drift",blob:l.blob,drift:[{old:"lib/z.ts:1",new:"lib/z.ts:2"}]}))')" >"$TMPROOT/e.jsonl"
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "drift/uncited-refused" "$([[ $rc -ne 0 ]] && grep -q '^REFUSED wiki/side.md: .*not cited' "$TMPROOT/out.txt"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"

edits wiki/gone.md
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "apply/status-marked-refused" "$([[ $rc -ne 0 ]] && grep -q '^REFUSED wiki/gone.md: .*superseded' "$TMPROOT/out.txt" && grep -q 'lib/c.ts:3' "$VAULT/wiki/gone.md"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"

# --- 3. claim: from must occur exactly once ------------------------------------
claim() { # claim <note> <from> <to>
  qline "$1" | node -e 'const [f,t]=process.argv.slice(1);const l=JSON.parse(require("fs").readFileSync(0,"utf8"));
    console.log(JSON.stringify({note:l.note,kind:"claim",blob:l.blob,from:f,to:t}))' "$2" "$3" >"$TMPROOT/e.jsonl"
}
claim wiki/side.md 'Nothing imports lib/supabase.ts.' 'Only lib/upload-service.ts imports lib/supabase.ts.'
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "claim/applied-exact-bytes" "$([[ $rc -eq 0 ]] && cmp -s "$VAULT/wiki/side.md" "$TMPROOT/side.expected"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")] file: [$(od -c "$VAULT/wiki/side.md" | head)]"
cp "$VAULT/wiki/twice.md" "$TMPROOT/twice.before"
claim wiki/twice.md 'Nothing imports it.' 'X.'
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "claim/ambiguous-refused" "$([[ $rc -ne 0 ]] && grep -q '^REFUSED wiki/twice.md: .*2 times' "$TMPROOT/out.txt" && cmp -s "$VAULT/wiki/twice.md" "$TMPROOT/twice.before"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"
claim wiki/twice.md 'not there' 'X.'
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "claim/absent-refused" "$([[ $rc -ne 0 ]] && grep -q '^REFUSED wiki/twice.md: .*0 times' "$TMPROOT/out.txt"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"

printf '%s\n' '{"note":"wiki/_drafts/dr.md","kind":"claim","blob":"x","from":"Draft","to":"D"}' '{"note":"wiki/../x.md","kind":"claim","blob":"x","from":"a","to":"b"}' >"$TMPROOT/e.jsonl"
rv apply "$TMPROOT/e.jsonl"; rc=$?
check "apply/draft-and-escape-refused" "$([[ $rc -ne 0 && "$(grep -c '^REFUSED' "$TMPROOT/out.txt")" == 2 ]] && grep -q '^Draft' "$VAULT/wiki/_drafts/dr.md"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"

# --- 4. bump -------------------------------------------------------------------
rv bump wiki/drift.md wiki/moved.md; rc=$?
check "bump/runs" "$([[ $rc -eq 0 && "$(grep -c '^BUMPED' "$TMPROOT/out.txt")" == 2 ]]; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"
node -e 'const [f,d]=process.argv.slice(1);let t=require("fs").readFileSync(f,"utf8");
  process.stdout.write(t.replace("last_verified: "+d,"last_verified: 2020-01-01"))' "$VAULT/wiki/drift.md" "$TODAY" >"$TMPROOT/drift.unbumped"
check "bump/crlf-comment-only-date" "$(cmp -s "$TMPROOT/drift.unbumped" "$TMPROOT/drift.expected" && grep -q "^last_verified: $TODAY  # checked by hand"$'\r'"\$" "$VAULT/wiki/drift.md"; echo $?)" "file: [$(od -c "$VAULT/wiki/drift.md" | head -8)]"
check "bump/confidence-untouched" "$(grep -q '^confidence: low' "$VAULT/wiki/moved.md"; echo $?)" "file: [$(cat "$VAULT/wiki/moved.md")]"
rv bump wiki/gone.md wiki/_drafts/dr.md; rc=$?
check "bump/refuses-status-and-draft" "$([[ $rc -ne 0 && "$(grep -c '^REFUSED' "$TMPROOT/out.txt")" == 2 ]] && grep -q 'last_verified: 2020-01-01' "$VAULT/wiki/gone.md" "$VAULT/wiki/_drafts/dr.md"; echo $?)" "out: [$(cat "$TMPROOT/out.txt")]"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
