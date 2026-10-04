#!/usr/bin/env bash
# test-tidy-decide.sh — gate for brain/bin/tidy-decide.mjs (INNOV-372).
#
# Contract under test:
#   - questions: every judgment kind tidy used to stop at gets a question whose
#     options are real candidates found on disk / in git history:
#       anchor  — rename history (git log -M), basename/suffix match in another
#                 registered repo, a path the note body names, verify's evidence
#       tag     — same-concept singleton pairs; lone singletons get existing tags
#       link    — dead [[_COMMUNITY_*]] stubs ranked by members: overlap with the
#                 old stub read back from vault git history (filename + alias case)
#   - a candidate the anchor gate rejects (wrong-repo cross-check) is never offered
#   - apply: a chosen/typed anchor that does not classify `verified` is NOT
#     written (byte-identical note — the negative control)
#   - tag fold rewrites the tag in place; link rewrite keeps |alias and #heading
#   - CRLF notes keep CRLF
#   - unanswered questions are untouched and listed
#   - freshness after apply: answered categories drop, no new findings
#
# Run:  bash tests/test-tidy-decide.sh   (from anywhere; needs node + git)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
FRESH="$REPO_ROOT/brain/bin/freshness.mjs"
TD="$REPO_ROOT/brain/bin/tidy-decide.mjs"
ANCH="$REPO_ROOT/brain/bin/check-anchors.mjs"

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

REPOS="$TMPROOT/repos"
VAULT="$TMPROOT/vault"
export REPOS_DIR="$REPOS"
gitinit() { # gitinit <dir> [remote]
  git init --quiet -b main "$1"
  git -C "$1" config user.email "tidy-test@example.invalid"
  git -C "$1" config user.name "Tidy Test"
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.autocrlf false
  git -C "$1" config core.quotepath true   # git's default, pinned against a global override
  [[ -n "${2:-}" ]] && git -C "$1" remote add origin "$2"
  return 0
}
commit() { git -C "$1" add -A && git -C "$1" commit --quiet -m "$2"; }

# --- fixture repos: alpha renames src/old.sh → lib/new.sh; beta has helper.sh --
mkdir -p "$REPOS/alpha/src" "$REPOS/alpha/docs" "$REPOS/beta/tools"
gitinit "$REPOS/alpha" "https://github.com/x/alpha.git"
echo 'echo old' >"$REPOS/alpha/src/old.sh"
echo '# guide' >"$REPOS/alpha/docs/guide.md"
commit "$REPOS/alpha" seed
mkdir -p "$REPOS/alpha/lib"
git -C "$REPOS/alpha" mv src/old.sh lib/new.sh
commit "$REPOS/alpha" rename
gitinit "$REPOS/beta" "https://github.com/x/beta.git"
echo 'echo help' >"$REPOS/beta/tools/helper.sh"
commit "$REPOS/beta" seed
# gamma is checked out under a folder name that is not its repos.json name
mkdir -p "$REPOS/gamma-folder/bin"
gitinit "$REPOS/gamma-folder" "https://github.com/x/gamma.git"
echo 'echo tool' >"$REPOS/gamma-folder/bin/tool.sh"
commit "$REPOS/gamma-folder" seed

