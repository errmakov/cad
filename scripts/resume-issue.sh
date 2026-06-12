#!/usr/bin/env bash
# resume-issue.sh — Resolve a `needs-human` card and signal the pipeline to resume.
#
# Usage: ./scripts/resume-issue.sh <owner/repo> <issue_number>
# Example: ./scripts/resume-issue.sh errmakov/agentic-kanban 42
#
# Use after you've done the human part — written guidance as an issue comment and/or
# pushed a fix to the feature branch agent/issue-<N>. This clears the human flags and
# tags the card `retry`; on its next tick the dispatcher re-dispatches the agent for
# the card's CURRENT silo (SA/BA→saba, Dev→dev, Test→fix) — no backward move — and
# resets the swarm attempt counter. Equivalent to doing the label swap in the board UI.
#
# Requires: gh CLI authenticated (repo + workflow scope).

set -euo pipefail

REPO="${1:?Usage: resume-issue.sh <owner/repo> <issue_number>}"
ISSUE="${2:?Usage: resume-issue.sh <owner/repo> <issue_number>}"

gh issue edit "$ISSUE" --repo "$REPO" \
  --remove-label "blocker" \
  --remove-label "needs-human" \
  --add-label "retry"

echo "Resumed #${ISSUE}: cleared blocker/needs-human, added 'retry'."

# Kick a dispatcher tick so the resume is processed now.
gh workflow run dispatcher.yml --repo "$REPO" \
  && echo "Dispatcher kicked — it will re-dispatch the card's silo agent." \
  || echo "Note: could not kick the dispatcher automatically; run it from the Actions tab."
