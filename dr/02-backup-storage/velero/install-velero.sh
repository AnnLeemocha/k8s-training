#!/usr/bin/env bash
# =============================================================================
# install-velero.sh — 還原這座叢集目前 Velero 的安裝參數（v1.18.2）
#
# 參數是從線上實際狀態反推的（2026-09-23）：
#   kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.containers[0].args}'
#     → ["server","--features=EnableCSI","--uploader-type=kopia", ...]
#   kubectl -n velero get bsl default -o yaml
#     → provider aws / bucket velero / s3Url http://10.90.1.125:8333 / s3ForcePathStyle
#
# 單元 8（整座叢集重建）會用到這支腳本：新叢集跑一次，指向同一個 bucket，
# 舊叢集的備份就會自動同步出現在新叢集。
# =============================================================================
set -euo pipefail

S3_URL="${S3_URL:-http://10.90.1.125:8333}"   # 改用 HTTPS 時：https://s3-seaweedfs.nexai.org.com
BUCKET="${BUCKET:-velero}"
CRED_FILE="${CRED_FILE:-./credentials-velero}"

[ -f "$CRED_FILE" ] || { echo "找不到 $CRED_FILE，請先從 credentials-velero.example 複製一份並填值"; exit 1; }

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.14.2 \
  --image velero/velero:v1.18.2 \
  --bucket "$BUCKET" \
  --secret-file "$CRED_FILE" \
  --backup-location-config region=us-east-1,s3ForcePathStyle="true",s3Url="$S3_URL" \
  --use-volume-snapshots=true \
  --features=EnableCSI \
  --use-node-agent \
  --uploader-type kopia \
  --wait

# 參數說明：
#   --provider aws                SeaweedFS 講 S3 API，所以用 AWS plugin
#   --plugins ...aws:v1.14.2      AWS plugin 版本要跟 Velero 版本相容（見官方相容表）
#   --bucket velero               bucket 必須事先建立（velero 帳號沒有建 bucket 權限）
#   region=us-east-1              SeaweedFS 不在乎 region，但 AWS SDK 一定要有值
#   s3ForcePathStyle=true         用 http://host/bucket 而非 http://bucket.host（自建 S3 幾乎都要）
#   --features=EnableCSI          用 CSI VolumeSnapshot 備份 PV（Rook-Ceph 支援）
#   --use-node-agent              部署 node-agent DaemonSet：Data Mover / File System Backup 需要
#   --uploader-type kopia         Data Mover 用 kopia 上傳（去重 + 加密）

velero backup-location get
