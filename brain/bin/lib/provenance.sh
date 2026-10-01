#!/usr/bin/env bash
# lib/provenance.sh — the ONE definition of "is this graph's build commit on the
# repo's reference branch", shared by the sync-time gate (sync-graph.sh) and the
# doctor-time report (check-mirror-source.sh --behind, INNOV-354).
#
# Moved here verbatim from sync-graph.sh: two copies would drift, and the drift
# would be doctor and the publish gate disagreeing about which branch a mirror is
# measured against (the INNOV-274 defect condition, as in lib/branch.sh).
#
# PRECONDITION: the caller sets $VAULT and $SCRIPT_DIR (the plugin's bin/) before
# sourcing, then calls load_reference_branches once. No other top-level work.
#
# --- THE PROVENANCE GATE (INNOV-353) -------------------------------------
#
# A shared mirror used to reflect whichever commit the last person to sync had
# checked out. One team vault held a mirror 1,429 commits behind its trunk and
# another built from a feature branch, and both passed every sync-graph.sh check: the
# staleness test says "differs", never "newer" or "from the right branch", and
# the scope audit looks at which files are in the graph, not which commit.
#
# The rule: `built_at_commit` must be an ancestor of origin/<reference branch>.
# ONE long-running branch per repo, because "built from the agreed branch" only
# means something against one line of history. A commit AHEAD of that branch is
# refused too — unmerged code does not belong in the shared graph — and so is a
# branch that was later SQUASH-merged: its commits never enter the reference
# branch's history, so from the graph alone it is indistinguishable from a branch
# abandoned a year ago. Rebuilding from the reference branch is the only way to
# get a mirror anyone can verify.
#
# Same polarity as the scope gate, for the same reason: a positive finding
# REFUSES, "could not check" is SKIPPED, says why, and publishes. Every graph
# built before graphify stamped the commit is unverifiable, and refusing those
# would break working vaults over a rule they were never able to meet.
#
# Nothing here fetches or moves the source checkout. The ref is whatever the
# checkout last fetched: a commit on the reference branch is one the checkout got
# BY fetching it, so a stale ref can only ever err towards SKIPPED or REFUSED.
# shellcheck source=branch.sh
source "$SCRIPT_DIR/lib/branch.sh"

# repos.json's configured reference branches. Parallel arrays, as the alias map.
REPO_BRANCH_NAMES=()
REPO_BRANCH_REFS=()
load_reference_branches() {
  REPO_BRANCH_NAMES=()
  REPO_BRANCH_REFS=()
  if command -v node >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/resolve-repos.mjs" ]]; then
    while IFS=$'\t' read -r _branch_name _branch_ref; do
      _branch_ref="${_branch_ref%$'\r'}"
      [[ -n "$_branch_name" && -n "$_branch_ref" ]] || continue
      REPO_BRANCH_NAMES+=("$_branch_name")
      REPO_BRANCH_REFS+=("$_branch_ref")
    done < <(node "$SCRIPT_DIR/resolve-repos.mjs" --vault "$VAULT" --print-branches 2>/dev/null || true)
  fi
}


# Checks one mirror. Sets PROV_VERDICT (OK | REFUSED | SKIPPED) and PROV_DETAIL:
# for OK and REFUSED "<commit> <branch> <how the branch was chosen>", for SKIPPED
# the reason. Always returns 0 so `set -e` cannot turn a report into an abort.
provenance_check() { # graph_path repo_path mirror_name
  local graph="$1" repo="$2" nm="$3" sha="" branch="" how="" rc=0 i=0
  PROV_VERDICT="SKIPPED"
  # The ROOT property only, so a real JSON parse: a textual match would also find
  # a node attribute of the same name, and pass or refuse on the wrong commit.
  sha="$(node -e 'const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).built_at_commit;
    if (typeof v === "string") process.stdout.write(v);' "$graph" 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    PROV_DETAIL="graph.json could not be read for its built_at_commit (node, or the file itself)"; return 0
  fi
  if [[ -z "$sha" ]]; then
    PROV_DETAIL="graph.json carries no built_at_commit (rebuild it with a current graphify)"; return 0
  fi
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    PROV_DETAIL="built_at_commit '$sha' is not a commit id"; return 0
  fi
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    PROV_DETAIL="$repo is not a git checkout"; return 0
  fi
  while [[ $i -lt ${#REPO_BRANCH_NAMES[@]} ]]; do
    if [[ "${REPO_BRANCH_NAMES[$i]}" == "$nm" ]]; then branch="${REPO_BRANCH_REFS[$i]}"; fi
    i=$((i + 1))
  done
  if [[ -n "$branch" ]]; then
    how="configured in repos.json"
  else
    # detect_default_branch reads $VAULT; here the repo in question is the SOURCE.
    branch="$(VAULT="$repo" detect_default_branch)"
    how="the detected default, not configured - set \"branch\" for $nm in repos.json if that is the wrong branch"
  fi
  if [[ -z "$branch" ]]; then
    PROV_DETAIL="no reference branch: repos.json sets no \"branch\" for $nm and the checkout's default could not be detected"; return 0
  fi
  if ! git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" >/dev/null 2>&1; then
    PROV_DETAIL="the checkout has no origin/$branch ($how) - fetch it, or correct the branch"; return 0
  fi
  if ! git -C "$repo" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
    PROV_DETAIL="built_at_commit ${sha:0:12} is not in this checkout, so it cannot be compared to origin/$branch ($how)"; return 0
  fi
  git -C "$repo" merge-base --is-ancestor "$sha" "refs/remotes/origin/$branch" >/dev/null 2>&1 || rc=$?
  PROV_DETAIL="${sha:0:12} $branch $how"
  if [[ $rc -eq 0 ]]; then
    PROV_VERDICT="OK"
  elif [[ $rc -ne 1 ]]; then
    PROV_DETAIL="git could not compare ${sha:0:12} to origin/$branch ($how)"
  elif [[ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]]; then
    # History is cut, so "not an ancestor" proves nothing here.
    PROV_DETAIL="the checkout is a shallow clone, so ${sha:0:12} cannot be placed on origin/$branch ($how)"
  else
    PROV_VERDICT="REFUSED"
  fi
  return 0
}
