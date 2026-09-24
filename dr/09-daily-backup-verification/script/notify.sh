#!/usr/bin/env bash
# notify.sh <訊息> —— 送到 WEBHOOK_URL（Slack / Mattermost / Google Chat 相容的 {"text": ...} 格式）
# WEBHOOK_URL 沒設定時只印到 stdout（Job log 仍看得到）。
set -uo pipefail
MSG="$1"
echo "$MSG"
[ -n "${WEBHOOK_URL:-}" ] || { echo "(未設定 WEBHOOK_URL，略過通知)"; exit 0; }
jq -n --arg t "$MSG" '{text: $t}' \
  | curl -sS -m 15 -X POST -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK_URL" \
  || echo "通知送出失敗（不影響檢查結果）"
