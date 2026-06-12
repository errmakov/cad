#!/usr/bin/env bash
# move-issue.sh — Moves a project item to a target status column.
#
# Usage: ./scripts/move-issue.sh <owner> <project_number> <item_id> <target_status>
#
# Example: ./scripts/move-issue.sh my-org 5 PVTI_abc123 "Dev"
#
# Requires: gh CLI authenticated with project scope

set -euo pipefail

OWNER="${1:?Usage: move-issue.sh <owner> <project_number> <item_id> <target_status>}"
PROJECT_NUMBER="${2:?Usage: move-issue.sh <owner> <project_number> <item_id> <target_status>}"
ITEM_ID="${3:?Usage: move-issue.sh <owner> <project_number> <item_id> <target_status>}"
TARGET_STATUS="${4:?Usage: move-issue.sh <owner> <project_number> <item_id> <target_status>}"

# The project node id + Status field id + option ids are STATIC. Resolve them from the
# cheapest source first so a move normally costs just ONE GraphQL call (the item-edit
# below) instead of three:
#   1) $FW_PROJECT_META  — injected by the workflow from the repo variable (free)
#   2) the FW_PROJECT_META repo variable via REST (gh variable get; core bucket)
#   3) live GraphQL (project view + field-list), cached per-runner in /tmp (legacy path)
# 1/2 carry {project_id, status_field_id, options:{<name>:<id>}}; see cache-project-meta.sh.
META="${FW_PROJECT_META:-}"
if [ -z "$META" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  META=$(gh variable get FW_PROJECT_META --repo "$GITHUB_REPOSITORY" 2>/dev/null || true)
fi

PROJECT_ID=""; STATUS_FIELD_ID=""; TARGET_OPTION_ID=""
if [ -n "$META" ] && jq -e . >/dev/null 2>&1 <<<"$META"; then
  PROJECT_ID=$(jq -r '.project_id // empty' <<<"$META")
  STATUS_FIELD_ID=$(jq -r '.status_field_id // empty' <<<"$META")
  TARGET_OPTION_ID=$(jq -r --arg s "$TARGET_STATUS" '.options[$s] // empty' <<<"$META")
fi

# Fall back to live GraphQL if the cache is absent/stale or lacks this status.
if [ -z "$PROJECT_ID" ] || [ -z "$STATUS_FIELD_ID" ] || [ -z "$TARGET_OPTION_ID" ]; then
  CACHE="/tmp/fw-project-${OWNER}-${PROJECT_NUMBER}.json"
  if [ -s "$CACHE" ]; then
    PROJECT_ID=$(jq -r '.project_id' "$CACHE")
    FIELDS_JSON=$(jq -c '.fields' "$CACHE")
  else
    PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json | jq -r '.id')
    FIELDS_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json)
    if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
      jq -n --arg pid "$PROJECT_ID" --argjson fields "$FIELDS_JSON" \
        '{project_id: $pid, fields: $fields}' > "$CACHE" 2>/dev/null || true
    fi
  fi
  STATUS_FIELD_ID=$(echo "$FIELDS_JSON" | jq -r '.fields[] | select(.name == "Status") | .id')
  TARGET_OPTION_ID=$(echo "$FIELDS_JSON" | jq -r --arg status "$TARGET_STATUS" \
    '.fields[] | select(.name == "Status") | .options[] | select(.name == $status) | .id')
fi

if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
  echo "Error: Could not find project #${PROJECT_NUMBER} for owner ${OWNER}" >&2
  exit 1
fi
if [ -z "$STATUS_FIELD_ID" ] || [ "$STATUS_FIELD_ID" = "null" ]; then
  echo "Error: Could not find Status field in project" >&2
  exit 1
fi
if [ -z "$TARGET_OPTION_ID" ] || [ "$TARGET_OPTION_ID" = "null" ]; then
  echo "Error: Status '${TARGET_STATUS}' not found in project" >&2
  exit 1
fi

# Move the item
gh project item-edit \
  --id "$ITEM_ID" \
  --project-id "$PROJECT_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$TARGET_OPTION_ID" \
  --format json > /dev/null

echo "Moved item ${ITEM_ID} to '${TARGET_STATUS}'"
