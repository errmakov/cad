#!/usr/bin/env bash
# setup-project.sh — Creates the GitHub Project board with required status columns.
#
# Usage: ./scripts/setup-project.sh <owner> <repo>
#
# This is a one-time setup helper. Run it locally to bootstrap the project board.
#
# Requires: gh CLI authenticated with project scope

set -euo pipefail

OWNER="${1:?Usage: setup-project.sh <owner> <repo>}"
REPO="${2:?Usage: setup-project.sh <owner> <repo>}"

echo "=== Agentic Kanban — Project Setup ==="
echo ""

# Step 1: Check gh auth
echo "Checking gh auth status..."
if ! gh auth status 2>/dev/null; then
  echo "Please authenticate with: gh auth login"
  exit 1
fi

# Check for project scope
if ! gh auth status 2>&1 | grep -q "project"; then
  echo "Adding 'project' scope to gh auth..."
  gh auth refresh -s project
fi

echo ""

# Step 2: Create the project
echo "Creating GitHub Project board..."
PROJECT_URL=$(gh project create \
  --owner "$OWNER" \
  --title "Agentic Kanban" \
  --format json 2>/dev/null | jq -r '.url' || echo "")

if [ -z "$PROJECT_URL" ]; then
  echo "Note: Project may already exist, or creation failed."
  echo "You can create it manually at: https://github.com/orgs/${OWNER}/projects/new"
  echo ""
  echo "Required status columns (create these in Board view):"
  echo "  1. Todo"
  echo "  2. Ready for Work"
  echo "  3. SA/BA"
  echo "  4. Dev"
  echo "  5. Test"
  echo "  6. Human Review"
  echo "  7. Ready to Deploy"
  echo "  8. Done"
  echo ""
  echo "After creating the project, note the project number from the URL"
  echo "and set it as the PROJECT_NUMBER repository variable."
  exit 0
fi

echo "Project created: $PROJECT_URL"
echo ""

# Step 3: Get project number from URL
PROJECT_NUMBER=$(echo "$PROJECT_URL" | grep -o '[0-9]*$')
echo "Project number: $PROJECT_NUMBER"

# Step 4: Link project to repo
echo "Linking project to repository ${OWNER}/${REPO}..."
gh project link "$PROJECT_NUMBER" --owner "$OWNER" --repo "${OWNER}/${REPO}" 2>/dev/null || true

echo ""
echo "=== Manual Steps Required ==="
echo ""
echo "The GitHub API cannot create custom status options programmatically"
echo "via the CLI. Please manually add these status columns in the Board view:"
echo ""
echo "  1. Go to: ${PROJECT_URL}"
echo "  2. Switch to Board view"
echo "  3. Edit the Status field to have these options (exact names):"
echo "     - Todo"
echo "     - Ready for Work"
echo "     - SA/BA"
echo "     - Dev"
echo "     - Test"
echo "     - Human Review"
echo "     - Ready to Deploy"
echo "     - Done"
echo ""
echo "Then set these GitHub repository variables:"
echo "  PROJECT_NUMBER=${PROJECT_NUMBER}"
echo "  PROJECT_OWNER=${OWNER}"
echo ""
echo "And these GitHub repository secrets:"
echo "  ANTHROPIC_API_KEY=sk-ant-..."
echo "  PROJECT_PAT=ghp_... (with project, repo, workflow scopes)"
echo "  TELEGRAM_BOT_TOKEN=..."
echo "  TELEGRAM_CHAT_ID=..."
echo ""
echo "Create the 'review-notified' label in your repo:"
echo "  gh label create review-notified --description 'Telegram notification sent' --color c5def5 --repo ${OWNER}/${REPO}"
echo ""
echo "=== Setup Complete ==="
