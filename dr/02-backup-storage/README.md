# 單元 2：建立外部 Backup Storage

> 備份的第一條規則：**備份不能跟被備份的東西一起死掉。**

## 目錄

1. [為什麼 Backup Storage 不應該只存在 Kubernetes 裡](#1-為什麼-backup-storage-不應該只存在-kubernetes-裡)
2. [建立 S3 Compatible Object Storage](#2-建立-s3-compatible-object-storage)
3. [設定 Velero Credentials](#3-設定-velero-credentials)
4. [建立 Backup Storage Location](#4-建立-backup-storage-location)
5. [驗證 Velero → Object Storage 的連線](#5-驗證-velero--object-storage-的連線)
6. [確認備份資料確實寫入叢集外部](#6-確認備份資料確實寫入叢集外部)
7. [常見錯誤](#7-常見錯誤)
8. [練習](#8-練習)

```text
02-backup-storage/velero/
├── credentials-velero.example   Velero S3 認證檔範本（真正的檔案不要進版控）
├── install-velero.sh            這座叢集 Velero 的實際安裝參數（單元 8 重建時重用）
├── bsl-default.yaml             BackupStorageLocation（與線上一致，HTTP）
├── bsl-https.yaml               改走 HTTPS + 自簽 CA 的版本
└── s3-check-pod.yaml            不經過 Velero、直接 ls bucket 的驗證 Pod
```

---

## 1. 為什麼 Backup Storage 不應該只存在 Kubernetes 裡

一個很常見、看起來很合理的設計：「在叢集裡用 Rook 開一個 CephObjectStore
（RGW）或部署一個 MinIO，給 Velero 當備份目的地。」

這座叢集其實真的有 `rook-ceph-retain-bucket` 這個 StorageClass（可以用
ObjectBucketClaim 開 Ceph RGW bucket），早期測試備份 `test-ceph-rgw-final`
就是這樣做的。問題是：

| 災難 | 備份在叢集內的 Ceph RGW / MinIO | 備份在叢集外的 SeaweedFS |
|---|---|---|
| 誤刪 namespace | ✅ 救得回來 | ✅ |
| Ceph 故障（OSD 大量損壞） | ❌ 備份跟資料一起壞 | ✅ |
| etcd 損壞、API Server 起不來 | ⚠️ 資料可能還在，但 MinIO/RGW 也要靠叢集才能跑 | ✅ |
| 整座叢集重灌 / 機房失火 | ❌ | ✅（若備份機在另一個機房更好） |
| 勒索軟體拿到 cluster-admin | ❌ 一個 `kubectl delete` 就全部清掉 | ⚠️ 視 S3 帳號權限而定 |

原則：

1. **不同的故障域**：不同機器、不同磁碟，最好不同機房（3-2-1：3 份資料、
   2 種媒介、1 份異地）。
2. **不同的權限域**：叢集的 cluster-admin 不應該能刪掉備份。Velero 用的
   S3 帳號只給它需要的權限，bucket 由另一個管理者帳號建立。
3. **不依賴被保護的系統**：Backup Storage 自己要能獨立開機、獨立登入、
   獨立驗證。

---

## 2. 建立 S3 Compatible Object Storage

本課程使用 **SeaweedFS**（`weed mini` 單機全功能模式）跑在叢集外的一台
Ubuntu 26.04 備份機 `10.90.1.125`，資料放在獨立的第二顆硬碟 `/dev/sdb1`。

完整安裝步驟（硬碟分割、systemd、S3 帳號、HTTPS、防火牆）在
**[../seaweedfs/README.md](../seaweedfs/README.md)**，這裡只列關鍵檢查點：

| 步驟 | 檢查點 | 為什麼重要 |
|---|---|---|
| 獨立硬碟掛在 `/backup` | `df -h /backup` 顯示 `/dev/sdb1` | 確認資料沒寫到系統碟 `/dev/sda` |
| systemd `RequiresMountsFor=/backup/seaweedfs` | 硬碟沒掛上時服務不會啟動 | 避免「硬碟沒掛，資料默默寫進根目錄」 |
| 兩組 S3 帳號 | `seaweed-admin`（管理）、`velero-backup`（只能存取 `velero` bucket） | 權限分離：Velero 不能建立/刪除 bucket |
| 管理者先建立 bucket | `aws s3 mb s3://velero` 以 admin 身分執行 | velero 帳號執行 `mb` 會得到 `AccessDenied`（實測）|
| reboot 測試 | 重開機後 `systemctl is-active seaweedfs` = active | 備份機自己也要能在災難後自動恢復 |

> 本課程另外還有一個 `etcd-backups` bucket（單元 6 使用）。建議 etcd 備份用
> **另一組** S3 帳號，只給 `etcd-backups` 的權限。

---

## 3. 設定 Velero Credentials

Velero 的 AWS plugin 使用標準 AWS credentials 檔格式：

```bash
cd dr/02-backup-storage/velero
cp credentials-velero.example credentials-velero
vi credentials-velero          # 填入 velero-backup 的 secretKey
chmod 600 credentials-velero
```

```ini
[default]
aws_access_key_id=velero-backup
aws_secret_access_key=<SeaweedFS s3-config.json 裡 velero 的 secretKey>
```

`velero install --secret-file` 會把它存成 `velero` namespace 裡的 Secret
`cloud-credentials`（key 名稱是 `cloud`），Velero server 與 node-agent 都會
掛載它。線上實際狀態：

```bash
$ kubectl -n velero get secret
NAME                      TYPE     DATA   AGE
cloud-credentials         Opaque   1      18d
velero-repo-credentials   Opaque   1      18d
```

- `cloud-credentials`：連 S3 的帳密。
- `velero-repo-credentials`：**kopia repository 的加密密碼**，Velero 第一次
  使用 Data Mover 時自動產生。PV 資料在 S3 上是用它加密的。
  ⚠️ **單元 8 的關鍵**：新叢集如果產生了**不同**的 repo 密碼，就讀不出舊叢集
  上傳的 PV 資料。這個 Secret 要跟 S3 帳密一起，另外保存在叢集外。

**更換 credentials（例如輪替密碼）：**

```bash
kubectl -n velero create secret generic cloud-credentials \
  --from-file=cloud=./credentials-velero --dry-run=client -o yaml | kubectl apply -f -
kubectl -n velero rollout restart deploy/velero
kubectl -n velero rollout restart ds/node-agent
```

---

## 4. 建立 Backup Storage Location

BSL 就是「Velero 要把備份寫到哪裡」的設定物件。第一次安裝時 `velero install`
會幫你建立 `default`。這座叢集的安裝參數整理在
[velero/install-velero.sh](velero/install-velero.sh)：

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.14.2 \
  --bucket velero \
  --secret-file ./credentials-velero \
  --backup-location-config region=us-east-1,s3ForcePathStyle="true",s3Url=http://10.90.1.125:8333 \
  --features=EnableCSI \
  --use-node-agent \
  --uploader-type kopia \
  --wait
```

產生的 BSL（[velero/bsl-default.yaml](velero/bsl-default.yaml)）：

```yaml
spec:
  provider: aws
  default: true
  objectStorage:
    bucket: velero
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: http://10.90.1.125:8333
```

### HTTP 還是 HTTPS？

線上目前是 **HTTP 直連 8333**。`seaweedfs/README.md` 後半段已經建好
Nginx + TLS（`https://s3-seaweedfs.nexai.org.com`）和防火牆規則
（`ufw deny 8333/tcp`）——**如果先開防火牆、BSL 還沒切換，Velero 會立刻變成
`Unavailable`，所有備份失敗**。正確順序：

1. `kubectl apply -f velero/bsl-https.yaml`（填入 `caCert`）
2. `velero backup-location get` 確認仍是 `Available`
3. 跑一次小備份確認能寫入
4. 最後才在備份機上 `ufw deny 8333/tcp`

---

## 5. 驗證 Velero → Object Storage 的連線

```bash
$ velero backup-location get
NAME      PROVIDER   BUCKET/PREFIX   PHASE       LAST VALIDATED                  ACCESS MODE   DEFAULT
default   aws        velero          Available   2026-09-23 16:54:49 +0800 CST   ReadWrite     true
```

```bash
$ kubectl -n velero get bsl default -o jsonpath='{.status}' | python3 -m json.tool
{
    "lastSyncedTime": "2026-09-23T08:11:00Z",
    "lastValidationTime": "2026-09-23T08:10:18Z",
    "phase": "Available"
}
```

- `PHASE=Available`：Velero 每分鐘驗證一次能否存取 bucket。
- `lastSyncedTime`：Velero 會定期把 bucket 裡的備份清單**同步回叢集**
  （所以新叢集接上同一個 bucket，就會自動看到舊備份）。
- `Unavailable` 時看原因：

```bash
kubectl -n velero logs deploy/velero | grep -i "backup storage location" | tail
```

---

## 6. 確認備份資料確實寫入叢集外部

`Available` 只代表「連得上」。要確認「真的寫出去了」，**不透過 Velero**，
直接去 S3 看。用 [velero/s3-check-pod.yaml](velero/s3-check-pod.yaml)
（使用 Velero 自己的 credentials，只做 `ls`）：

```bash
kubectl apply -f velero/s3-check-pod.yaml
kubectl -n velero logs -f s3-check
kubectl -n velero delete pod s3-check
```

實測輸出（2026-09-23，單元 3 的 `dr-course-backup-01` 完成後）：

```text
== bucket 最上層
                           PRE backups/
                           PRE kopia/
                           PRE restores/
== backups/dr-course-backup-01
2026-09-23 08:29:30        449 dr-course-backup-01-itemoperations.json.gz
2026-09-23 08:28:06      12381 dr-course-backup-01-logs.gz
2026-09-23 08:28:06         29 dr-course-backup-01-podvolumebackups.json.gz
2026-09-23 08:28:06        392 dr-course-backup-01-resource-list.json.gz
2026-09-23 08:28:06         49 dr-course-backup-01-results.gz
2026-09-23 08:29:30        636 dr-course-backup-01-volumeinfo.json.gz
2026-09-23 08:28:06         29 dr-course-backup-01-volumesnapshots.json.gz
2026-09-23 08:29:30      15508 dr-course-backup-01.tar.gz        ← 所有 K8s 資源的 JSON
2026-09-23 08:29:30       3681 velero-backup.json                ← Backup CR 本身
== kopia
                           PRE cloudbeaver/
                           PRE dr-demo/                          ← dr-demo 的 PV 資料
                           PRE dr-pitfall/
                           PRE filebrowser/
                           ...
== kopia/dr-demo size
Total Objects: 365
   Total Size: 37285283                                          ← 約 37MB，kopia 壓縮去重後
```

也可以在備份機上直接確認實體硬碟有在長：

```bash
# 在 10.90.1.125 上
df -h /backup
sudo du -sh /backup/seaweedfs
```

最後，確認備份內容能被「讀出來」（而不是只有檔案存在）：

```bash
velero backup download dr-course-backup-01 -o /tmp/dr-course-backup-01.tar.gz
tar tzf /tmp/dr-course-backup-01.tar.gz | head
# resources/persistentvolumeclaims/namespaces/dr-demo/postgres-data.json
# resources/secrets/namespaces/dr-demo/postgres-secret.json      ← Secret 是 base64，不是加密！
# resources/deployments.apps/namespaces/dr-demo/postgres.json
# ...
```

> ⚠️ 資安重點：備份 tar.gz 裡的 Secret 只是 base64。**能讀 bucket 的人就能讀
> 到所有 Secret**。這就是為什麼 bucket 權限要收緊、HTTPS 要開、備份機要擋防火牆。
> （PV 資料則由 kopia 用 `velero-repo-credentials` 加密。）

---

## 7. 常見錯誤

| 症狀 | 原因 | 解法 |
|---|---|---|
| BSL `Unavailable`，log 出現 `AccessDenied` | credentials 錯、或帳號沒有該 bucket 權限 | 用 `s3-check-pod.yaml` 同一組帳密測 `ls`，縮小範圍 |
| `NoSuchBucket` | bucket 沒事先建立（velero 帳號不能建） | 用 `seaweed-admin` 執行 `aws s3 mb s3://velero` |
| `SignatureDoesNotMatch` | 走 reverse proxy 時 Host 被改寫；或 `s3.externalUrl` 與 BSL `s3Url` 不一致 | Nginx `proxy_set_header Host $host`；兩邊 URL 完全一致 |
| `x509: certificate signed by unknown authority` | HTTPS 自簽憑證，Velero 不信任 | BSL `objectStorage.caCert` 填 Root CA 的 base64 |
| `dial tcp 10.90.1.125:8333: i/o timeout` | 防火牆擋住、或走 HTTPS 但 BSL 還是 8333 | 見第 4 節「HTTP 還是 HTTPS」的切換順序 |
| 忘記 `s3ForcePathStyle` | SDK 用 `velero.10.90.1.125` 這種 virtual-host 網址 | 自建 S3 一律加 `s3ForcePathStyle: "true"` |

---

## 8. 練習

1. 用 `velero-backup` 帳號嘗試 `aws s3 mb s3://test`，確認被拒絕。為什麼這是「好」的結果？
2. 把 `bsl-default.yaml` 複製成 `bsl-readonly.yaml`，名稱改成 `readonly`、
   `default: false`、加上 `accessMode: ReadOnly` 並 apply。
   用 `velero backup create x --storage-location readonly` 會發生什麼事？（做完記得刪除這個 BSL）
3. 在 bucket 裡找到單元 3 那份備份的 `resource-list.json.gz`，下載解壓，
   對照 `velero backup describe --details` 的 Resource List 是否一致。