# --- fixture vault -------------------------------------------------------------
mkdir -p "$VAULT/wiki/alpha" "$VAULT/wiki/misc" "$VAULT/wiki/_drafts" "$VAULT/graphify/alpha/communities" "$VAULT/logs"
gitinit "$VAULT"
cat >"$VAULT/repos.json" <<'EOF'
{ "repos": { "alpha": { "remote": "github.com/x/alpha" }, "beta": { "remote": "github.com/x/beta" }, "gamma": { "remote": "github.com/x/gamma" } } }
EOF
note() { # note <rel> <crlf:0|1> <frontmatter lines (newline-joined)> <body>
  local eol=$'\n' l out; [[ "$2" == 1 ]] && eol=$'\r\n'
  out="---$eol"
  while IFS= read -r l; do out="$out$l$eol"; done <<<"$3"
  printf '%s' "$out" "last_verified: 2099-01-01$eol" "confidence: medium$eol" "---$eol" "# t$eol" "$4$eol" >"$VAULT/$1"
}
note wiki/alpha/renamed.md 1 $'id: renamed\nsource: alpha/src/old.sh\ntags: [shell, constraint]' 'Old script.'
note wiki/alpha/cross.md 0 $'id: cross\nsource: alpha/scripts/helper.sh\ntags: [shell, ops]' 'Helper.'
note wiki/misc/cross2.md 0 $'id: cross2\nsource: alpha/scripts/helper.sh\ntags: [ops, constraints]' 'Helper too.'
note wiki/alpha/wrongrepo.md 0 $'id: wrongrepo\nsource: beta/docs/guide.md\ntags: [ops, shell]' 'Wrong repo.'
note wiki/misc/tool.md 0 $'id: tool\nsource: misc/tool.sh\ntags: [ops, shell]' 'Tool.'
note wiki/alpha/session.md 0 $'id: session\nsource: verified-in-session/2026-09-16\ntags: [shell, ops]' 'Seen live.'
note wiki/alpha/nosrc.md 0 $'id: nosrc\ntags: [shell, bash-tricks]' 'Read `docs/guide.md` first.'
note wiki/alpha/linker.md 0 $'id: linker\nsource: alpha/docs/guide.md\ntags: [shell, ops]' 'See [[_COMMUNITY_Old Name|the old cluster]] and [[_COMMUNITY_Old Name#Members]] and [[_COMMUNITY_Aliased Label]].'
note wiki/_drafts/d.md 0 $'id: d\nsource: alpha/src/old.sh\ntags: [draftonly]' 'Draft [[_COMMUNITY_Old Name]].'
# A stub named after an em-dash label (INNOV-323). git octal-quotes the name unless
# quotepath is off, so the deleted stub could not be read back from history.
EMDASH=$'\xe2\x80\x94'
note wiki/alpha/emlinker.md 0 $'id: emlinker\nsource: alpha/docs/guide.md\ntags: [shell, ops]' "See [[_COMMUNITY_Acc ${EMDASH} Floor]]."
printf -- '---\nid: index\n---\n[[renamed]] [[cross]] [[cross2]] [[session]] [[nosrc]] [[linker]] [[tool]] [[wrongrepo]] [[emlinker]]\n' >"$VAULT/wiki/index.md"

stub() { # stub <file-base> <alias|-> <member...>
  local f="$VAULT/graphify/alpha/communities/$1.md" a="$2"; shift 2
  { echo '---'; echo 'generated: true'; echo 'repo: alpha'
    [[ "$a" != - ]] && { echo 'aliases:'; echo "  - \"$a\""; }
    echo 'members:'; local m; for m in "$@"; do echo "  - \"$m\""; done
    echo '---'; echo '# stub'; } >"$f"
}
echo '{}' >"$VAULT/graphify/alpha/graph.json"
stub "_COMMUNITY_Old Name" - a b c
stub "_COMMUNITY_Community 5" "_COMMUNITY_Aliased Label" c y
stub "_COMMUNITY_Acc ${EMDASH} Floor" - y z
commit "$VAULT" "old stubs"
rm "$VAULT/graphify/alpha/communities/"*.md
stub "_COMMUNITY_Split One" - a b x
stub "_COMMUNITY_Split Two" - c y z
stub "_COMMUNITY_Unrelated" - q
commit "$VAULT" "relabel splits"
# verify's saved verdict for one stub link (INNOV-371 store)
cat >"$VAULT/logs/verify-findings.json" <<'EOF'
[{"note":"wiki/alpha/linker.md","kind":"dead-link","target":"_COMMUNITY_Aliased Label","verdict":"found","replacement":"_COMMUNITY_Unrelated","reason":"r","blob":"x","date":"2026-10-01","pr":null}]
EOF

