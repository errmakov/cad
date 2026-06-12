#!/usr/bin/env bash
# gh-limits.sh — show the GitHub API rate-limit buckets at a glance, with how long
# until each resets. The pipeline lives on the GRAPHQL bucket (Projects V2 board
# reads + moves are GraphQL-only); REST is where our label/kick/dispatch calls go.
#
# Usage: ./scripts/gh-limits.sh [--watch]
#   --watch : refresh every 15s until you Ctrl-C
#
# The rate_limit endpoint itself does NOT count against any limit, so this is free
# to call (and to poll). Read-only.
#
# Requires: gh CLI (authenticated) and jq.

set -uo pipefail

bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
grn=$'\033[32m'; ylw=$'\033[33m'; red=$'\033[31m'

show() {
  local json now
  json=$(gh api rate_limit 2>/dev/null) || { echo "${red}Could not read rate_limit (is gh authenticated?)${reset}" >&2; return 1; }
  now=$(date +%s)

  echo
  echo "${bold}GitHub API limits${reset}  ${dim}($(date '+%H:%M:%S') local)${reset}"

  # Show the buckets that matter, in priority order. graphql first — it's the one the
  # pipeline exhausts.
  for res in graphql core search code_search; do
    local limit used remaining rst secs mins ss label colour bar filled pct
    limit=$(jq -r ".resources.${res}.limit // empty" <<<"$json")
    [ -z "$limit" ] && continue
    used=$(jq -r ".resources.${res}.used"      <<<"$json")
    remaining=$(jq -r ".resources.${res}.remaining" <<<"$json")
    rst=$(jq -r ".resources.${res}.reset"      <<<"$json")
    secs=$(( rst - now )); [ "$secs" -lt 0 ] && secs=0
    mins=$(( secs / 60 )); ss=$(( secs % 60 ))

    # colour by how much headroom is left
    pct=$(( remaining * 100 / (limit>0?limit:1) ))
    if   [ "$pct" -le 5 ];  then colour="$red"
    elif [ "$pct" -le 25 ]; then colour="$ylw"
    else                         colour="$grn"; fi

    # 20-char usage bar
    filled=$(( (limit - remaining) * 20 / (limit>0?limit:1) ))
    bar=""
    for ((i=0;i<20;i++)); do [ "$i" -lt "$filled" ] && bar="${bar}█" || bar="${bar}·"; done

    label=$(printf '%-11s' "$res")
    printf '  %s%s%s %s%s%s  %s%5d%s/%-5d left  %sresets %s (in %dm %02ds)%s\n' \
      "$bold" "$label" "$reset" \
      "$colour" "$bar" "$reset" \
      "$colour" "$remaining" "$reset" "$limit" \
      "$dim" "$(date -r "$rst" '+%H:%M:%S' 2>/dev/null || date -d "@$rst" '+%H:%M:%S')" "$mins" "$ss" "$reset"
  done
  echo
}

if [ "${1:-}" = "--watch" ]; then
  while true; do
    clear
    show || exit 1
    echo "  ${dim}refreshing every 15s — Ctrl-C to stop${reset}"
    sleep 15
  done
else
  show
fi
