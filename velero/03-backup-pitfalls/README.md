# 單元 5：Backup 的陷阱 — 有備份但不一定救得回來

> 這個單元的每一份備份，Velero 都回報 **`Completed`、0 errors、0 warnings**。
> 但它們全部救不回一個可用的應用。

## 目錄

1. [Lab 環境](#1-lab-環境)
2. [Backup Completed 與 Application 可用是兩件事](#2-backup-completed-與-application-可用是兩件事)
3. [情境 1：Resource 有了但 Data 不存在](#3-情境-1resource-有了但-data-不存在)
4. [情境 2：Secret 遺失](#4-情境-2secret-遺失)
5. [情境 3：ConfigMap 遺失](#5-情境-3configmap-遺失)
6. [情境 4：StorageClass 不存在](#6-情境-4storageclass-不存在)
7. [情境 5：快照拍到還沒寫進磁碟的資料（實測意外發現）](#7-情境-5快照拍到還沒寫進磁碟的資料實測意外發現)
8. [Namespace / Resource Dependency](#8-namespace--resource-dependency)
9. [Restore 後 Pod Running 但 Application 仍然不能使用](#9-restore-後-pod-running-但-application-仍然不能使用)
10. [總整理：症狀 → 原因對照表](#10-總整理症狀--原因對照表)
11. [練習](#11-練習)

---

## 1. Lab 環境

```text
05-backup-pitfalls/
├── manifest/
│   ├── 00-namespace.yaml              dr-pitfall namespace
│   ├── 01-storageclass-legacy.yaml    「舊叢集才有」的 StorageClass（情境 4）
│   ├── 02-postgres-config.yaml        Secret（帳密）+ ConfigMap（init SQL）
│   ├── 03-postgres.yaml               PVC + PostgreSQL（同時依賴 PVC/Secret/ConfigMap）
│   └── 04-legacy-volume.yaml          使用 legacy SC 的 PVC + 寫檔的 Deployment
├── business-data.sql                  部署後才寫入的「業務資料」（3 筆訂單）
└── velero/
    ├── change-storage-class.yaml      情境 4 的解法
    └── backup-with-sync-hook.yaml     情境 5 的解法（Backup Hook）
```

刻意設計：一個 PostgreSQL 同時依賴 **PVC（資料）+ Secret（帳密）+
ConfigMap（初始化 SQL）**。少了任何一個，還原後的症狀都不一樣。

```bash
kubectl apply -f dr/05-backup-pitfalls/manifest/
kubectl -n dr-pitfall rollout status deploy/postgres
kubectl -n dr-pitfall exec -i deploy/postgres -- psql -U shop -d shop < dr/05-backup-pitfalls/business-data.sql
kubectl -n dr-pitfall exec deploy/postgres -- psql -U shop -d shop -c 'SELECT order_no, note FROM orders ORDER BY id;'
```

實測（2026-09-23）：

```text
  order_no  |      note
------------+-----------------
 SEED-0001  | initdb 種子資料      ← ConfigMap 裡的 init SQL 產生
 ORDER-1001 | 客戶 A 的訂單        ← 以下 3 筆只存在 PVC 裡
 ORDER-1002 | 客戶 B 的訂單
 ORDER-1003 | 客戶 C 的訂單
(4 rows)
```

接著建立 4 份「範圍不同」的備份：

```bash
velero backup create pitfall-full         --include-namespaces dr-pitfall --snapshot-move-data --wait
velero backup create pitfall-no-data      --include-namespaces dr-pitfall --snapshot-volumes=false --wait
velero backup create pitfall-no-secret    --include-namespaces dr-pitfall --exclude-resources secrets --snapshot-move-data --wait
velero backup create pitfall-no-configmap --include-namespaces dr-pitfall --exclude-resources configmaps --snapshot-move-data --wait
```

---

## 2. Backup Completed 與 Application 可用是兩件事

```text
$ velero backup get
NAME                   STATUS      ERRORS   WARNINGS   CREATED
pitfall-full           Completed   0        0          2026-09-23 16:33:16 +0800 CST
pitfall-no-configmap   Completed   0        0          2026-09-23 16:35:01 +0800 CST
pitfall-no-data        Completed   0        0          2026-09-23 16:34:02 +0800 CST
pitfall-no-secret      Completed   0        0          2026-09-23 16:34:04 +0800 CST
```

四份看起來一模一樣。**Velero 只負責「你要它備份的東西有沒有備份到」，
不會知道你的應用需要什麼。**「備份範圍對不對」只有應用負責人知道，
而唯一的驗證方法是還原。

以下每個情境都用 `--namespace-mappings` 還原到獨立的 namespace，不影響來源。

---

## 3. 情境 1：Resource 有了但 Data 不存在

```bash
velero restore create pitfall-restore-no-data --from-backup pitfall-no-data \
  --namespace-mappings dr-pitfall:dr-pitfall-nodata --wait
```

實測結果：

```text
$ velero restore get pitfall-restore-no-data
NAME                      BACKUP            STATUS      ERRORS   WARNINGS
pitfall-restore-no-data   pitfall-no-data   Completed   0        2

$ kubectl get pods,pvc -n dr-pitfall-nodata
pod/legacy-writer-765bdc58b-kkgqs   1/1     Running   0          22s
pod/postgres-5bf9b8b7cc-mqdnh       1/1     Running   0          21s
persistentvolumeclaim/legacy-data     Bound    pvc-d1d1462c-...   1Gi   RWO   rook-ceph-block-legacy
persistentvolumeclaim/postgres-data   Bound    pvc-7425e2f7-...   2Gi   RWO   rook-ceph-block

$ kubectl -n dr-pitfall-nodata exec deploy/postgres -- psql -U shop -d shop -c 'SELECT order_no, note FROM orders ORDER BY id;'
 order_no  |      note
-----------+-----------------
 SEED-0001 | initdb 種子資料
(1 row)
```

**這是全單元最危險的情境**，因為每一項表面檢查都通過：

| 檢查 | 結果 |
|---|---|
| Restore phase | ✅ Completed |
| Pod | ✅ Running 1/1 |
| PVC | ✅ Bound |
| 資料庫能連線、`orders` table 存在 | ✅ |
| 有資料 | ✅ 有一筆…… |
| **業務資料 ORDER-1001~1003** | ❌ **全部消失** |

發生了什麼事：

1. 備份沒有 Volume 資料 → 還原時 PVC 由 StorageClass 動態佈建了一顆**空磁碟**。
2. 官方 postgres image 看到空的資料目錄 → 執行 `initdb` → 執行
   `/docker-entrypoint-initdb.d/01-schema.sql`（來自 ConfigMap）。
3. 於是 table 被重新建立、種子資料被重新塞進去 → **看起來像是有資料的正常資料庫**。

`legacy-writer` 也一樣：檔案內容的時間戳記從 `08:33:01`（原始）變成
`08:36:07`（還原後重新寫的）。

**防範：** 驗證腳本要查「災難前才存在、不可能自動重生」的資料
（業務資料、時間戳記早於備份時間的紀錄），不是查 table 在不在。

---

## 4. 情境 2：Secret 遺失

```bash
velero restore create pitfall-restore-no-secret --from-backup pitfall-no-secret \
  --namespace-mappings dr-pitfall:dr-pitfall-nosecret --wait
```

```text
$ kubectl get pods -n dr-pitfall-nosecret
NAME                                READY   STATUS                       RESTARTS   AGE
legacy-writer-765bdc58b-kkgqs       1/1     Running                      0          74s
postgres-5bf9b8b7cc-mqdnh           0/1     CreateContainerConfigError   0          74s

$ kubectl -n dr-pitfall-nosecret get events --field-selector reason=Failed
postgres-5bf9b8b7cc-mqdnh   Error: secret "postgres-secret" not found
```

PVC 已經 Bound、資料也已經還原（Data Mover 完成），但容器根本啟動不了——
`envFrom.secretRef` 找不到 Secret。

**修復：只從完整備份補還原 Secret**（應用其他部分完全不動）：

```bash
velero restore create pitfall-restore-secret-only --from-backup pitfall-full \
  --include-resources secrets --namespace-mappings dr-pitfall:dr-pitfall-nosecret --wait
```

```text
$ kubectl -n dr-pitfall-nosecret get pods
postgres-5bf9b8b7cc-mqdnh   1/1     Running   0          96s      ← kubelet 自動重試成功，不用重建 Pod

$ kubectl -n dr-pitfall-nosecret exec deploy/postgres -- psql -U shop -d shop -c 'SELECT order_no FROM orders ORDER BY id;'
  order_no
------------
 SEED-0001
 ORDER-1001
 ORDER-1002
 ORDER-1003
(4 rows)                                                           ← 資料完整
```

**真實世界的變形：** 很多團隊為了「備份檔不要有密碼」刻意排除 Secret，
改用 External Secrets / Vault 管理——這是好做法，但**還原前 Vault 必須先可用，
而且 ExternalSecret 物件要在備份裡**。否則就是這個情境。

---

## 5. 情境 3：ConfigMap 遺失

```bash
velero restore create pitfall-restore-no-configmap --from-backup pitfall-no-configmap \
  --namespace-mappings dr-pitfall:dr-pitfall-nocm --wait
```

```text
$ kubectl get pods,cm -n dr-pitfall-nocm
pod/legacy-writer-765bdc58b-kkgqs   1/1     Running             0          98s
pod/postgres-5bf9b8b7cc-mqdnh       0/1     ContainerCreating   0          98s
configmap/kube-root-ca.crt   1      99s                           ← 只有 K8s 自動產生的那一個

$ kubectl -n dr-pitfall-nocm get events --field-selector reason=FailedMount
postgres-5bf9b8b7cc-mqdnh   MountVolume.SetUp failed for volume "init-sql" : configmap "postgres-init-sql" not found
```

跟 Secret 遺失的症狀**不同**：

| 缺什麼 | 用法 | 症狀 |
|---|---|---|
| Secret / ConfigMap | `env` / `envFrom` 引用 | `CreateContainerConfigError`（容器建立前就失敗） |
| Secret / ConfigMap | 當作 **volume** 掛載 | `ContainerCreating` 卡住 + `FailedMount` event |

有趣的是：這個 ConfigMap 只在「第一次 initdb」時有用，資料還原回來之後
其實根本用不到它——但 Pod spec 宣告了要掛載，kubelet 就會一直等。
**「應用執行時不需要」不代表「還原時可以不要」。**

---

## 6. 情境 4：StorageClass 不存在

真實情境：舊叢集的 SC 叫 `ceph-block-ssd`，新叢集改名為 `rook-ceph-block`，
備份裡的 PVC 還寫著舊名字。在同一座叢集重現：建立 `rook-ceph-block-legacy`
→ 備份（`pitfall-full`）→ 刪除 SC → 還原。

```bash
kubectl delete sc rook-ceph-block-legacy
# 已經 Bound 的 PVC 不受影響（PV 不依賴 SC 物件存在）
kubectl get pvc -n dr-pitfall legacy-data      # 仍是 Bound

velero restore create pitfall-restore-no-sc --from-backup pitfall-full \
  --namespace-mappings dr-pitfall:dr-pitfall-nosc --item-operation-timeout 3m
```

```text
$ kubectl get pods,pvc -n dr-pitfall-nosc
pod/legacy-writer-765bdc58b-kkgqs   0/1     Pending   0          58s
pod/postgres-5bf9b8b7cc-mqdnh       1/1     Running   0          58s
persistentvolumeclaim/legacy-data     Pending                          rook-ceph-block-legacy
persistentvolumeclaim/postgres-data   Bound     pvc-ff334f93-...   2Gi   rook-ceph-block

$ kubectl -n dr-pitfall-nosc describe pvc legacy-data
  Warning  ProvisioningFailed  persistentvolume-controller  storageclass.storage.k8s.io "rook-ceph-block-legacy" not found

$ velero restore describe pitfall-restore-no-sc
Phase:  PartiallyFailed
Errors:
  Velero:   error from restore item operation: error to expose snapshot: error to wait target PVC consumed,
            dr-pitfall-nosc/legacy-data: error to wait for PVC: error to get storage class
            rook-ceph-block-legacy: storageclasses.storage.k8s.io "rook-ceph-block-legacy" not found
Restore Item Operations:  1 of 2 completed successfully, 1 failed
```

> 沒加 `--item-operation-timeout` 的話，這個 Restore 會卡在
> `WaitingForPluginOperations` 最多 **4 小時**（預設值）才失敗。

**解法：Velero 的 change-storage-class 設定**
（[velero/change-storage-class.yaml](velero/change-storage-class.yaml)）：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: change-storage-class-config
  namespace: velero
  labels:
    velero.io/plugin-config: ""
    velero.io/change-storage-class: RestoreItemAction
data:
  rook-ceph-block-legacy: rook-ceph-block      # 舊名 → 新名
```

```bash
kubectl apply -f dr/05-backup-pitfalls/velero/change-storage-class.yaml
velero restore create pitfall-restore-sc-mapped --from-backup pitfall-full \
  --namespace-mappings dr-pitfall:dr-pitfall-scfixed --wait
kubectl delete -f dr/05-backup-pitfalls/velero/change-storage-class.yaml   # 全域設定，用完移除
```

```text
$ velero restore get pitfall-restore-sc-mapped
NAME                        BACKUP         STATUS      ERRORS   WARNINGS
pitfall-restore-sc-mapped   pitfall-full   Completed   0        2

$ kubectl get pvc -n dr-pitfall-scfixed
legacy-data     Bound    pvc-c4f10124-...   1Gi   RWO   rook-ceph-block     ← 已被改寫成新 SC
postgres-data   Bound    pvc-418d199e-...   2Gi   RWO   rook-ceph-block
```

⚠️ 這個 ConfigMap 對**之後所有 Restore** 都生效，屬於全域設定，應納入
版本控管，不要留一份沒人記得的在叢集裡。

但是——`legacy-data` 裡的檔案呢？這就帶出了下一個情境。

---

## 7. 情境 5：快照拍到還沒寫進磁碟的資料（實測意外發現）

上一個情境還原後，檢查 `legacy.txt`：

```text
$ kubectl -n dr-pitfall-scfixed exec deploy/legacy-writer -- ls -la /data
-rw-r--r--    1 root     root             0 Sep 23 08:33 legacy.txt      ← 0 bytes！
$ kubectl -n dr-pitfall exec deploy/legacy-writer -- ls -la /data            （來源）
-rw-r--r--    1 root     root            56 Sep 23 08:33 legacy.txt
```

檔案**存在**，但內容是**空的**。這不是這個單元原本設計的情境，是實測時
踩到的真實問題。時間軸：

```text
08:33:01  legacy-writer 寫入 legacy.txt（56 bytes）→ 資料進入節點的 page cache
08:33:16  velero backup create pitfall-full → 幾秒後拍 CSI 快照
          ├ ext4 journal 每 5 秒提交 → 「檔案存在」這件事已經落盤
          └ 檔案內容（delayed allocation）預設最多 30 秒才寫回 → 快照拍到 0 bytes
```

**CSI Snapshot 拍的是區塊裝置，不是應用程式的記憶體。** 這叫做
**crash-consistent**（跟突然拔電一樣的狀態），不是 **application-consistent**。

為什麼 PostgreSQL 的資料沒事？因為資料庫每次 `COMMIT` 都會 `fsync`，
保證寫進磁碟才回應成功。一般應用程式寫檔通常不會。

### A/B 驗證：沒有 hook vs. 有 sync hook

為了確認原因，做了一次對照實驗——寫入檔案後**立刻**備份：

```bash
# A：沒有 hook
kubectl -n dr-pitfall exec deploy/postgres -- sh -c 'echo "FLUSH-TEST-NOHOOK $(date)" > /var/lib/postgresql/data/flush-test.txt'
velero backup create pitfall-no-hook --include-namespaces dr-pitfall --snapshot-move-data

# B：有 pre-backup hook 先執行 sync
kubectl -n dr-pitfall exec deploy/postgres -- sh -c 'echo "FLUSH-TEST-HOOK $(date)" > /var/lib/postgresql/data/flush-test.txt'
kubectl apply -f dr/05-backup-pitfalls/velero/backup-with-sync-hook.yaml
```

還原後比較：

```text
== no-hook
-rw-r--r-- 1 root root 0 Sep 23 08:43 /var/lib/postgresql/data/flush-test.txt
== with-hook
-rw-r--r-- 1 root root 48 Sep 23 08:44 /var/lib/postgresql/data/flush-test.txt
FLUSH-TEST-HOOK Wed Sep 23 08:44:33 AM UTC 2026
```

`velero backup describe pitfall-with-hook` 顯示 `HooksAttempted: 2, HooksFailed: 0`。

Hook 的寫法（[velero/backup-with-sync-hook.yaml](velero/backup-with-sync-hook.yaml)）：

```yaml
spec:
  hooks:
    resources:
      - name: flush-page-cache
        includedNamespaces: ["dr-pitfall"]
        labelSelector:
          matchExpressions:
            - { key: app, operator: In, values: ["postgres", "legacy-writer"] }
        pre:
          - exec:
              command: ["/bin/sh", "-c", "sync && echo synced"]
              onError: Fail
              timeout: 30s
```

也可以直接寫在 Pod template 的 annotation 上（不用每份 Backup 都寫一次）：

```yaml
metadata:
  annotations:
    pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "sync"]'
    pre.hook.backup.velero.io/timeout: 30s
```

一致性等級（由弱到強）：

| 做法 | 一致性 | 適用 |
|---|---|---|
| 什麼都不做 | crash-consistent | 本身會 fsync 的資料庫（勉強可接受） |
| `sync` hook | 已寫入的資料都落盤 | 一般寫檔的應用 |
| `fsfreeze --freeze` / `--unfreeze`（pre/post hook） | 快照期間檔案系統凍結 | 需要嚴格時間點一致 |
| 資料庫原生：`pg_dump`、`CHECKPOINT`、MySQL `FLUSH TABLES WITH READ LOCK` | application-consistent | 正式環境資料庫 |

---

## 8. Namespace / Resource Dependency

Velero 以 namespace 為邊界備份，但應用的依賴常常**跨出**那個邊界：

| 依賴 | 例子（本課程 7 個產品） | 只還原單一 namespace 會怎樣 |
|---|---|---|
| 跨 namespace 連線 | cloudbeaver 連 flarum/planka/peertube 的資料庫 | cloudbeaver 回來了，但對面的 DB 不在 |
| 共用 Gateway | 所有 HTTPRoute `parentRefs: dev-gateway`（`default` namespace） | HTTPRoute 還原成功但 `Accepted=False`，外面連不到 |
| Namespace label + NetworkPolicy | cloudbeaver 的 `namespaceSelector` 靠 namespace label 放行 | label 沒回來 → 流量被擋；而且 Cilium 在 Pod 建立時計算身分，**label 要比 Pod 先存在** |
| Cluster-scoped 資源 | StorageClass、ClusterRole、CRD、IngressClass | 預設不會跟著 namespace 備份（`includeClusterResources` 為 null 時只帶 PV/CRD） |
| CRD 與 Operator | Rook 的 CephCluster、cert-manager 的 Certificate | CRD 在但 Operator 沒跑 → 物件沒有人處理 |
| TLS 憑證 Secret | `default/gateway-tls` | 在別的 namespace，不會跟著應用備份 |

**防範：** 為每個應用寫一張「依賴清單」，還原演練時照清單逐項確認；
或把有依賴關係的 namespace 放進**同一份**備份，一起還原。

---

## 9. Restore 後 Pod Running 但 Application 仍然不能使用

本課程 7 個產品開發過程中實際遇過、還原後會重現的情境：

| 情境 | 發生在 | 症狀 | 原因 |
|---|---|---|---|
| App 的「已安裝」標記跟 DB 不同步 | flarum | Pod Running，但 `Table 'appdb.settings' doesn't exist` | 標記檔在 `flarum-assets` PVC、資料在 mysql PVC；只還原其中一個，或兩者時間點不同 |
| 密碼被改過 | planka / mysql | `password authentication failed` | 官方 image 只在首次 initdb 套用密碼；Secret 是新密碼、DB 裡是舊密碼（或反過來） |
| 一次性管理員密碼 | peertube | 無法登入 | root 密碼只在首次啟動印在 log，還原後不會再印 |
| 外部依賴 | onlyoffice | CPU 飆高、功能異常 | NetworkPolicy 擋住對外連線，背景程式無限重試 |
| Probe 太嚴格 | mysql | 還原後大量資料要 recovery，liveness 在 recovery 中殺掉容器 | `initialDelaySeconds` 小於冷啟動/recovery 時間 |
| DNS / Hostname | 全部 | 瀏覽器連不到 | HTTPRoute 的 hostname 與新叢集的 DNS / Gateway IP 不一致 |
| 資料不一致 | 任何 App + DB 分開存放 | 檔案有、DB 紀錄沒有（或反過來） | 兩個 PVC 快照時間點不同 |

所以單元 4 的判斷標準最後一層是「**應用功能正常**」：登入、讀一筆舊資料、
寫一筆新資料、從外部網址連得到。

---

## 10. 總整理：症狀 → 原因對照表

| 還原後症狀 | 第一個要懷疑的 | 怎麼確認 |
|---|---|---|
| Pod Running、資料是空的或只有預設資料 | 沒備份 Volume 資料 / `restorePVs: false` | `velero backup describe --details` 的 Backup Volumes |
| `CreateContainerConfigError` | Secret/ConfigMap（env 引用）不存在 | `kubectl describe pod` → Events |
| `ContainerCreating` + `FailedMount` | Secret/ConfigMap（volume 掛載）或 PVC 不存在 | Events |
| PVC `Pending` + `ProvisioningFailed` | StorageClass 不存在 | `kubectl get sc` |
| Restore 卡在 `WaitingForPluginOperations` | Data Mover 下載中，或 PVC 永遠無法 Bound | `kubectl -n velero get datadownloads` |
| Restore `PartiallyFailed` | 看 `velero restore describe` 的 Errors | `velero restore logs` |
| 檔案在但 0 bytes | 快照前資料未落盤 | 加 pre-backup hook |
| HTTPRoute 沒作用 | Gateway 不存在 / 不在同一份還原 | `kubectl get httproute -o yaml` 看 `status.parents` |
| 連不到其他 namespace 的服務 | NetworkPolicy / namespace label | `kubectl get ns --show-labels` |

---

## 11. 練習

1. 對 `dr-pitfall` 做一份 `--exclude-resources persistentvolumeclaims` 的備份並還原。
   跟情境 1 的症狀一樣嗎？為什麼？
2. 情境 4 的 change-storage-class ConfigMap 如果忘記刪除，一個月後另一位同事
   還原一份跟這個 lab 無關的備份，會受影響嗎？（提示：看 `data` 的 key）
3. 改寫 `04-legacy-volume.yaml`，用 Pod annotation 的方式加上 `sync` hook，
   重做情境 5 的 A/B 實驗。
4. 替 `dr-pitfall` 寫一支像 `script/check-data.sh` 的驗證腳本，必須能偵測出
   情境 1（提示：檢查 `ORDER-1001` 是否存在，而不是 `count(*) > 0`）。

**清理（講師 / 課後）：**

```bash
kubectl delete ns dr-pitfall-nodata dr-pitfall-nosecret dr-pitfall-nocm dr-pitfall-nosc dr-pitfall-scfixed --ignore-not-found
kubectl delete ns dr-pitfall && kubectl delete sc rook-ceph-block-legacy --ignore-not-found
for b in pitfall-full pitfall-no-data pitfall-no-secret pitfall-no-configmap pitfall-no-hook pitfall-with-hook; do
  velero backup delete "$b" --confirm
done
```
