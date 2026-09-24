#!/usr/bin/env bash
# =============================================================================
# restore-etcd-member.sh — 在「一台」control-plane 上，從 snapshot 重建本機 etcd 資料目錄
#
# ⚠️⚠️ 這是整座叢集等級的破壞性操作。預設只「印出」要執行的指令（dry-run），
#       加上 --execute 才會真的執行。不要在共用 / 正式叢集上練習。
#
# 前提（見 README 的安全確認清單）：
#   - 3 台 control-plane 都要各自執行一次本腳本，而且用「同一個」snapshot 檔
#   - 已經在 3 台上都停止 kube-apiserver 與 etcd（本腳本的 stop 步驟會做，但必須 3 台都做完才能 start）
#   - etcdutl 版本與叢集 etcd 相同（3.6.6）
#
# 用法：
#   sudo ./restore-etcd-member.sh stop                       # 3 台都先執行
#   sudo RESTORE_TOKEN=etcd-restore-20260923 ./restore-etcd-member.sh restore /root/snap.db
#                                                            # 3 台都執行：同一個 snapshot、同一個 RESTORE_TOKEN
#   sudo ./restore-etcd-member.sh start-etcd                 # 3 台都執行，確認 quorum
#   sudo ./restore-etcd-member.sh start-cp                   # 3 台都執行，啟動 apiserver 等
#   以上每個指令後面加 --execute 才會真的執行
# =============================================================================
set -euo pipefail

# ---- 本叢集的成員表（kubeadm stacked etcd，2026-09-23 實際設定）----
declare -A PEER=( [k8s01]=10.90.1.81 [k8s02]=10.90.1.82 [k8s03]=10.90.1.83 )
INITIAL_CLUSTER="k8s01=https://10.90.1.81:2380,k8s02=https://10.90.1.82:2380,k8s03=https://10.90.1.83:2380"
MANIFESTS=/etc/kubernetes/manifests
PARKED=/etc/kubernetes/manifests-parked      # 移出 manifests 目錄 = kubelet 停止該 static Pod
DATA_DIR=/var/lib/etcd

ACTION="${1:-}"; shift || true
SNAP=""; EXECUTE=0
for a in "$@"; do case "$a" in --execute) EXECUTE=1;; *) SNAP="$a";; esac; done

NODE="$(hostname -s)"
IP="${PEER[$NODE]:-}"
[ -n "$IP" ] || { echo "這台 ($NODE) 不在成員表中"; exit 1; }

run() { if [ $EXECUTE = 1 ]; then echo "+ $*"; eval "$@"; else echo "[dry-run] $*"; fi; }
[ $EXECUTE = 1 ] && [ "$(id -u)" != 0 ] && { echo "--execute 需要 root"; exit 1; }

case "$ACTION" in
  stop)
    # 先停 apiserver（不再寫 etcd），再停 controller-manager/scheduler，最後停 etcd
    run "mkdir -p $PARKED"
    for c in kube-apiserver kube-controller-manager kube-scheduler etcd; do
      run "mv $MANIFESTS/$c.yaml $PARKED/"
    done
    echo "等待容器停止：watch 'crictl ps | grep -E \"etcd|kube-apiserver\"' 直到沒有輸出"
    ;;
  restore)
    [ -n "$SNAP" ] && { [ $EXECUTE = 0 ] || [ -f "$SNAP" ]; } || { echo "請指定 snapshot 檔"; exit 1; }
    if [ $EXECUTE = 1 ] && crictl ps 2>/dev/null | grep -qE '\betcd\b'; then
      echo "etcd 容器還在跑，請先執行 stop 並等它停止"; exit 1
    fi
    TOKEN="${RESTORE_TOKEN:?請設定 RESTORE_TOKEN（3 台必須相同，例如 etcd-restore-20260923）}"
    TS=$(date +%Y%m%d%H%M%S)
    run "etcdutl snapshot status $SNAP -w table"                  # 確認檔案完整
    run "mv $DATA_DIR $DATA_DIR.before-restore-$TS"              # 保留舊資料，不要 rm！
    run "etcdutl snapshot restore $SNAP \
      --name $NODE \
      --initial-cluster $INITIAL_CLUSTER \
      --initial-advertise-peer-urls https://$IP:2380 \
      --initial-cluster-token $TOKEN \
      --data-dir $DATA_DIR"
    run "chmod 700 $DATA_DIR"
    echo "完成後到下一台執行同樣步驟（同一個 snapshot、同一個 RESTORE_TOKEN）。"
    ;;
  start-etcd)
    run "mv $PARKED/etcd.yaml $MANIFESTS/"
    echo "3 台都執行後，確認：etcdctl ... endpoint health --cluster -w table"
    ;;
  start-cp)
    for c in kube-apiserver kube-controller-manager kube-scheduler; do
      run "mv $PARKED/$c.yaml $MANIFESTS/"
    done
    run "systemctl restart kubelet"
    ;;
  *)
    sed -n '2,25p' "$0"; exit 1;;
esac
