#!/usr/bin/env bash
# notify-telegram.sh — Sends a message via Telegram Bot API.
#
# Usage: ./scripts/notify-telegram.sh "Your message here"
#
# Requires environment variables:
#   TELEGRAM_BOT_TOKEN — Bot token from @BotFather
#   TELEGRAM_CHAT_ID   — Target chat/user ID

set -euo pipefail

# Interpret backslash escapes (e.g. \n) so callers can pass multi-line messages
# as a single argument and have Telegram render real newlines.
MESSAGE=$(printf '%b' "${1:?Usage: notify-telegram.sh <message>}")

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "Warning: TELEGRAM_BOT_TOKEN not set, skipping notification" >&2
  exit 0
fi

if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "Warning: TELEGRAM_CHAT_ID not set, skipping notification" >&2
  exit 0
fi

# Send message via Telegram Bot API
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg chat_id "$TELEGRAM_CHAT_ID" \
    --arg text "$MESSAGE" \
    '{chat_id: $chat_id, text: $text, parse_mode: "Markdown", disable_web_page_preview: true}')")

if [ "$HTTP_STATUS" -ne 200 ]; then
  echo "Warning: Telegram API returned HTTP ${HTTP_STATUS}" >&2
  # Don't fail the workflow over a notification issue
  exit 0
fi

echo "Telegram notification sent"
