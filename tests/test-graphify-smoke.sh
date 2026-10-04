#!/usr/bin/env bash
# test-graphify-smoke.sh — static checks on .github/workflows/graphify-smoke.yml (INNOV-370).
# The workflow itself only runs on manual dispatch, so these guard what a PR can
# silently break: the trigger, the permissions, and the graphify pin drifting
# away from the one /brain:init and /brain:doctor install.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WF=.github/workflows/graphify-smoke.yml
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

[ -f "$WF" ] || { echo "FAIL $WF missing"; exit 1; }
wf=$(tr -d '\r' < "$WF")

# Trigger: workflow_dispatch and nothing else.
on_block=$(printf '%s\n' "$wf" | awk '/^on:/{f=1;next} f&&/^[^ #]/{exit} f')
if printf '%s\n' "$on_block" | grep -q '^  workflow_dispatch:' &&
   [ "$(printf '%s\n' "$on_block" | grep -c '^  [a-z_]*:')" = 1 ]; then
  ok "triggered only by workflow_dispatch"
else
  bad "trigger must be workflow_dispatch only"
fi

# Least privilege: contents: read and nothing else, at workflow and job level.
perm_block=$(printf '%s\n' "$wf" | awk '/^permissions:/{f=1;next} f&&/^[^ ]/{exit} f' | grep -v '^ *$')
if [ "$perm_block" = "  contents: read" ] &&
   [ "$(printf '%s\n' "$wf" | grep -c 'permissions:')" = 1 ]; then
  ok "permissions: contents: read only"
else
  bad "permissions must be exactly contents: read"
fi

# The pin lives once, in install-graphify.sh (INNOV-358). The workflow and the
# skills must install through it, so the run proves the version users get.
pin=$(tr -d '\r' < brain/bin/install-graphify.sh | sed -n 's/^GRAPHIFY_VERSION=//p')
if [ -n "$pin" ] && printf '%s\n' "$wf" | grep -q "GRAPHIFY_VERSION: '$pin'"; then
  ok "version check expects $pin"
else
  bad "GRAPHIFY_VERSION must be '$pin' (from brain/bin/install-graphify.sh)"
fi
for f in "$WF" brain/skills/init/SKILL.md brain/skills/doctor/SKILL.md brain/README.md; do
  t=$(tr -d '\r' < "$f")
  if printf '%s\n' "$t" | grep -q 'install-graphify.sh' && ! printf '%s\n' "$t" | grep -q 'graphifyy=='; then
    ok "$f installs through install-graphify.sh"
  else
    bad "$f must install via install-graphify.sh, not a bare graphifyy== pin"
  fi
done

if printf '%s\n' "$wf" | grep -q 'PYTHONHASHSEED: .0.'; then
  ok "PYTHONHASHSEED pinned to 0"
else
  bad "PYTHONHASHSEED must be 0"
fi

if printf '%s\n' "$wf" | grep -qiE 'API_KEY|secrets\.'; then
  bad "workflow must not reference an API key or secret"
else
  ok "no API key or secret"
fi

exit $fail
