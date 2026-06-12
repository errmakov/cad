#!/usr/bin/env bash
# whats-up.sh — ad-hoc "where is this card right now?" for a single workitem.
#
# Usage: ./scripts/whats-up.sh <issue_number> [repo] [project_number] [--log]
#   repo            : owner/repo   (default: the repo of the current directory)
#   project_number  : Projects V2 # (default: the PROJECT_NUMBER repo variable, else 14)
#   --log / -l      : also dump the full step LOG of the most relevant run (gh run view --log)
#
# Prints, for one issue: board column, stage labels + a plain-English verdict of what
# the pipeline is doing with it, the linked PR, the last few timeline comments, any
# workflow run that is queued/running right NOW for it, and — the point — the ACTUAL
# job step tree (gh run view) of the most relevant run so you see real progress, not
# just derived state. Read-only — touches nothing.
#
# Per-issue run attribution relies on the `run-name: … #<issue>` set in the agent
# workflows; runs created before that shipped fall back to the issue's comment links.
#
# Requires: gh CLI (authenticated, repo + project + actions read) and jq.

set -uo pipefail

# ---- args: positionals (issue, repo, project) + optional --log flag anywhere ----
LOG=0; POS=()
for a in "$@"; do
  case "$a" in
    --log|-l) LOG=1 ;;
    *) POS+=("$a") ;;
  esac
done
ISSUE="${POS[0]:?Usage: whats-up.sh <issue_number> [repo] [project_number] [--log]}"
REPO="${POS[1]:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
if [ -z "${REPO:-}" ]; then
  echo "Could not determine repo — pass it: whats-up.sh $ISSUE owner/repo [project]" >&2
  exit 1
fi
OWNER="${REPO%%/*}"
PROJECT="${POS[2]:-$(gh variable get PROJECT_NUMBER 2>/dev/null || echo 14)}"

# Pipeline workflows, ordered by stage, for the "running now" sweep.
WORKFLOWS=(agent-saba.yml agent-dev.yml agent-test.yml agent-fix.yml agent-resolve.yml agent-deploy.yml review-feedback.yml)

bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
grn=$'\033[32m'; ylw=$'\033[33m'; red=$'\033[31m'; cyn=$'\033[36m'

# ---------- 1. Issue core (title, state, labels, comments) ----------
ISSUE_JSON=$(gh issue view "$ISSUE" --repo "$REPO" \
  --json number,title,state,url,labels,comments 2>/dev/null) || {
    echo "${red}#$ISSUE not found in $REPO${reset}" >&2; exit 1; }

TITLE=$(jq -r '.title' <<<"$ISSUE_JSON")
STATE=$(jq -r '.state' <<<"$ISSUE_JSON")
URL=$(jq -r '.url' <<<"$ISSUE_JSON")
LABELS=$(jq -r '[.labels[].name] | join(", ")' <<<"$ISSUE_JSON")
has() { jq -e --arg l "$1" 'any(.labels[]?.name; . == $l)' <<<"$ISSUE_JSON" >/dev/null 2>&1; }

echo
echo "${bold}#$ISSUE  $TITLE${reset}  ${dim}[$STATE]${reset}"
echo "${dim}$URL${reset}"

# ---------- 2. Board column ----------
COLUMN=$(gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 500 2>/dev/null \
  | jq -r --argjson n "$ISSUE" '.items[] | select(.content.number == $n) | .status // "—"')
[ -z "$COLUMN" ] && COLUMN="(not on board)"
echo "  ${bold}Board${reset}   : $COLUMN"
echo "  ${bold}Labels${reset}  : ${LABELS:-none}"

# ---------- 3. Plain-English verdict ----------
if   has needs-human;       then VERDICT="${red}🆘 STOPPED — needs you (a swarm/resolve gave up). Resume it by hand.${reset}"
elif has blocker;           then VERDICT="${ylw}🐝 Tests failing — the fix-swarm is working it in place.${reset}"
elif has redeploy-required; then VERDICT="${ylw}♻️  Skipped by a deploy on a merge conflict — needs another deploy kick to ship (resolve may be fixing the branch).${reset}"
elif has approved;          then VERDICT="${grn}✅ Approved — ships on the next batch deploy.${reset}"
elif has changes-requested; then VERDICT="${ylw}🔄 Changes requested — bouncing back to Dev for rework.${reset}"
elif has review-notified;   then VERDICT="${cyn}👀 Album sent — waiting for your approve / changes-requested label.${reset}"
elif has stage:doing;       then VERDICT="${cyn}🔧 An agent is actively working it right now (holds the WIP slot).${reset}"
elif has stage:done;        then VERDICT="${dim}⏸  Stage finished — waiting for the dispatcher to pull it one lane right.${reset}"
elif [ "$COLUMN" = "Ready to Deploy" ]; then VERDICT="${grn}🚀 Approved — waiting for the next batch deploy to merge & ship.${reset}"
elif [ "$COLUMN" = "Done" ]; then VERDICT="${grn}🏁 Shipped — live on the wall.${reset}"
else                             VERDICT="${dim}😴 Idle — queued in its lane, nothing in flight.${reset}"
fi
echo "  ${bold}Status${reset}  : $VERDICT"

