#!/usr/bin/env bash
# =============================================================================
# restore-test.sh — 自動化 Restore Test：把最新的排程備份「真的還原一次」並用資料驗證
#
# 流程：
#   1. 找出 SCHEDULE_NAME 最新一份 Completed 備份
#   2. 建立 Velero Restore：SOURCE_NS → TARGET_NS（namespaceMapping，不碰正在運作的應用）
#   3. 等 Restore 完成、等應用 Ready
#   4. 執行資料驗證腳本（預設 dr/script/check-data.sh，查 DR-TEST-DB-001 與 DR-TEST-FS-001）
#   5. 清除這次還原出來的資源（依 velero.io/restore-name label，只刪這次還原的東西）
#   6. 通知結果與實測耗時（= 這個應用的實測 RTO 參考值）
#
# 為什麼 TARGET_NS 要事先存在：RBAC 只在這個 namespace 給權限（Role），
# 不必給 Job 叢集層級的 exec / 刪除 namespace 權限。
#
# 環境變數：SCHEDULE_NAME(daily-full-backup) BACKUP_NAME(可選，指定備份) SOURCE_NS(dr-demo) TARGET_NS(dr-restore-test)
#           CHECK_SCRIPT(./check-data.sh) RESTORE_TIMEOUT_MIN(30) KEEP_ON_FAILURE(true)
#           CLUSTER_NAME WEBHOOK_URL
# =============================================================================
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
S="${SCHEDULE_NAME:-daily-full-backup}"
SRC="${SOURCE_NS:-dr-demo}"
TGT="${TARGET_NS:-dr-restore-test}"
CHECK="${CHECK_SCRIPT:-$DIR/check-data.sh}"
TIMEOUT_MIN="${RESTORE_TIMEOUT_MIN:-30}"
C="${CLUSTER_NAME:-k8s-training}"
START=$(date +%s)
fail() { "$DIR/notify.sh" "❌ [$C] Restore Test 失敗（$SRC ← ${BACKUP:-?}）：$*"; exit 1; }

# 0. 目標 namespace 必須存在、而且是乾淨的（上一次失敗留下的資源要先處理）
kubectl get ns "$TGT" >/dev/null 2>&1 || fail "目標 namespace $TGT 不存在（請先 apply manifest/00-namespace-rbac.yaml）"
LEFT=$(kubectl -n "$TGT" get pvc,deploy -l velero.io/restore-name -o name 2>/dev/null | wc -l)
[ "$LEFT" -eq 0 ] || fail "$TGT 裡還有上一次還原留下的 $LEFT 個資源，請先檢查後清除"

# 1. 最新一份 Completed 備份，而且必須包含 SRC（includedNamespaces 為空或 * 或含 SRC）
# BACKUP_NAME 有設定時直接用（手動演練指定某一份備份），否則自動找排程的最新一份
BACKUP="${BACKUP_NAME:-}"
[ -n "$BACKUP" ] || BACKUP=$(kubectl -n velero get backups.velero.io -l velero.io/schedule-name="$S" -o json | jq -r --arg ns "$SRC" '
  [.items[] | select(.status.phase=="Completed")
            | select((.spec.includedNamespaces // ["*"]) as $i | ($i|index("*")) or ($i|index($ns)))]
  | sort_by(.status.completionTimestamp) | last | .metadata.name // empty')
[ -n "$BACKUP" ] || fail "找不到包含 $SRC 的 Completed 備份"
echo "使用備份：$BACKUP"

# 2. 建立 Restore（等同 velero restore create --from-backup ... --namespace-mappings SRC:TGT）
R="restore-test-$(date +%Y%m%d%H%M%S)"
kubectl create -f - <<YAML || fail "建立 Restore 失敗"
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $R
  namespace: velero
  labels:
    training/restore-test: "true"
spec:
  backupName: $BACKUP
  includedNamespaces: ["$SRC"]
  namespaceMapping:
    $SRC: $TGT
  restorePVs: true
  itemOperationTimeout: ${TIMEOUT_MIN}m
YAML

# 3. 等 Restore 結束
PHASE=""
for _ in $(seq 1 $((TIMEOUT_MIN * 6))); do
  PHASE=$(kubectl -n velero get restores.velero.io "$R" -o jsonpath='{.status.phase}')
  case "$PHASE" in Completed|PartiallyFailed|Failed|FailedValidation) break;; esac
  sleep 10
done
WARN=$(kubectl -n velero get restores.velero.io "$R" -o jsonpath='{.status.warnings}')
ERRS=$(kubectl -n velero get restores.velero.io "$R" -o jsonpath='{.status.errors}')
echo "Restore $R：phase=$PHASE warnings=${WARN:-0} errors=${ERRS:-0}"
[ "$PHASE" = Completed ] || fail "Restore $R 狀態為 ${PHASE:-逾時}（errors=${ERRS:-0}）"

# 等所有 Deployment Ready
kubectl -n "$TGT" wait deploy --all --for=condition=Available --timeout=600s \
  || fail "Restore Completed 但 Deployment 沒有 Ready —— 典型的「有備份但救不回來」"

# 4. 資料驗證（看資料，不是看 Pod）
if "$CHECK" "$TGT"; then RESULT=PASS; else RESULT=FAIL; fi
DUR=$(( ($(date +%s) - START) / 60 ))

# 5. 清除本次還原的資源（只刪帶有這次 restore-name label 的東西；PV 隨 reclaimPolicy=Delete 回收）
if [ "$RESULT" = PASS ] || [ "${KEEP_ON_FAILURE:-true}" != true ]; then
  kubectl -n "$TGT" delete all,pvc,secret,configmap,serviceaccount -l velero.io/restore-name="$R" --wait=true >/dev/null
  echo "已清除 $TGT 中還原的資源"
else
  echo "驗證失敗，保留 $TGT 中的資源供除錯（KEEP_ON_FAILURE=true）"
fi
# 只保留最近 5 次 restore-test 的 Restore 紀錄
kubectl -n velero get restores.velero.io -l training/restore-test=true -o json \
  | jq -r '.items | sort_by(.metadata.creationTimestamp) | .[:-5][] .metadata.name' \
  | xargs -r kubectl -n velero delete restores.velero.io >/dev/null

# 6. 通知
if [ "$RESULT" = PASS ]; then
  "$DIR/notify.sh" "✅ [$C] Restore Test 通過：$SRC ← $BACKUP，資料驗證 PASS，耗時 ${DUR} 分鐘（實測 RTO 參考）"
else
  fail "資料驗證未通過（耗時 ${DUR} 分鐘），資源保留在 $TGT"
fi