scan() { BRAIN_ROOT="$VAULT" node "$FRESH" --json >"$1" 2>/dev/null; }
count() { # count <scan.json> <kind> [note] → number of findings
  node -e 'const [f,k,n]=process.argv.slice(1);
    process.stdout.write(String(JSON.parse(require("fs").readFileSync(f,"utf8")).filter(x=>x.kind===k&&(!n||x.note===n)).length))' "$@" 2>/dev/null || echo ERR
}
Q="$TMPROOT/q.jsonl"
scan "$TMPROOT/before.json"
BRAIN_ROOT="$VAULT" node "$TD" questions "$TMPROOT/before.json" >"$Q" 2>"$TMPROOT/q.err"; rc=$?
check "questions/runs" "$([[ $rc -eq 0 && -s "$Q" ]]; echo $?)" "rc=$rc err: [$(cat "$TMPROOT/q.err")]"

# labels <id> → option labels joined by |
labels() {
  node -e 'const [f,id]=process.argv.slice(1);
    const q=require("fs").readFileSync(f,"utf8").split("\n").filter(Boolean).map(JSON.parse).find(x=>x.id===id);
    process.stdout.write(q?q.options.map(o=>o.label).join("|"):"NOQUESTION")' "$Q" "$1" 2>/dev/null || echo ERR
}
# pick <id> <label> → appends the chosen option's apply lines to answers
pick() {
  node -e 'const [f,id,l]=process.argv.slice(1);
    const q=require("fs").readFileSync(f,"utf8").split("\n").filter(Boolean).map(JSON.parse).find(x=>x.id===id);
    const o=q.options.find(o=>o.label===l); for(const a of o.apply) console.log(JSON.stringify(a))' "$Q" "$1" "$2" >>"$TMPROOT/a.jsonl"
}
qdump() { cat "$Q"; }

