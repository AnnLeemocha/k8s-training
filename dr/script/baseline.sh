#!/usr/bin/env bash
# =============================================================================
# baseline.sh — 災難演練前，先留一份「叢集正常時長什麼樣子」的基準紀錄。
#
# 為什麼：還原完成後要回答「跟災難前一樣嗎？」，沒有基準就只能憑印象。
# 這份紀錄也是 08-cluster-rebuild 重建叢集時的「清單」：StorageClass、
# Gateway、Ceph 設定……都要照這裡的樣子重建回來。
#
# 用法：./script/baseline.sh [輸出目錄，預設 ./tmp/baseline-<時間>]
# 注意：輸出含叢集設定細節，請存放在叢集外、權限受控的位置。
# =============================================================================
set -uo pipefail

OUT="${1:-./tmp/baseline-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
echo "寫入基準紀錄到 $OUT"

run() {  # run <輸出檔名> <指令...>；單一指令失敗不中斷，只記錄錯誤
  local file="$1"; shift
  if "$@" > "$OUT/$file" 2>&1; then echo "  ok   $file"; else echo "  FAIL $file（見檔案內容）"; fi
}

# --- 叢集 / 工作負載 ---
run nodes.txt            kubectl get nodes -o wide
run versions.txt         kubectl version
run pods.txt             kubectl get pods -A -o wide
run pvc.txt              kubectl get pvc -A
run pv.txt               kubectl get pv
run storageclass.yaml    kubectl get storageclass -o yaml
run volumesnapshotclass.yaml kubectl get volumesnapshotclass -o yaml
run crds.txt             kubectl get crd

# --- 網路入口 ---
run gateway.yaml         kubectl get gateway -A -o yaml
run httproute.yaml       kubectl get httproute -A -o yaml

# --- Velero ---
run velero-bsl.txt       kubectl -n velero get backupstoragelocation -o wide
run velero-backups.txt   kubectl -n velero get backups.velero.io
run velero-schedules.txt kubectl -n velero get schedules.velero.io

# --- Rook / Ceph ---
run cephcluster.yaml     kubectl -n rook-ceph get cephcluster -o yaml
run cephfilesystem.yaml  kubectl -n rook-ceph get cephfilesystem -o yaml
run cephobjectstore.yaml kubectl -n rook-ceph get cephobjectstore -o yaml
run ceph-status.txt      kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
run ceph-osd-tree.txt    kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
run ceph-df.txt          kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df
run ceph-fs-status.txt   kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph fs status

echo "完成。"
