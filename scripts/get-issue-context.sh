#!/usr/bin/env bash
# get-issue-context.sh — Fetches an issue's full context (body + all comments).
#
# Usage: ./scripts/get-issue-context.sh <repo> <issue_number>
# Output: Markdown document with issue title, body, labels, and all comments
#
# Requires: gh CLI authenticated with repo scope

set -euo pipefail

REPO="${1:?Usage: get-issue-context.sh <repo> <issue_number>}"
ISSUE_NUMBER="${2:?Usage: get-issue-context.sh <repo> <issue_number>}"

# Fetch issue details + comments via REST (gh api) so this stays OFF the GraphQL
# bucket — get-issue-context runs in every agent, so it was a top GraphQL consumer.
ISSUE_JSON=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}")
COMMENTS_JSON=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100")

TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
BODY=$(echo "$ISSUE_JSON" | jq -r '.body // "No description provided."')
LABELS=$(echo "$ISSUE_JSON" | jq -r 'if (.labels | length) > 0 then [.labels[].name] | join(", ") else "none" end')

# Output as structured markdown
cat <<EOF
# Issue #${ISSUE_NUMBER}: ${TITLE}

**Labels**: ${LABELS}

## Description

${BODY}
EOF

# Append all comments
COMMENT_COUNT=$(echo "$COMMENTS_JSON" | jq 'length')

if [ "$COMMENT_COUNT" -gt 0 ]; then
  echo ""
  echo "## Comments"
  echo ""

  echo "$COMMENTS_JSON" | jq -r '.[] | "### Comment by \(.user.login) (\(.created_at))\n\n\(.body)\n"'
fi