# --- 1. candidates per kind ---------------------------------------------------
check "anchor/rename-history" "$([[ "$(labels anchor:wiki/alpha/renamed.md)" == alpha/lib/new.sh\|* ]]; echo $?)" "got: [$(labels anchor:wiki/alpha/renamed.md)]"
check "anchor/cross-repo-basename" "$([[ "$(labels anchor:wiki/misc/cross2.md)" == *beta/tools/helper.sh* ]]; echo $?)" "got: [$(labels anchor:wiki/misc/cross2.md)]"
check "anchor/wrong-repo-not-offered" "$([[ "$(labels anchor:wiki/alpha/cross.md)" != *beta/* && "$(labels anchor:wiki/alpha/cross.md)" != NOQUESTION ]]; echo $?)" "got: [$(labels anchor:wiki/alpha/cross.md)]"
check "anchor/registered-name-not-folder" "$([[ "$(labels anchor:wiki/misc/tool.md)" == gamma/bin/tool.sh\|* && "$(labels anchor:wiki/misc/tool.md)" != *gamma-folder* ]]; echo $?)" "got: [$(labels anchor:wiki/misc/tool.md)]"
check "anchor/wrong-repo-no-untracked" "$([[ "$(labels anchor:wiki/alpha/wrongrepo.md)" == 'alpha/docs/guide.md|Leave' ]]; echo $?)" "got: [$(labels anchor:wiki/alpha/wrongrepo.md)]"
check "anchor/no-source-body-path" "$([[ "$(labels anchor:wiki/alpha/nosrc.md)" == *alpha/docs/guide.md* && "$(labels anchor:wiki/alpha/nosrc.md)" != *untracked* ]]; echo $?)" "got: [$(labels anchor:wiki/alpha/nosrc.md)]"
check "anchor/unverifiable-has-untracked" "$([[ "$(labels anchor:wiki/alpha/session.md)" == *untracked* ]]; echo $?)" "got: [$(labels anchor:wiki/alpha/session.md)]"
check "tag/pair" "$([[ "$(labels tag-pair:constraint+constraints)" == constraint\|constraints\|* ]]; echo $?)" "got: [$(labels tag-pair:constraint+constraints)] q: [$(qdump | grep tag)]"
check "tag/lone-has-existing-tag" "$([[ "$(labels tag:wiki/alpha/nosrc.md:bash-tricks)" == shell\|* || "$(labels tag:wiki/alpha/nosrc.md:bash-tricks)" == *ops* ]]; echo $?)" "got: [$(labels tag:wiki/alpha/nosrc.md:bash-tricks)]"
check "link/member-overlap-filename" "$([[ "$(labels 'link:wiki/alpha/linker.md:_COMMUNITY_Old Name')" == '_COMMUNITY_Split One|_COMMUNITY_Split Two|'* ]]; echo $?)" "got: [$(labels 'link:wiki/alpha/linker.md:_COMMUNITY_Old Name')]"
check "link/member-overlap-alias" "$([[ "$(labels 'link:wiki/alpha/linker.md:_COMMUNITY_Aliased Label')" == '_COMMUNITY_Split Two|'* ]]; echo $?)" "got: [$(labels 'link:wiki/alpha/linker.md:_COMMUNITY_Aliased Label')]"
EM_ID="link:wiki/alpha/emlinker.md:_COMMUNITY_Acc ${EMDASH} Floor"
check "link/non-ascii-stub-from-history" "$([[ "$(labels "$EM_ID")" == '_COMMUNITY_Split Two|'* ]]; echo $?)" "got: [$(labels "$EM_ID")]"
check "link/verify-replacement" "$([[ "$(labels 'link:wiki/alpha/linker.md:_COMMUNITY_Aliased Label')" == *_COMMUNITY_Unrelated* ]]; echo $?)" "got: [$(labels 'link:wiki/alpha/linker.md:_COMMUNITY_Aliased Label')]"
check "questions/skip-drafts" "$(! grep -q '_drafts' "$Q"; echo $?)" "q: [$(grep _drafts "$Q")]"
check "questions/at-most-4-options" "$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(JSON.parse);process.exit(l.every(q=>q.options.length>=2&&q.options.length<=4&&q.header.length<=12)?0:1)' "$Q"; echo $?)" "q: [$(qdump)]"

# --- 2. apply ------------------------------------------------------------------
: >"$TMPROOT/a.jsonl"
pick anchor:wiki/alpha/renamed.md alpha/lib/new.sh
pick tag-pair:constraint+constraints constraint
pick 'link:wiki/alpha/linker.md:_COMMUNITY_Old Name' '_COMMUNITY_Split One'
pick anchor:wiki/misc/cross2.md beta/tools/helper.sh
# typed "Other" answers that the gate must reject: a nonexistent file, and the
# wrong-repo file the questions step deliberately did not offer
printf '%s\n' '{"id":"anchor:wiki/alpha/nosrc.md","kind":"anchor","note":"wiki/alpha/nosrc.md","to":"alpha/docs/nope.md"}' \
  '{"id":"anchor:wiki/alpha/cross.md","kind":"anchor","note":"wiki/alpha/cross.md","from":"alpha/scripts/helper.sh","to":"beta/tools/helper.sh"}' \
  '{"id":"anchor:wiki/misc/tool.md","kind":"anchor","note":"wiki/misc/tool.md","from":"misc/tool.sh","to":"gamma-folder/bin/tool.sh"}' \
  '{"id":"x","kind":"tag","note":"wiki/../../escape.md","from":"a","to":"b"}' \
  '{"id":"anchor:wiki/alpha/wrongrepo.md","kind":"untracked","note":"wiki/alpha/wrongrepo.md"}' \
  '{"id":"tag:wiki/alpha/nosrc.md:bash-tricks","kind":"untracked","note":"wiki/alpha/session.md"}' >>"$TMPROOT/a.jsonl"
