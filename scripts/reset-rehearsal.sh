#!/usr/bin/env bash
# reset-rehearsal.sh — restore a clean slate between pipeline rehearsals (Option C).
#
# Usage: ./scripts/reset-rehearsal.sh <owner> <repo> <project_number>
#   Optional: ARCHIVE_TAG=attempt-3 ./scripts/reset-rehearsal.sh ...   # keep this run's history
#
# What it does:
#   1. (optional) archive current master as tag rehearsal/<ARCHIVE_TAG>
#   2. force-reset master to the immutable `baseline` tag (restores app code + workflows)
#   3. delete all agent/issue-* remote branches
#   4. close the previous demo-backlog issues and remove their board items
#   5. re-seed a fresh backlog into Todo
#   6. trigger the `deploy-baseline` workflow to restore the VPS to the clean app AND
#      wipe the persisted data volume — rehearsals are independent, so reactions/timer/
#      tallies must start empty (skip the whole deploy with RESET_SKIP_DEPLOY=1)
#
# Requires: gh authenticated (repo + project scopes), git remote `origin`,
# branch protection on `master` OFF (or a PAT that can force-push).
#
# One-time setup (when the demo is first ready on master):
#   git tag baseline && git push origin baseline

set -euo pipefail

OWNER="${1:?Usage: reset-rehearsal.sh <owner> <repo> <project_number>}"
REPO="${2:?Usage: reset-rehearsal.sh <owner> <repo> <project_number>}"
PROJECT="${3:?Usage: reset-rehearsal.sh <owner> <repo> <project_number>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Fetching refs..."
# --force is REQUIRED: a plain `git fetch --tags` will NOT move a tag we already
# have locally, so a stale local `baseline` tag would make the master reset below a
# silent no-op ("Everything up-to-date") and leave the previous run's features on
# master. --force makes the local baseline tag always match origin.
git fetch origin --force --tags --prune

# 0. Safety: baseline tag must exist.
if ! git ls-remote --tags origin baseline | grep -q 'refs/tags/baseline'; then
  echo "ERROR: 'baseline' tag not found on origin."
  echo "Create it once when the demo is ready:  git tag baseline && git push origin baseline"
  exit 1
fi

# 1. Optional archive of the run we are about to wipe.
if [ -n "${ARCHIVE_TAG:-}" ]; then
  echo "==> Archiving current master as rehearsal/${ARCHIVE_TAG}..."
  git push origin "origin/master:refs/tags/rehearsal/${ARCHIVE_TAG}" || true
fi

# 2. Force-reset master to baseline.
echo "==> Force-resetting master to baseline..."
git push --force origin "refs/tags/baseline:refs/heads/master"

# 2a. VERIFY the reset actually took. The push above can report "Everything
#     up-to-date" and leave a feature-laden master in place; never reseed on top
#     of an un-reset master (that produces duplicate, already-implemented cards).
git fetch origin master >/dev/null 2>&1
if [ "$(git rev-parse origin/master)" != "$(git rev-parse "refs/tags/baseline")" ]; then
  echo "ERROR: master ($(git rev-parse --short origin/master)) != baseline ($(git rev-parse --short refs/tags/baseline)) after reset."
  echo "Master was NOT reset — aborting before reseeding. Check branch protection / push perms, then retry."
  exit 1
fi
echo "    master is now at baseline ($(git rev-parse --short refs/tags/baseline)) — clean scaffold confirmed."

# 3. Delete agent feature branches.
echo "==> Deleting agent/issue-* branches..."
for b in $(git ls-remote --heads origin 'agent/issue-*' | awk '{print $2}' | sed 's#refs/heads/##'); do
  echo "    - $b"
  git push origin --delete "$b" || true
done

# 4. Permanently delete previous demo issues (deleting an issue also removes its
#    board item). --state all also cleans up any closed ones from earlier runs.
#    Requires repo-admin rights; --yes skips the confirmation prompt.
echo "==> Deleting previous demo-backlog issues..."
CLOSED_NUMS=$(gh issue list --repo "${OWNER}/${REPO}" --label demo-backlog --state all --limit 200 --json number -q '.[].number' || true)
for n in $CLOSED_NUMS; do
  gh issue delete "$n" --repo "${OWNER}/${REPO}" --yes 2>/dev/null || true
done

if [ -n "$CLOSED_NUMS" ]; then
  echo "==> Removing their items from the board..."
  ITEMS_JSON=$(gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 500)
  for n in $CLOSED_NUMS; do
    ID=$(echo "$ITEMS_JSON" | jq -r --argjson num "$n" '.items[] | select(.content.number == $num) | .id')
    if [ -n "$ID" ] && [ "$ID" != "null" ]; then
      gh project item-delete "$PROJECT" --owner "$OWNER" --id "$ID" 2>/dev/null || true
    fi
  done
fi

# 5. Re-seed a fresh backlog.
echo "==> Re-seeding backlog..."
chmod +x "${SCRIPT_DIR}/seed-backlog.sh"
"${SCRIPT_DIR}/seed-backlog.sh" "$OWNER" "$REPO" "$PROJECT"

# 6. Restore the VPS to the clean baseline app. deploy-baseline rebuilds from the
#    (now reset) master, pushes ghcr.io/.../factorywall:baseline + :latest, and
#    deploys it — so the live app drops the previous rehearsal's features.
#    Opt out with RESET_SKIP_DEPLOY=1 (e.g. when offline or iterating locally).
if [ "${RESET_SKIP_DEPLOY:-0}" = "1" ]; then
  echo "==> Skipping VPS restore (RESET_SKIP_DEPLOY=1)."
  echo "    Restore later: gh workflow run deploy-baseline.yml --ref master --repo ${OWNER}/${REPO}"
else
  echo "==> Restoring the VPS to the clean baseline app (deploy-baseline)..."
  if gh workflow run deploy-baseline.yml --ref master --repo "${OWNER}/${REPO}" -f wipe_data=true; then
    echo "    Triggered. Watch it:"
    echo "    gh run watch \$(gh run list -w deploy-baseline.yml -L1 --repo ${OWNER}/${REPO} --json databaseId -q '.[0].databaseId') --repo ${OWNER}/${REPO}"
  else
    echo "    ::could not trigger deploy-baseline automatically — run it from the Actions tab."
  fi
fi

echo ""
echo "==> Reset complete (repo + board reset; clean baseline deploying to the VPS)."
