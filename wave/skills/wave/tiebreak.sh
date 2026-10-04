#!/usr/bin/env bash
# Resolve a direct, material conflict between the saved Codex Terra and Grok reviews.
# Never use this as a routine third review: at most one Astra call per worker run.
#
#   bash "$WAVE/tiebreak.sh" INNOV-309          # diff reviews (review.sh RISK_REVIEW=1)
#   bash "$WAVE/tiebreak.sh" --plan INNOV-309   # plan reviews (plan-review.sh, risk tier)
#
# Astra gets the compressed problem (two verdicts plus the diff or plan), not the repo.
set -uo pipefail

MODE=diff
[ "${1:-}" = "--plan" ] && { MODE=plan; shift; }
ISSUE="${1:-}"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "$MODE" = plan ]; then
  CODEX_LOG="$ROOT/.wave-plan-review.codex-terra.log"
  GROK_LOG="$ROOT/.wave-plan-review.grok.log"
  SUBJECT_FILE="$ROOT/.wave-plan.md"
  OUT="$ROOT/.wave-plan-review.astra"
  prompt="Resolve only a direct, material disagreement between the Codex Terra plan review in $CODEX_LOG and the Grok plan critique in $GROK_LOG for the implementation plan in $SUBJECT_FILE. Read all three files. State the evidence and exactly one resolution: REVISE PLAN (say how), KEEP PLAN, or NEEDS HUMAN. Do not suggest unrelated improvements. End with TIE-BREAK: <resolution>."
else
  CODEX_LOG="$ROOT/.wave-review.codex-terra.log"
  GROK_LOG="$ROOT/.wave-review.grok.log"
  SUBJECT_FILE="$ROOT/.wave-review.diff"
  OUT="$ROOT/.wave-review.astra"
  prompt="Resolve only a direct, material disagreement between the Codex Terra review in $CODEX_LOG and the Grok architecture review in $GROK_LOG for the diff in $SUBJECT_FILE. Read all three files. State the evidence and exactly one resolution: CLAUDE FIX, DISMISS FINDING, or NEEDS HUMAN. Do not suggest unrelated improvements. End with TIE-BREAK: <resolution>."
fi

[ -s "$CODEX_LOG" ] && [ -s "$GROK_LOG" ] && [ -s "$SUBJECT_FILE" ] || {
  echo "NO ASTRA TIE-BREAK: requires completed Codex, Grok, and $MODE logs"
  exit 1
}

out="$(timeout 900 codex -s read-only --model gpt-6-astra exec "$prompt" 2>"$OUT.err")"
printf '%s\n' "$out" > "$OUT.log"

if ! sed '/^[[:space:]]*$/d' <<< "$out" | tail -n 1 | grep -q '^TIE-BREAK: '; then
  echo "NO ASTRA TIE-BREAK: incomplete verdict; see ${OUT#"$ROOT"/}.log/.err"
  exit 1
fi
printf '%s\nTIE-BREAKER: astra (%s)\n' "$out" "$MODE"
