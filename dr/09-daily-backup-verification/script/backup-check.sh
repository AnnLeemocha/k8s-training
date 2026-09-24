#!/usr/bin/env bash
# =============================================================================
# backup-check.sh — 每日檢查：最新一份排程備份存在、夠新、Completed、沒有 error
#
# 為什麼不是只看「備份失敗通知」：本叢集 09-17 ~ 09-21 連續 5 天「沒有產生備份」，
# 沒有失敗紀錄可以通知。所以要檢查的是「最新一份成功備份距今多久」—— 沒有就是告警。
#
# 環境變數：
#   SCHEDULE_NAME   要檢查的 Velero Schedule（預設 daily-full-backup）
#   MAX_AGE_HOURS   最新 Completed 備份最多可以多舊（預設 26 = 每日 + 2 小時緩衝）
#   CLUSTER_NAME    通知訊息中的叢集名稱
#   NOTIFY_SUCCESS  true = 成功也通知（預設 true，讓「沒收到訊息」本身也成為異常訊號）
#   WEBHOOK_URL     通知目的地（可選）
# 結束碼：通過 0、失敗 1（Job 會顯示 Failed，kubectl get jobs 一眼看出）
# =============================================================================
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
S="${SCHEDULE_NAME:-daily-full-backup}"
MAX="${MAX_AGE_HOURS:-26}"
C="${CLUSTER_NAME:-k8s-training}"
NS=velero
PROBLEMS=()

# 1. BSL 是否可用（不可用 = 接下來的備份一定失敗）
BSL=$(kubectl -n $NS get backupstoragelocations.velero.io -o json \
      | jq -r '.items[] | "\(.metadata.name)=\(.status.phase // "Unknown")"' | tr '\n' ' ')
BAD_BSL=$(kubectl -n $NS get backupstoragelocations.velero.io -o json \
      | jq -r '.items[] | select(.status.phase != "Available") | .metadata.name')
echo "BSL: $BSL"
[ -n "$BAD_BSL" ] && PROBLEMS+=("BackupStorageLocation 不是 Available：$BSL")

# 2. Schedule 本身（注意一定要寫 schedules.velero.io，本叢集的 `schedules` 會拿到 Fleet 的資源）
SCHED_PHASE=$(kubectl -n $NS get schedules.velero.io "$S" -o jsonpath='{.status.phase}{" paused="}{.spec.paused}' 2>&1)
echo "Schedule $S: $SCHED_PHASE"
case "$SCHED_PHASE" in Enabled*) ;; *) PROBLEMS+=("Schedule $S 狀態異常：$SCHED_PHASE");; esac
echo "$SCHED_PHASE" | grep -q 'paused=true' && PROBLEMS+=("Schedule $S 被暫停")

# 3. 最新一份備份（不分狀態）與最新一份 Completed 備份
JSON=$(kubectl -n $NS get backups.velero.io -l velero.io/schedule-name="$S" -o json)
LATEST=$(echo "$JSON" | jq -c '[.items[]] | sort_by(.metadata.creationTimestamp) | last // empty')
LATEST_OK=$(echo "$JSON" | jq -c '[.items[] | select(.status.phase=="Completed")] | sort_by(.status.completionTimestamp) | last // empty')

if [ -z "$LATEST_OK" ]; then
  PROBLEMS+=("找不到任何 Completed 的 $S 備份")
else
  NAME=$(echo "$LATEST_OK" | jq -r .metadata.name)
  DONE=$(echo "$LATEST_OK" | jq -r .status.completionTimestamp)
  ERR=$(echo "$LATEST_OK" | jq -r '.status.errors // 0')
  WARN=$(echo "$LATEST_OK" | jq -r '.status.warnings // 0')
  ITEMS=$(echo "$LATEST_OK" | jq -r '"\(.status.progress.itemsBackedUp // 0)/\(.status.progress.totalItems // 0)"')
  AGE_H=$(echo "$LATEST_OK" | jq -r '(now - (.status.completionTimestamp | fromdateiso8601)) / 3600 | floor')   # 用 jq 算，避免 busybox date 不吃 ISO 格式
  echo "最新 Completed：$NAME 完成於 $DONE（${AGE_H}h 前）errors=$ERR warnings=$WARN items=$ITEMS"
  [ "$AGE_H" -gt "$MAX" ] && PROBLEMS+=("最新成功備份 $NAME 已經 ${AGE_H} 小時（上限 ${MAX}h）")
  [ "$ERR" != 0 ] && PROBLEMS+=("$NAME errors=$ERR")
fi
if [ -n "$LATEST" ]; then
  LP=$(echo "$LATEST" | jq -r '.status.phase // "New"'); LN=$(echo "$LATEST" | jq -r .metadata.name)
  case "$LP" in Completed|InProgress|New|Queued|WaitingForPluginOperations|Finalizing|FinalizingPartiallyFailed) ;;
    *) PROBLEMS+=("最新一次備份 $LN 狀態為 $LP");; esac
fi

# 4. 結果與通知
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  [ "${NOTIFY_SUCCESS:-true}" = true ] && "$DIR/notify.sh" "✅ [$C] Velero 備份正常：$NAME（${AGE_H}h 前完成，items $ITEMS，warnings $WARN）"
  exit 0
else
  "$DIR/notify.sh" "❌ [$C] Velero 備份檢查失敗（schedule: $S）
$(printf -- '- %s\n' "${PROBLEMS[@]}")"
  exit 1
fi