cp "$VAULT/wiki/alpha/wrongrepo.md" "$TMPROOT/wrongrepo.before"
cp "$VAULT/wiki/alpha/nosrc.md" "$TMPROOT/nosrc.before"
cp "$VAULT/wiki/alpha/cross.md" "$TMPROOT/cross.before"
cp "$VAULT/wiki/alpha/session.md" "$TMPROOT/session.before"
cp "$VAULT/wiki/misc/tool.md" "$TMPROOT/tool.before"
BRAIN_ROOT="$VAULT" node "$TD" apply "$Q" "$TMPROOT/a.jsonl" >"$TMPROOT/apply.out" 2>&1; rc=$?
out="$(cat "$TMPROOT/apply.out")"
check "apply/runs" "$([[ $rc -eq 0 && "$out" == TIDY-DECIDE:* ]]; echo $?)" "rc=$rc out: [$out]"
check "apply/negative-control-missing-file" "$(cmp -s "$VAULT/wiki/alpha/nosrc.md" "$TMPROOT/nosrc.before" && grep -q '^REFUSED anchor:wiki/alpha/nosrc.md' "$TMPROOT/apply.out"; echo $?)" "out: [$out] note: [$(cat "$VAULT/wiki/alpha/nosrc.md")]"
check "apply/negative-control-wrong-repo" "$(cmp -s "$VAULT/wiki/alpha/cross.md" "$TMPROOT/cross.before" && grep -q '^REFUSED anchor:wiki/alpha/cross.md' "$TMPROOT/apply.out"; echo $?)" "out: [$out]"
check "apply/negative-control-folder-alias" "$(cmp -s "$VAULT/wiki/misc/tool.md" "$TMPROOT/tool.before" && grep -q '^REFUSED anchor:wiki/misc/tool.md' "$TMPROOT/apply.out"; echo $?)" "out: [$out]"
check "apply/negative-control-wrong-repo-untracked" "$(cmp -s "$VAULT/wiki/alpha/wrongrepo.md" "$TMPROOT/wrongrepo.before" && grep -q '^REFUSED anchor:wiki/alpha/wrongrepo.md' "$TMPROOT/apply.out"; echo $?)" "out: [$out]"
check "apply/refuses-unbound-edit" "$(grep -q '^REFUSED tag:wiki/alpha/nosrc.md:bash-tricks: not an edit this question offers' "$TMPROOT/apply.out"; echo $?)" "out: [$out]"
check "apply/refuses-path-escape" "$(grep -q '^REFUSED x' "$TMPROOT/apply.out"; echo $?)" "out: [$out]"
check "apply/anchor-written-crlf-kept" "$(grep -q $'^source: alpha/lib/new.sh\r$' "$VAULT/wiki/alpha/renamed.md" && ! grep -qv $'\r$' "$VAULT/wiki/alpha/renamed.md"; echo $?)" "note: [$(od -c "$VAULT/wiki/alpha/renamed.md" | head -5)]"
BRAIN_ROOT="$VAULT" node "$ANCH" wiki/alpha/renamed.md wiki/misc/cross2.md >/dev/null 2>&1; rc=$?
check "apply/anchors-pass-gate" "$([[ $rc -eq 0 ]]; echo $?)" "check-anchors rc=$rc"
check "apply/tag-folded" "$(grep -q '^tags: \[ops, constraint\]$' "$VAULT/wiki/misc/cross2.md"; echo $?)" "note: [$(cat "$VAULT/wiki/misc/cross2.md")]"
body="$(cat "$VAULT/wiki/alpha/linker.md")"
check "apply/link-keeps-alias-heading" "$([[ "$body" == *'[[_COMMUNITY_Split One|the old cluster]]'* && "$body" == *'[[_COMMUNITY_Split One#Members]]'* ]]; echo $?)" "body: [$body]"
check "apply/unanswered-listed-untouched" "$(grep -q '^UNANSWERED anchor:wiki/alpha/session.md' "$TMPROOT/apply.out" && cmp -s "$VAULT/wiki/alpha/session.md" "$TMPROOT/session.before"; echo $?)" "out: [$out]"

