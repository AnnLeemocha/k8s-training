#!/usr/bin/env bash
# =============================================================================
# restore-apps-in-order.sh — 新叢集基礎元件就緒後，依相依順序用 Velero 還原應用
#
# 為什麼要分批：
#   - 一次還原全部，Velero 會照「資源種類」排序而不是「應用相依」排序；
#   - 分批可以每批驗證完再進下一批，出問題時範圍小、容易判斷。
# 預設 dry-run（只印出指令），加 --execute 才執行。
#
# 用法：
#   ./restore-apps-in-order.sh <備份名稱>            # 看會執行什麼
#   ./restore-apps-in-order.sh <備份名稱> --execute
# =============================================================================
set -euo pipefail
BACKUP="${1:?請指定備份名稱，例如 daily-full-backup-20260923010055}"
EXECUTE=0; [ "${2:-}" = "--execute" ] && EXECUTE=1

# 分批（依本課程產品的實際相依關係）：
#   第 1 批：沒有跨 namespace 相依、自帶資料庫的應用
#   第 2 批：跨 namespace 存取別人的應用（cloudbeaver 連 flarum/planka/peertube 的 DB）
#   第 3 批：DR 課程自己的 lab
TIERS=(
  "drawio filebrowser flarum planka onlyoffice peertube"
  "cloudbeaver"
  "dr-demo"
)
# 永遠不要從備份還原的 namespace（由各自的安裝程序重建）
NEVER="kube-system kube-public kube-node-lease velero rook-ceph cattle-system cattle-fleet-system etcd-backup"

run() { if [ $EXECUTE = 1 ]; then echo "+ $*"; eval "$@"; else echo "[dry-run] $*"; fi; }

echo "== 備份內容檢查：$BACKUP"
run "velero backup describe $BACKUP | sed -n '/^Phase/p;/^Namespaces/,/^Resources/p'"

i=0
for tier in "${TIERS[@]}"; do
  i=$((i+1))
  for ns in $tier; do
    case " $NEVER " in *" $ns "*) echo "跳過系統 namespace $ns"; continue;; esac
    run "velero restore create rebuild-$ns-\$(date +%Y%m%d%H%M) --from-backup $BACKUP --include-namespaces $ns --restore-volumes=true --wait"
  done
  echo "---- 第 $i 批完成。請先驗證（Pod Ready、HTTPRoute Accepted、資料查得到）再按 Enter 繼續 ----"
  [ $EXECUTE = 1 ] && read -r _
done
echo "全部完成。最後執行：./dr/script/check-data.sh dr-demo"
