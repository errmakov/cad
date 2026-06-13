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

# Fetch project items with ONLY the fields the dispatcher needs, via a LEAN GraphQL
# query. GitHub's GraphQL rate limit charges by the node count a query *requests*; the
# old `gh project item-list` pulls every custom field value of every item (~40–100
# points PER POLL), and the dispatcher polls on every tick — so it dominated the whole
# pipeline's GraphQL spend (a 3-card rehearsal could burn ~2,000). This query asks only
# for status + number + title + item-id + the first 10 labels: ~5 points per poll
# (~10x cheaper), and produces the IDENTICAL output shape (verified by diff).
#
# BOARD_LIMIT (default 50) caps items(first:). It MUST stay >= the real board size, or
# the dispatcher silently misses cards (truncated WIP counts / stranded pulls). likewise
# labels(first:10) must cover the most labels any one card carries at once
# (stage:doing / stage:done, blocker, needs-human, retry, review-notified, …).
read -r -d '' QUERY <<'GRAPHQL' || true
query($owner: String!, $number: Int!, $first: Int!) {
  user(login: $owner) {
    projectV2(number: $number) {
      items(first: $first) {
        nodes {
          id
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
          content {
            __typename
            ... on Issue       { number title labels(first: 10) { nodes { name } } }
            ... on PullRequest { number title labels(first: 10) { nodes { name } } }
          }
        }
      }
    }
  }
}
GRAPHQL

# Transform into the simpler format: [{status, number, title, item_id, type, labels}].
# labels: the dispatcher uses these for WIP sub-states (stage:doing / stage:done),
# blocker detection, and the swarm.
gh api graphql \
  -f query="$QUERY" \
  -f owner="$OWNER" \
  -F number="$PROJECT_NUMBER" \
  -F first="${BOARD_LIMIT:-50}" \
| jq '[
  .data.user.projectV2.items.nodes[]
  | select(.content.number != null)
  | {
      status: (.fieldValueByName.name // null),
      number: .content.number,
      title: .content.title,
      item_id: .id,
      type: .content.__typename,
      labels: [ .content.labels.nodes[].name ]
    }
]'
