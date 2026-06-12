#!/usr/bin/env bash
# poll-board.sh — Queries the GitHub Project board and returns items with their statuses.
#
# Usage: ./scripts/poll-board.sh <owner> <project_number>
# Output: JSON array of items with status, number, title, item_id
#
# Requires: gh CLI authenticated with project scope

set -euo pipefail

OWNER="${1:?Usage: poll-board.sh <owner> <project_number>}"
PROJECT_NUMBER="${2:?Usage: poll-board.sh <owner> <project_number>}"

# Fetch all project items with their Status field values.
#
# IMPORTANT: GitHub's GraphQL rate limit charges by the number of nodes a query
# *requests* (the `first:` / --limit), NOT the number returned. `--limit 500` on a
# ~12-item board costs ~100 GraphQL PER POLL — and the dispatcher polls every tick,
# so this dominates the whole pipeline's GraphQL spend. We cap it to BOARD_LIMIT
# (default 50) which is ~2x cheaper. It MUST stay >= the real board size, or the
# dispatcher would silently miss cards (truncated WIP counts / stranded pulls), so
# raise BOARD_LIMIT if you ever run a bigger board.
ITEMS_JSON=$(gh project item-list "$PROJECT_NUMBER" \
  --owner "$OWNER" \
  --format json \
  --limit "${BOARD_LIMIT:-50}")

# Transform into a simpler format: [{status, number, title, item_id, type, labels}]
# labels: the issue's label names — the dispatcher uses these for WIP sub-states
# (stage:doing / stage:done), blocker detection, and the swarm. gh exposes Labels
# as a project field; normalise whether it comes back as strings or {name} objects.
echo "$ITEMS_JSON" | jq '[
  .items[]
  | select(.content.number != null)
  | {
      status: .status,
      number: .content.number,
      title: .content.title,
      item_id: .id,
      type: .content.type,
      labels: ((.labels // []) | map(if type == "object" then .name else . end))
    }
]'
