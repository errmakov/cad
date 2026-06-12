#!/usr/bin/env bash
# agent-cost.sh — emit one agent's spend (from a Claude Code `--output-format json`
# result) as a machine-readable line in the job LOG, plus a human line in the Actions
# step summary. Nothing is posted to the issue — scripts/run-stats.sh harvests the
# FW_COST lines from the run logs locally after a rehearsal, keeping the issue threads
# clean during the live demo.
#
# Usage: agent-cost.sh <role> <claude-json> <repo> <issue>
#   role        : saba | dev | test | fix | resolve
#   claude-json : path to JSON saved from `claude ... --output-format json`
#   repo        : owner/repo (accepted for call-site symmetry; unused)
#   issue       : issue number (embedded in the FW_COST line so run-stats can group)
#
# Never fails the caller — a missing/partial JSON just no-ops.

set -uo pipefail

ROLE="${1:?Usage: agent-cost.sh <role> <claude-json> <repo> <issue>}"
JSON="${2:?Usage: agent-cost.sh <role> <claude-json> <repo> <issue>}"
REPO="${3:-}"   # accepted but unused (kept for call-site symmetry)
ISSUE="${4:?Usage: agent-cost.sh <role> <claude-json> <repo> <issue>}"

if [ ! -s "$JSON" ]; then
  echo "agent-cost: no JSON at ${JSON} — skipping (no spend recorded)."
  exit 0
fi

USD=$(jq -r '.total_cost_usd // 0' "$JSON" 2>/dev/null || echo 0)
IN=$(jq -r '.usage.input_tokens // 0' "$JSON" 2>/dev/null || echo 0)
OUT=$(jq -r '.usage.output_tokens // 0' "$JSON" 2>/dev/null || echo 0)
CACHE=$(jq -r '.usage.cache_read_input_tokens // 0' "$JSON" 2>/dev/null || echo 0)

case "$USD" in
  ''|*[!0-9.]*) USD=0 ;;
esac

# Machine-readable line — run-stats.sh greps this out of `gh run view --log`.
# The trailing space after issue=<n> lets run-stats match exactly (issue=6 vs issue=60).
echo "FW_COST issue=${ISSUE} role=${ROLE} usd=${USD} in=${IN} out=${OUT} cache=${CACHE} "

# Human line in the Actions step summary (visible in the run UI).
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  USDF=$(printf '%.4f' "$USD" 2>/dev/null || echo "$USD")
  printf '💵 **%s** (#%s) · $%s · %s in / %s out · cache %s\n' \
    "$ROLE" "$ISSUE" "$USDF" "$IN" "$OUT" "$CACHE" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi
