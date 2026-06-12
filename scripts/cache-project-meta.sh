#!/usr/bin/env bash
# cache-project-meta.sh — one-time: stash the STATIC Projects V2 ids (project node id,
# Status field id, and every status option id) into the repo variable FW_PROJECT_META.
#
# Why: move-issue.sh otherwise re-derives these with two GraphQL reads (project view +
# field-list) on every cold runner — the single fattest avoidable GraphQL cost in the
# pipeline. With the variable set, move-issue.sh reads it (env-injected = free, or one
# REST var-get) and only spends GraphQL on the move itself.
#
# Usage: ./scripts/cache-project-meta.sh <owner> <project_number> <owner/repo>
# Example: ./scripts/cache-project-meta.sh errmakov 14 errmakov/agentic-kanban
#
# Run ONCE (and again only if the project / its Status field is recreated). The ids are
# not secret. move-issue.sh falls back to live GraphQL if the variable is missing/stale,
# so the pipeline keeps working even if you never run this.
#
# Requires: gh CLI authenticated (project + repo:actions-variables write) and jq.

set -euo pipefail

OWNER="${1:?Usage: cache-project-meta.sh <owner> <project_number> <owner/repo>}"
PROJECT_NUMBER="${2:?Usage: cache-project-meta.sh <owner> <project_number> <owner/repo>}"
REPO="${3:?Usage: cache-project-meta.sh <owner> <project_number> <owner/repo>}"

echo "Fetching project metadata (2 GraphQL reads)..." >&2
PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json | jq -r '.id')
FIELDS_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json)

if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
  echo "ERROR: could not resolve project #${PROJECT_NUMBER} for ${OWNER}" >&2; exit 1
fi

# Build the compact metadata the mover needs: { project_id, status_field_id, options{name:id} }
META=$(echo "$FIELDS_JSON" | jq -c --arg pid "$PROJECT_ID" '
  (.fields[] | select(.name == "Status")) as $sf
  | {
      project_id: $pid,
      status_field_id: $sf.id,
      options: ( $sf.options | map({ (.name): .id }) | add )
    }')

if [ -z "$META" ] || [ "$(jq -r '.status_field_id // empty' <<<"$META")" = "" ]; then
  echo "ERROR: no 'Status' single-select field found in project #${PROJECT_NUMBER}" >&2
  echo "$FIELDS_JSON" | jq -r '.fields[].name' >&2
  exit 1
fi

echo "Resolved:" >&2
echo "$META" | jq '{project_id, status_field_id, statuses: (.options | keys)}' >&2

gh variable set FW_PROJECT_META --repo "$REPO" --body "$META"
echo "✓ Stored FW_PROJECT_META on ${REPO}. move-issue.sh will now skip the metadata reads." >&2