# --- 3. freshness after apply ---------------------------------------------------
scan "$TMPROOT/after.json"
check "fresh/broken-source-drops" "$([[ "$(count "$TMPROOT/before.json" broken-source wiki/alpha/renamed.md)" == 1 && "$(count "$TMPROOT/after.json" broken-source wiki/alpha/renamed.md)" == 0 ]]; echo $?)" "before/after"
check "fresh/singletons-cleared" "$(node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(a.some(x=>x.kind==="singleton-tag"&&/^constraints?$/.test(x.tag))?1:0)' "$TMPROOT/after.json"; echo $?)" "after: [$(grep -A1 singleton "$TMPROOT/after.json" | grep tag)]"
check "fresh/stub-links-fixed" "$([[ "$(count "$TMPROOT/before.json" dead-link wiki/alpha/linker.md)" == 3 && "$(count "$TMPROOT/after.json" dead-link wiki/alpha/linker.md)" == 1 ]]; echo $?)" "after dead: [$(count "$TMPROOT/after.json" dead-link)]"
newf="$(node -e 'const fs=require("fs");const k=x=>JSON.stringify(x);const b=new Set(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).map(k));
  process.stdout.write(JSON.parse(fs.readFileSync(process.argv[2],"utf8")).filter(x=>!b.has(k(x))).map(k).join("\n"))' "$TMPROOT/before.json" "$TMPROOT/after.json")"
check "fresh/no-new-findings" "$([[ -z "$newf" ]]; echo $?)" "new: [$newf]"

# --- 4. drop/remove options -------------------------------------------------------
: >"$TMPROOT/a.jsonl"
pick tag:wiki/alpha/nosrc.md:bash-tricks 'Drop tag'
pick 'link:wiki/alpha/linker.md:_COMMUNITY_Aliased Label' 'Remove link'
pick anchor:wiki/alpha/nosrc.md alpha/docs/guide.md
pick anchor:wiki/alpha/cross.md 'Mark source_untracked'
printf '%s\n' '{"id":"anchor:wiki/alpha/session.md","kind":"anchor","note":"wiki/alpha/session.md","from":"verified-in-session/2026-09-16","to":"alpha/../beta/tools/helper.sh"}' >>"$TMPROOT/a.jsonl"
BRAIN_ROOT="$VAULT" node "$TD" apply "$Q" "$TMPROOT/a.jsonl" >"$TMPROOT/apply.out" 2>&1
check "apply/negative-control-dotdot" "$(cmp -s "$VAULT/wiki/alpha/session.md" "$TMPROOT/session.before" && grep -q '^REFUSED anchor:wiki/alpha/session.md: anchor may not contain' "$TMPROOT/apply.out"; echo $?)" "out: [$(cat "$TMPROOT/apply.out")]"
check "apply/source-inserted" "$(grep -q '^source: alpha/docs/guide.md$' "$VAULT/wiki/alpha/nosrc.md" && [[ "$(sed -n 1p "$VAULT/wiki/alpha/nosrc.md")" == --- ]]; echo $?)" "note: [$(cat "$VAULT/wiki/alpha/nosrc.md")]"
check "apply/untracked-set" "$(sed -n '/^---$/,/^---$/p' "$VAULT/wiki/alpha/cross.md" | grep -q '^source_untracked: true$'; echo $?)" "note: [$(cat "$VAULT/wiki/alpha/cross.md")]"
check "apply/drop-tag" "$(grep -q '^tags: \[shell\]$' "$VAULT/wiki/alpha/nosrc.md"; echo $?)" "note: [$(cat "$VAULT/wiki/alpha/nosrc.md")] out: [$(cat "$TMPROOT/apply.out")]"
check "apply/remove-link-unwraps" "$(grep -q 'and Aliased Label\.$' "$VAULT/wiki/alpha/linker.md"; echo $?)" "body: [$(cat "$VAULT/wiki/alpha/linker.md")]"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
exit 0
