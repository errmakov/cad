#!/usr/bin/env bash
# run-stats.sh — post-run analytics for the masterclass. Harvests per-agent SPEND from
# the Actions run LOGS (the FW_COST lines the agents print — nothing is posted to the
# issues) and computes LEAD TIME from the issue label timeline, then prints a Markdown
# table + totals you can drop straight onto a slide.
#
# Usage: ./scripts/run-stats.sh <owner> <repo> [runs_per_workflow]
#   runs_per_workflow : how many recent runs of each agent workflow to scan (default 80).
#
# Definitions:
#   cost      = sum of every FW_COST line for the issue across all agent runs (all
#               stages + retries), harvested from `gh run view --log`.
#   lead time = first `stage:doing` label (the dispatcher's SA/BA pull) → first
#               `approved` label (arrival in Ready to Deploy). Not-yet-approved → "—".
#
# Requires: gh CLI authenticated (repo + actions read) and jq. Read-only — posts nothing.

set -uo pipefail

OWNER="${1:?Usage: run-stats.sh <owner> <repo> [runs_per_workflow]}"
REPO="${2:?Usage: run-stats.sh <owner> <repo> [runs_per_workflow]}"
SCAN="${3:-80}"
SLUG="${OWNER}/${REPO}"

WORKFLOWS=(agent-saba.yml agent-dev.yml agent-test.yml agent-fix.yml agent-resolve.yml)

fmt_dur() {  # seconds -> "Xm YYs"
  local s="$1"
  printf '%dm%02ds' "$((s / 60))" "$((s % 60))"
}

median() {  # numbers as args -> median value (numeric). No args -> empty.
  [ "$#" -eq 0 ] && return 0
  printf '%s\n' "$@" | sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) exit
      if (NR % 2) printf "%s", a[(NR + 1) / 2]
      else        printf "%s", (a[NR / 2] + a[NR / 2 + 1]) / 2
    }'
}

# 1) Harvest FW_COST lines from recent completed runs of the agent workflows.
COST_TMP=$(mktemp)
trap 'rm -f "$COST_TMP"' EXIT
echo "Scanning agent run logs for spend (up to ${SCAN} runs/workflow)..." >&2
for wf in "${WORKFLOWS[@]}"; do
  ids=$(gh run list -w "$wf" --repo "$SLUG" -L "$SCAN" \
        --json databaseId,status -q '.[] | select(.status=="completed") | .databaseId' 2>/dev/null || true)
  for id in $ids; do
    gh run view "$id" --repo "$SLUG" --log 2>/dev/null \
      | grep -oE 'FW_COST issue=[0-9]+ role=[a-z]+ usd=[0-9.]+ in=[0-9]+ out=[0-9]+ cache=[0-9]+' \
      >> "$COST_TMP" || true
  done
  echo "  scanned ${wf}" >&2
done

cost_for() {  # issue -> summed usd across every harvested FW_COST line
  grep -E "FW_COST issue=$1 " "$COST_TMP" 2>/dev/null \
    | sed -E 's/.*usd=([0-9.]+).*/\1/' \
    | awk '{s += $1} END {printf "%.4f", s + 0}'
}

# 2) Walk the demo cards.
NUMS=$(gh issue list --repo "$SLUG" --label demo-backlog --state all --limit 200 \
  --json number -q '.[].number' | sort -n)
if [ -z "$NUMS" ]; then
  echo "No demo-backlog issues found in ${SLUG}."
  exit 0
fi

total_usd=0
total_lead=0
shipped=0
rows=""
lead_list=""   # lead-time seconds, shipped cards only (for median)
cost_list=""   # spend usd, shipped cards only (for median)

for n in $NUMS; do
  TITLE=$(gh issue view "$n" --repo "$SLUG" --json title -q '.title' 2>/dev/null \
    | sed 's/|/\\|/g')

  USD=$(cost_for "$n")

  TL=$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$num:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$num){
          timelineItems(itemTypes:[LABELED_EVENT], first:100){
            nodes{ ... on LabeledEvent { createdAt label{ name } } }
          }
        }
      }
    }' -f owner="$OWNER" -f name="$REPO" -F num="$n" \
    --jq '.data.repository.issue.timelineItems.nodes' 2>/dev/null || echo '[]')

  START=$(echo "$TL" | jq '[.[] | select(.label.name=="stage:doing") | .createdAt | fromdateiso8601] | min // empty' 2>/dev/null)
  END=$(echo "$TL"   | jq '[.[] | select(.label.name=="approved")   | .createdAt | fromdateiso8601] | min // empty' 2>/dev/null)

  LEAD_CELL="—"
  if [ -n "$START" ] && [ -n "$END" ] && [ "$END" -ge "$START" ] 2>/dev/null; then
    LEAD=$((END - START))
    LEAD_CELL=$(fmt_dur "$LEAD")
    total_lead=$((total_lead + LEAD))
    shipped=$((shipped + 1))
    lead_list="$lead_list $LEAD"
    cost_list="$cost_list $USD"
  fi

  USDF=$(printf '%.2f' "$USD" 2>/dev/null || echo "$USD")
  total_usd=$(awk -v a="$total_usd" -v b="$USD" 'BEGIN{printf "%.4f", a + b}')

  rows="${rows}| #${n} | ${TITLE} | \$${USDF} | ${LEAD_CELL} |"$'\n'
done

TOTAL_USDF=$(printf '%.2f' "$total_usd" 2>/dev/null || echo "$total_usd")
AVG_CELL="—"
MED_LEAD_CELL="—"
MED_COST_CELL="—"
if [ "$shipped" -gt 0 ]; then
  AVG_CELL="avg $(fmt_dur "$((total_lead / shipped))")"
  # Medians over shipped cards only (unshipped $0.00 / — rows excluded).
  med_lead=$(median $lead_list)
  MED_LEAD_CELL="med $(fmt_dur "$(printf '%.0f' "$med_lead")")"
  med_cost=$(median $cost_list)
  MED_COST_CELL="\$$(printf '%.2f' "$med_cost")"
fi

echo "## FactoryWall pipeline stats — ${SLUG}"
echo ""
echo "| # | Card | Cost | Lead time |"
echo "|---|------|------|-----------|"
printf '%s' "$rows"
echo "| | **${shipped} shipped** | **\$${TOTAL_USDF}** | **${AVG_CELL}** |"
echo "| | **median (shipped)** | **${MED_COST_CELL}** | **${MED_LEAD_CELL}** |"
echo ""
echo "_Cost = FW_COST log lines (every stage + retry). Lead time = first \`stage:doing\` → first \`approved\`._"
echo "_Average & median are over shipped cards only; unshipped (\$0.00 / —) rows are excluded._"
