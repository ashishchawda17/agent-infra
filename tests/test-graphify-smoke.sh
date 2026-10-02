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

if printf '%s\n' "$wf" | grep -q '^permissions:' &&
   printf '%s\n' "$wf" | awk '/^permissions:/{f=1;next} f&&/^[^ ]/{exit} f' | grep -q '^  contents: read$'; then
  ok "permissions: contents: read"
else
  bad "permissions must declare contents: read"
fi

# The pin must match the skills' pin, so the run proves the version users get.
pin_of() { tr -d '\r' < "$1" | grep -o 'graphifyy==[0-9][0-9.]*' | sed 's/graphifyy==//' | sort -u; }
init_pin=$(pin_of brain/skills/init/SKILL.md)
doctor_pin=$(pin_of brain/skills/doctor/SKILL.md)
wf_pin=$(pin_of "$WF")
if [ -n "$wf_pin" ] && [ "$wf_pin" = "$init_pin" ] && [ "$wf_pin" = "$doctor_pin" ]; then
  ok "graphify pin $wf_pin matches init and doctor"
else
  bad "graphify pin drift: workflow='$wf_pin' init='$init_pin' doctor='$doctor_pin'"
fi
if printf '%s\n' "$wf" | grep -q "GRAPHIFY_VERSION: '$init_pin'"; then
  ok "version check expects $init_pin"
else
  bad "GRAPHIFY_VERSION must be '$init_pin'"
fi

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
