#!/usr/bin/env bash
# pipeline-status.sh — whole-board health: is the line BUSY, IDLE-with-work (kick the
# dispatcher), STRANDED (a card holds a WIP slot but nothing is running), waiting on
# YOU, or fully DRAINED. Answers "is it idle, do I need to kick the dispatcher?".
#
# Usage: ./scripts/pipeline-status.sh [repo] [project_number]
#   repo            : owner/repo   (default: the repo of the current directory)
#   project_number  : Projects V2 # (default: the PROJECT_NUMBER repo variable, else 14)
#
# IDLE = nothing queued/in_progress across the dispatcher + every agent workflow.
# When idle, it classifies what's left and prints the ONE action to take.
#
# Requires: gh CLI (authenticated, repo + project + actions read) and jq.

set -uo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
if [ -z "${REPO:-}" ]; then
  echo "Could not determine repo — pass it: pipeline-status.sh owner/repo [project]" >&2
  exit 1
fi
OWNER="${REPO%%/*}"
PROJECT="${2:-$(gh variable get PROJECT_NUMBER 2>/dev/null || echo 14)}"

bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
grn=$'\033[32m'; ylw=$'\033[33m'; red=$'\033[31m'; cyn=$'\033[36m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- board ----------
BOARD=$("$SCRIPT_DIR/poll-board.sh" "$OWNER" "$PROJECT" 2>/dev/null) || {
  echo "${red}Could not read the board.${reset}" >&2; exit 1; }

# jq helper: list "  #<n>  <title>" for a filter expression over the items array.
list() { jq -r "[.[] | $1] | sort_by(.number) | .[] | \"    #\(.number)  \(.title[0:54])\"" <<<"$BOARD"; }
cnt()  { jq "[.[] | $1] | length" <<<"$BOARD"; }

STRANDED_F='select(.labels|index("stage:doing"))'
KICK_RFW_F='select(.status=="Ready for Work")'
KICK_DONE_F='select((.labels|index("stage:done")) and (.status|IN("SA/BA","Dev","Test")))'
KICK_BLK_F='select((.labels|index("blocker")) and ((.labels|index("stage:doing"))|not) and ((.labels|index("needs-human"))|not))'
NEEDHUMAN_F='select(.labels|index("needs-human"))'
HR_F='select(.status=="Human Review" and ((.labels|index("needs-human"))|not))'
RTD_F='select(.status=="Ready to Deploy")'

n_stranded=$(cnt "$STRANDED_F")
n_kick=$(( $(cnt "$KICK_RFW_F") + $(cnt "$KICK_DONE_F") + $(cnt "$KICK_BLK_F") ))
n_needhuman=$(cnt "$NEEDHUMAN_F")
n_hr=$(cnt "$HR_F")
n_rtd=$(cnt "$RTD_F")

# ---------- anything queued/in_progress? ----------
WATCH=(dispatcher.yml agent-saba.yml agent-dev.yml agent-test.yml agent-fix.yml agent-resolve.yml agent-deploy.yml review-feedback.yml)
ACTIVE=""
for wf in "${WATCH[@]}"; do
  rows=$(gh run list -w "$wf" --repo "$REPO" -L 8 \
    --json databaseId,status,displayTitle,createdAt \
    -q '.[] | select(.status=="in_progress" or .status=="queued")
        | "    \(.createdAt[11:16])  \(.status)  \(.displayTitle[0:46])  run \(.databaseId)"' 2>/dev/null)
  [ -n "$rows" ] && ACTIVE="${ACTIVE}${rows}"$'\n'
done
n_active=$(printf '%s' "$ACTIVE" | grep -c . || true)

# ---------- board summary ----------
echo
echo "${bold}Pipeline — $REPO  (project $PROJECT)${reset}"
jq -r '
  (["Ready for Work","SA/BA","Dev","Test","Human Review","Ready to Deploy","Done"]) as $order
  | group_by(.status)
  | map({status: .[0].status, n: length}) as $g
  | $order[] as $s
  | "    \($s): \(($g[] | select(.status==$s) | .n) // 0)"' <<<"$BOARD" | paste -sd'   ' -

# ---------- verdict ----------
echo
if [ "$n_active" -gt 0 ]; then
  echo "  ${grn}${bold}● BUSY${reset} — ${n_active} run(s) in flight. Let it cook; re-check in ~30s."
  printf '%s' "$ACTIVE"
else
  echo "  ${dim}● Nothing queued or running across the dispatcher + all agents.${reset}"
  echo

  if [ "$n_stranded" -gt 0 ]; then
    echo "  ${red}${bold}⚠ STRANDED${reset} — ${n_stranded} card(s) hold a WIP slot (${bold}stage:doing${reset}) but nothing is running."
    echo "  ${dim}A crashed/rate-limited run. A plain dispatcher kick will NOT free these (it treats"
    echo "  stage:doing as in-flight). Inspect, then re-dispatch the silo agent:${reset}"
    list "$STRANDED_F"
    echo "  ${bold}→ ./scripts/whats-up.sh <n>${reset}  then re-run that silo's agent (or clear stage:doing and kick)."
    echo
  fi

  if [ "$n_kick" -gt 0 ]; then
    echo "  ${ylw}${bold}↻ IDLE with work waiting${reset} — ${n_kick} card(s) the dispatcher can move:"
    list "$KICK_RFW_F";  list "$KICK_DONE_F";  list "$KICK_BLK_F"
    echo "  ${bold}→ kick the dispatcher:${reset}  gh workflow run dispatcher.yml -R $REPO"
    echo "  ${dim}  (REST: gh api --method POST repos/$REPO/actions/workflows/dispatcher.yml/dispatches -f ref=master)${reset}"
    echo
  fi

  if [ "$n_needhuman" -gt 0 ]; then
    echo "  ${red}${bold}🆘 needs-human${reset} — ${n_needhuman} card(s) stopped on purpose (swarm/resolve gave up):"
    list "$NEEDHUMAN_F"
    echo "  ${bold}→ fix, then:${reset}  ./scripts/resume-issue.sh $REPO <n>"
    echo
  fi

  if [ "$n_hr" -gt 0 ]; then
    echo "  ${cyn}${bold}👀 Your turn${reset} — ${n_hr} card(s) in Human Review awaiting your decision:"
    list "$HR_F"
    echo "  ${bold}→ add the label${reset}  approved  ${dim}or${reset}  changes-requested  ${dim}on the issue.${reset}"
    echo
  fi

  if [ "$n_rtd" -gt 0 ]; then
    echo "  ${grn}${bold}🚀 Ready to Deploy${reset} — ${n_rtd} card(s) waiting for a deploy kick:"
    list "$RTD_F"
    echo "  ${bold}→ ship them (one batch):${reset}  gh workflow run agent-deploy.yml -R $REPO"
    echo
  fi

  if [ "$n_stranded" -eq 0 ] && [ "$n_kick" -eq 0 ] && [ "$n_needhuman" -eq 0 ] && [ "$n_hr" -eq 0 ] && [ "$n_rtd" -eq 0 ]; then
    echo "  ${grn}${bold}✓ DRAINED${reset} — nothing running, nothing waiting. The line is clear."
  fi
fi
echo
