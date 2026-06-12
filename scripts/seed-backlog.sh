#!/usr/bin/env bash
# seed-backlog.sh — files the FactoryWall demo backlog as GitHub issues and drops
# them into the project board's "Todo" column.
#
# Usage: ./scripts/seed-backlog.sh <owner> <repo> <project_number>
#
# Requires: gh CLI authenticated with repo + project scopes.
#
# NOTE: Each card is a one-line human request. Acceptance criteria are intentionally
# NOT written here — producing them is the SA/BA agent's job (the first pipeline stage).
# Every issue is labelled `demo-backlog` so reset-rehearsal.sh can find and clear them.
#
# Resilient by design: GitHub's burst/secondary rate limit can throttle a tight
# create-loop, so each gh call retries with backoff, we pause between cards, and a
# single failure logs + continues instead of aborting the whole batch (NOT set -e).

set -uo pipefail

OWNER="${1:?Usage: seed-backlog.sh <owner> <repo> <project_number>}"
REPO="${2:?Usage: seed-backlog.sh <owner> <repo> <project_number>}"
PROJECT="${3:?Usage: seed-backlog.sh <owner> <repo> <project_number>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# retry <max> <initial_delay_s> -- <cmd...> : run cmd, retrying with exponential
# backoff on failure (especially GitHub rate limits). Prints stdout on success.
retry() {
  local max="$1" delay="$2"; shift 2
  local i out
  for ((i = 1; i <= max; i++)); do
    if out=$("$@" 2>/tmp/seed-err.txt); then printf '%s' "$out"; return 0; fi
    if grep -qiE 'rate limit|secondary|too quickly|abuse|timeout|try again' /tmp/seed-err.txt; then
      echo "    rate-limited/transient — retry ${i}/${max} in ${delay}s" >&2
    fi
    sleep "$delay"; delay=$((delay * 2))
  done
  cat /tmp/seed-err.txt >&2
  return 1
}

# find_item <issue_number> : return the project item id for an issue, polling until
# it appears. The repo auto-adds issues to the linked project asynchronously, so an
# item-add can race it and a single lookup can run before the item has propagated.
find_item() {
  local num="$1" i id
  for ((i = 1; i <= 8; i++)); do
    id=$(gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 500 2>/dev/null \
      | jq -r --argjson n "$num" '.items[] | select(.content.number == $n) | .id')
    if [ -n "$id" ] && [ "$id" != "null" ]; then printf '%s' "$id"; return 0; fi
    sleep 2
  done
  return 1
}

# Ensure the tracking labels exist (idempotent).
gh label create demo-backlog --repo "${OWNER}/${REPO}" \
  --color BFD4F2 --description "FactoryWall demo backlog card" 2>/dev/null || true
# Board-visible flag: a card that a deploy batch SKIPPED on a merge conflict and that
# needs another deploy kick to ship (otherwise it's indistinguishable from a freshly
# approved card just waiting in Ready to Deploy).
gh label create redeploy-required --repo "${OWNER}/${REPO}" \
  --color FBCA04 --description "Skipped on a deploy merge conflict — needs another deploy to ship" 2>/dev/null || true

# "title|one-line intent"
BACKLOG=(
  "Add a dark/light theme toggle|Let visitors switch FactoryWall between a light and a dark theme, and remember the choice."
  "Show a live attendee counter in the header|Display a number in the header representing how many people are viewing the wall."
  "Add an emoji reaction bar to the wall|Let visitors tap emoji reactions on the wall and see the running counts. The counts are shared across visitors and must survive a page reload and a redeploy (persist them server-side)."
  "Add a shared countdown timer|Let any visitor start a countdown: tap a +Countdown control, set minutes and seconds (MM:SS, up to 99:59) and start it. The running countdown is shared — every connected visitor sees the same timer ticking down in real time, and it survives a page reload and a redeploy (persist it server-side). When it reaches zero, show a clear 'Time's up' state."
  "Add a now-speaking banner|Show a banner naming the session currently on. DERIVE it client-side from a small built-in schedule (hardcode a list of start times + titles in the feature) and the current time — pick the session whose start time most recently passed; before the first one, show the first upcoming session. No server data, no API, no manual input — it computes itself from the clock so it renders correctly everywhere."
  "Show the day's agenda as a list|Display the day's agenda as a simple list of sessions and times."
  "Add speaker bio cards with ratings|Show a few speaker bio cards (name, role, short bio). Give EACH speaker card its own thumbs up / thumbs down rating, with per-speaker tallies persisted server-side so they survive reloads and redeploys."
  "Add a share-this-session button|Add a button that copies the current page link to the clipboard."
  "Add an FAQ accordion|Add a short FAQ section where each question expands to reveal its answer."
  "Add a live clock to the header|Show the current time in the header, updating every second. No server state needed — just a clean ticking clock."
  "Add a footer with a venue map link|Add a footer link labelled 'Venue map' that opens the venue location on Google Maps. Use https://maps.google.com/?q=conference+venue as the destination. The link must ALWAYS render — do not gate it behind an env var."
  "Add a jump-to-top button|Add a button that scrolls the page back to the top."
)

echo "Seeding ${#BACKLOG[@]} backlog issues into ${OWNER}/${REPO} (project ${PROJECT})..."
chmod +x "${SCRIPT_DIR}/move-issue.sh"

SEEDED=0
FAILED=""
for entry in "${BACKLOG[@]}"; do
  TITLE="${entry%%|*}"
  BODY="${entry#*|}"

  ISSUE_URL=$(retry 6 3 gh issue create --repo "${OWNER}/${REPO}" --title "$TITLE" --body "$BODY" --label demo-backlog)
  if [ -z "$ISSUE_URL" ]; then
    echo "  ::FAILED to create: ${TITLE}"
    FAILED="${FAILED} \"${TITLE}\""
    sleep 1
    continue
  fi
  echo "Created: $ISSUE_URL"
  NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')

  # Add to the project. The repo may be linked (auto-adds issues), so item-add can
  # report "already exists" — in that case just look the item up instead of failing.
  ITEM_ID=$(gh project item-add "$PROJECT" --owner "$OWNER" --url "$ISSUE_URL" --format json 2>/tmp/seed-err.txt | jq -r '.id' 2>/dev/null || true)
  if [ -z "$ITEM_ID" ] || [ "$ITEM_ID" = "null" ]; then
    # add raced the repo auto-add — poll until the item shows up
    ITEM_ID=$(find_item "$NUM")
  fi

  if [ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ]; then
    "${SCRIPT_DIR}/move-issue.sh" "$OWNER" "$PROJECT" "$ITEM_ID" "Todo" >/dev/null \
      && SEEDED=$((SEEDED + 1)) \
      || echo "  (could not set #${NUM} to Todo automatically; set it in the board UI)"
  else
    echo "  (could not add #${NUM} to the board automatically; add it in the UI)"
  fi

  sleep 1   # gentle throttle so the create-loop doesn't trip the burst limit
done

echo ""
echo "Done. ${SEEDED}/${#BACKLOG[@]} cards in Todo."
[ -n "$FAILED" ] && echo "Not created (re-run the seed):${FAILED}"
exit 0
