#!/usr/bin/env bash
# =============================================================================
# backup-control-plane-files.sh — 備份「etcd snapshot 以外」還原 control plane 必需的檔案
#
# etcd snapshot 只有 etcd 的資料。要把它還原成一座能用的叢集，還需要：
#   /etc/kubernetes/pki/                 叢集 CA、etcd CA、API Server / SA 金鑰
#                                        （SA 金鑰不同 → 所有既有 ServiceAccount token 失效）
#   /etc/kubernetes/encryption-config.yaml  Secret 靜態加密金鑰（沒有它 → 還原後讀不出任何 Secret）
#   /etc/kubernetes/encryption/          （本叢集存在此目錄，一併保存）
#   /etc/kubernetes/*.conf               admin/controller-manager/scheduler/kubelet kubeconfig
#   /etc/kubernetes/manifests/           static Pod 定義（etcd/apiserver/... 的啟動參數）
#   /etc/kubernetes/audit-policy.yaml、auth-config.yaml、kube-vip.conf（本叢集有的自訂檔）
#
# 這些檔案等同「叢集的最高權限」—— 輸出一律加密，並且存放在叢集外、權限受控的位置。
#
# 用法（在每台 control-plane 上以 root 執行）：
#   sudo BACKUP_PASSPHRASE_FILE=/root/.cp-backup-pass ./backup-control-plane-files.sh
# 解密：
#   openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/root/.cp-backup-pass \
#     -in cp-files-k8s01-<時間>.tar.gz.enc | tar xz -C /tmp/restore
# =============================================================================
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "請用 root 執行"; exit 1; }
PASS_FILE="${BACKUP_PASSPHRASE_FILE:?請設定 BACKUP_PASSPHRASE_FILE（加密用的密碼檔）}"
OUT_DIR="${OUT_DIR:-/var/backups/k8s-control-plane}"
NODE="$(hostname -s)"
TS="$(date +%Y%m%d%H%M%S)"
OUT="$OUT_DIR/cp-files-$NODE-$TS.tar.gz.enc"

mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"

# 只收存在的路徑（不同叢集的自訂檔不一定都有）
PATHS=()
for p in /etc/kubernetes/pki /etc/kubernetes/manifests /etc/kubernetes/encryption \
         /etc/kubernetes/encryption-config.yaml /etc/kubernetes/admin.conf \
         /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf \
         /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf \
         /etc/kubernetes/audit-policy.yaml /etc/kubernetes/auth-config.yaml \
         /etc/kubernetes/kube-vip.conf /var/lib/kubelet/config.yaml; do
  [ -e "$p" ] && PATHS+=("$p")
done

tar czf - "${PATHS[@]}" 2>/dev/null \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$PASS_FILE" -out "$OUT"
chmod 600 "$OUT"

echo "已建立：$OUT"
echo "內容："; printf '  %s\n' "${PATHS[@]}"
echo
echo "下一步：把這個檔案複製到叢集外（例如 aws s3 cp 到 etcd-backups/<node>/cp-files/），"
echo "並確認密碼檔 $PASS_FILE 另外保存（密碼跟備份放一起 = 沒有加密）。"