# ---------- 4. Linked PR ----------
PR_JSON=$(gh pr list --repo "$REPO" --head "agent/issue-$ISSUE" --state all \
  --json number,state,isDraft,url 2>/dev/null | jq -r '.[0] // empty')
if [ -n "$PR_JSON" ]; then
  PRN=$(jq -r '.number' <<<"$PR_JSON"); PRS=$(jq -r '.state' <<<"$PR_JSON")
  PRD=$(jq -r 'if .isDraft then "draft" else "ready" end' <<<"$PR_JSON")
  echo "  ${bold}PR${reset}      : #$PRN  ($PRS, $PRD)  ${dim}agent/issue-$ISSUE${reset}"
else
  echo "  ${bold}PR${reset}      : ${dim}none yet${reset}"
fi

# ---------- 5. Last timeline comments ----------
echo
echo "  ${bold}Last activity${reset}"
jq -r '.comments | sort_by(.createdAt) | .[-3:] | reverse | .[]
  | "    \(.createdAt[5:16] | sub("T"; " "))  \(.author.login)  "
    + ((.body | split("\n")[0] | gsub("[*#`>]"; "") | .[0:64]))' <<<"$ISSUE_JSON" 2>/dev/null \
  || echo "    (no comments)"

# Run IDs referenced in the issue's own comments → per-issue run history (fallback
# attribution for runs created before run-name shipped).
COMMENT_RUN_IDS=$(jq -r '.comments[].body' <<<"$ISSUE_JSON" \
  | grep -oE 'actions/runs/[0-9]+' | grep -oE '[0-9]+' | sort -un | tail -6)

# Runs whose run-name carries "#<issue>" — exact per-issue attribution, any status.
# (jq matches the issue as a whole token so #11 doesn't match #112.)
TITLED=$(gh run list --repo "$REPO" -L 60 \
  --json databaseId,status,conclusion,displayTitle,createdAt \
  -q ".[] | select(.displayTitle | test(\"#${ISSUE}([^0-9]|\$)\"))
      | \"\(.createdAt) \(.databaseId) \(.status) \(.conclusion // \"-\") \(.displayTitle)\"" 2>/dev/null)

# ---------- 6. This issue's runs RIGHT NOW ----------
echo
echo "  ${bold}Running now${reset} ${dim}(queued/in_progress for #$ISSUE)${reset}"
ACTIVE=$(awk '$3=="in_progress" || $3=="queued"' <<<"$TITLED")
if [ -n "$ACTIVE" ]; then
  while read -r created id status _ rest; do
    [ -z "$id" ] && continue
    echo "    ${grn}${created:11:5}${reset}  $status  ${rest}  ${dim}run $id${reset}"
  done <<<"$ACTIVE"
else
  echo "    ${dim}— nothing in flight for this issue —${reset}"
fi

# ---------- 7. Pick the most relevant run and show its ACTUAL job steps ----------
# Prefer a live (in_progress/queued) titled run; else the newest titled run; else the
# newest comment-linked run id.
TARGET=$(awk '$3=="in_progress" || $3=="queued"{print $2; exit}' <<<"$TITLED")
[ -z "$TARGET" ] && TARGET=$(awk 'NR==1{print $2}' <<<"$(sort -r <<<"$TITLED")")
[ -z "$TARGET" ] && TARGET=$(echo "$COMMENT_RUN_IDS" | tr ' ' '\n' | tail -1)

if [ -n "$TARGET" ]; then
  # Resolve the run's job id(s) and render the actual STEP tree via `gh run view --job`.
  # (`gh run view <run>` only lists jobs for an in-progress single-job run — the ✓/*
  # per-step breakdown lives behind --job.)
  JOB_IDS=$(gh run view "$TARGET" --repo "$REPO" --json jobs -q '.jobs[].databaseId' 2>/dev/null)
  if [ -n "$JOB_IDS" ]; then
    for jid in $JOB_IDS; do
      echo
      echo "  ${bold}Job steps${reset} ${dim}(gh run view --job=$jid)${reset}"
      gh run view --job="$jid" --repo "$REPO" 2>/dev/null | sed 's/^/  /' \
        || echo "    job $jid unavailable"
      if [ "$LOG" = "1" ]; then
        echo
        echo "  ${bold}Step log${reset} ${dim}(gh run view --job=$jid --log)${reset}"
        LOGOUT=$(gh run view --job="$jid" --repo "$REPO" --log 2>/dev/null)
        if [ -n "$LOGOUT" ]; then
          printf '%s\n' "$LOGOUT" | sed 's/^/  /'
        else
          echo "    ${dim}(full logs are only available once the run completes)${reset}"
        fi
      fi
    done
  else
    echo
    echo "  ${bold}Job steps${reset} ${dim}(gh run view $TARGET)${reset}"
    gh run view "$TARGET" --repo "$REPO" 2>/dev/null | sed 's/^/  /' \
      || echo "    run $TARGET unavailable"
  fi
else
  echo
  echo "  ${dim}No run attributable to #$ISSUE (it predates run-name titles and its"
  echo "  comments carry no run link). Its next agent run will show up here by title.${reset}"
  echo "  ${dim}Browse all runs: gh run list --repo $REPO${reset}"
fi
echo
