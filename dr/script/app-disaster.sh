#!/usr/bin/env bash
# =============================================================================
# app-disaster.sh — 模擬「應用程式層級災難」：整個 dr-demo namespace 被刪除。
#
# ⚠️ 這是破壞性操作：PV 的 reclaimPolicy 是 Delete，namespace 一刪，
#    Ceph 上的 RBD image / CephFS subvolume 也會一起被刪除，資料無法從叢集內找回，
#    只能靠 Velero 放在叢集外 Object Storage 的備份。
#
# 刪除前會先確認：有一份「Completed」的 Velero 備份涵蓋 dr-demo。
# 沒有可用備份就拒絕執行 —— 演練也要養成「先確認能救，再動手」的習慣。
#
# 用法：./script/app-disaster.sh [namespace，預設 dr-demo]
# =============================================================================
set -euo pipefail
NS="${1:-dr-demo}"

echo "== 尋找涵蓋 namespace '$NS' 的最新 Completed 備份"
LATEST=$(kubectl -n velero get backups.velero.io -o json | python3 -c '
import json, sys
ns = sys.argv[1]
items = [b for b in json.load(sys.stdin)["items"]
         if b.get("status", {}).get("phase") == "Completed"
         and (ns in b["spec"].get("includedNamespaces", []) or "*" in b["spec"].get("includedNamespaces", ["*"]))]
items.sort(key=lambda b: b["status"].get("completionTimestamp", ""))
print(items[-1]["metadata"]["name"] if items else "")
' "$NS")

if [ -z "$LATEST" ]; then
  echo "找不到任何 Completed 備份涵蓋 $NS，拒絕執行。請先完成 03-first-backup。"
  exit 1
fi
echo "   最新備份：$LATEST"
kubectl -n velero get backups.velero.io "$LATEST" \
  -o jsonpath='   phase={.status.phase} errors={.status.errors} warnings={.status.warnings} completed={.status.completionTimestamp}{"\n"}'

echo
read -r -p "確定要刪除 namespace '$NS'（含所有 PV 資料）？輸入 namespace 名稱確認：" ans
[ "$ans" = "$NS" ] || { echo "取消。"; exit 1; }

kubectl delete namespace "$NS"

echo "== 災難後狀態"
kubectl get namespace "$NS" 2>&1 || true
kubectl get pv | grep "$NS/" || echo "   已無任何 PV 屬於 $NS（資料已隨 reclaimPolicy=Delete 刪除）"
echo
echo "接下來：到 04-first-restore 用 $LATEST 還原。"
