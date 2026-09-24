# 單元 4：第一次 Restore — 把 Application 救回來

> 還原成功的定義不是「Pod Running」，而是「**災難前寫進去的那筆資料，現在
> 查得到**」。

## 目錄

1. [兩種還原方式：原地 vs. 還原到新 namespace](#1-兩種還原方式原地-vs-還原到新-namespace)
2. [建立 Restore（UI / CLI / yaml）](#2-建立-restoreui--cli--yaml)
3. [還原指定 Namespace / Application](#3-還原指定-namespace--application)
4. [RestorePVs 的用途](#4-restorepvs-的用途)
5. [Restore 過程中 Kubernetes 資源如何重新建立](#5-restore-過程中-kubernetes-資源如何重新建立)
6. [驗證 Pod / Service / PVC](#6-驗證-pod--service--pvc)
7. [驗證資料庫資料](#7-驗證資料庫資料)
8. [驗證 CephFS / Block Storage 資料](#8-驗證-cephfs--block-storage-資料)
9. [真的還原成功的判斷標準](#9-真的還原成功的判斷標準)
10. [練習](#10-練習)

```text
04-first-restore/velero/
├── restore-dr-demo.yaml             原地還原（dr-demo 被刪之後）
├── restore-to-new-namespace.yaml    還原到 dr-demo-restore（本課實測使用）
└── restore-partial.yaml             只還原某一種資源（例如 Secret）
```

---

## 1. 兩種還原方式：原地 vs. 還原到新 namespace

| | 原地還原 | 還原到新 namespace（namespaceMapping） |
|---|---|---|
| 前提 | 原 namespace 已不存在（或資源已刪除） | 原 namespace 可以還活著 |
| 風險 | 如果原應用其實還在，同名資源會被**跳過**（預設不覆蓋），容易誤判 | 幾乎沒有：新的 PV、新的 namespace，完全不碰原應用 |
| 用途 | 真正的災難復原 | **還原演練**、比對資料、救回單筆誤刪資料 |
| 本課程 | 講師 demo：`./script/app-disaster.sh` → 還原 | ✅ 實測（2026-09-23）|

> 建議上課順序：先用「還原到新 namespace」讓每位學員都能安全地練習，
> 最後由講師 demo 一次「刪掉 dr-demo → 原地還原」的完整災難流程。

---

## 2. 建立 Restore（UI / CLI / yaml）

**Velero UI：** 在備份清單中選 `dr-demo-backup-01` → Restore。精靈步驟
對應 Restore CR 欄位：

| 精靈步驟 | 本課程填什麼 | Restore CR 欄位 |
|---|---|---|
| 來源備份 | `dr-course-backup-01` | `spec.backupName` |
| Namespaces | `dr-demo` | `spec.includedNamespaces` |
| Namespace Mapping | `dr-demo` → `dr-demo-restore` | `spec.namespaceMapping` |
| Resources | 不填（全部） | `spec.includedResources` / `excludedResources` |
| Restore PVs | **開啟** | `spec.restorePVs: true` |
| 已存在資源的處理 | none | `spec.existingResourcePolicy` |

送出後一樣先確認 CR：`kubectl -n velero get restore <name> -o yaml`。

**CLI（本課實測）：**

```bash
velero restore create dr-course-restore-01 \
  --from-backup dr-course-backup-01 \
  --namespace-mappings dr-demo:dr-demo-restore \
  --restore-volumes=true \
  --wait
```

**yaml：** [velero/restore-to-new-namespace.yaml](velero/restore-to-new-namespace.yaml)

---

## 3. 還原指定 Namespace / Application

一份備份可以只還原其中一部分：

```bash
# 備份裡有多個 namespace，只還原 dr-demo
velero restore create --from-backup daily-full-backup-20260923010055 --include-namespaces dr-demo

# 只還原某種資源（例如誤刪的 Secret）
velero restore create --from-backup dr-demo-backup-01 --include-resources secrets

# 只還原某個應用（前提：該應用的所有資源都有一致的 label，見單元 3 第 5 節）
velero restore create --from-backup dr-demo-backup-01 --selector app.kubernetes.io/instance=postgres
```

> 💡 從每日全叢集備份（單元 9）只救回一個 namespace，是最常見的實戰用法：
> 備份做大範圍，還原做小範圍。

---

## 4. RestorePVs 的用途

| `restorePVs` | PVC 物件 | PV 資料 | 結果 |
|---|---|---|---|
| `true` | 還原 | Data Mover 從 S3 下載到**新的** PV | 資料回來了 ✅ |
| `false` | 還原 | 不還原；PVC 會由 StorageClass 動態佈建一顆**空的**新磁碟 | Pod 會 Running，但資料是空的 ⚠️ |

`restorePVs: false` 適合什麼時候用？

- 只想還原設定，資料由應用自己的機制（例如資料庫 replication）補回。
- 資料量很大，先把應用骨架拉起來，資料另外處理。

單元 5 情境 1 會示範「資料沒回來、但一切看起來都正常」有多危險。

---

## 5. Restore 過程中 Kubernetes 資源如何重新建立

Velero 還原**不是**把 etcd 倒回去，而是**透過 API Server 逐一 `create`**
每個資源——所以 admission webhook、ResourceQuota、LimitRange、
NetworkPolicy 等規則全部都會生效。還原順序是固定的（先被依賴的先建）：

```text
1. CustomResourceDefinitions
2. Namespaces
3. StorageClasses（若備份內有）
4. VolumeSnapshotClass / VolumeSnapshotContents / VolumeSnapshots
5. DataUploads → PersistentVolumes → PersistentVolumeClaims   ← Data Mover 在這裡把資料下載回來
6. ServiceAccounts → Secrets → ConfigMaps → LimitRanges
7. Pods → ReplicaSets → Endpoints → Services
8. 其餘資源（Deployment、HTTPRoute…，依字母順序）
```

實測 `velero restore describe dr-course-restore-01 --details`（節錄）：

```text
Phase:                       Completed
Total items to be restored:  19
Items restored:              19

Warnings:
  Cluster:  could not restore, CustomResourceDefinition:ciliumendpoints.cilium.io already exists.
  Namespaces:
    dr-demo-restore:  could not restore, ConfigMap:kube-root-ca.crt already exists.

Namespace mappings:  dr-demo=dr-demo-restore
Restore PVs:  true

Restore Item Operations:
  Operation for persistentvolumeclaims dr-demo-restore/postgres-data:
    Restore Item Action Plugin:  velero.io/csi-pvc-restorer
    Phase:                       Completed
    Progress:                    47876961 of 47876961 complete (Bytes)
  Operation for persistentvolumeclaims dr-demo-restore/shared-data:
    Phase:                       Completed
    Progress:                    45 of 45 complete (Bytes)
```

這兩個 warning 是**正常的**：

- `ciliumendpoints.cilium.io` CRD 叢集上本來就有。
- `kube-root-ca.crt` 是 namespace 建立時 K8s 自動產生的，Velero 發現已存在就跳過。

還原後觀察到的細節（都是教學重點）：

| 觀察 | 原因 |
|---|---|
| PV 名稱變了：`pvc-85e4...` → `pvc-2707...` | Data Mover 建立**新的** PV 再把資料寫進去 |
| Service ClusterIP 變了：`172.31.212.253` → `172.31.248.152` | ClusterIP 由叢集重新分配 → 應用一律用 DNS 連線 |
| 備份裡有 3 個 postgres Pod，還原後只有 1 個 | Velero **不還原**已結束（Completed/Failed）的 Pod |
| 還原後的 Pod 名稱跟原本一樣 `postgres-54bfb985f9-grjh5` | Velero 會還原 Pod 物件本身，之後由 ReplicaSet 接手管理 |
| `cephfs-test-1/2` 沒有被還原 | 備份當下這兩個裸 Pod 已經不存在 → 備份裡本來就沒有 |

---

## 6. 驗證 Pod / Service / PVC

```bash
$ kubectl get pods,svc,pvc -n dr-demo-restore
NAME                            READY   STATUS    RESTARTS   AGE
pod/postgres-54bfb985f9-grjh5   1/1     Running   0          76s

NAME               TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
service/postgres   ClusterIP   172.31.248.152   <none>        5432/TCP   70s

NAME                                  STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/postgres-data   Bound    pvc-2707f55e-4a11-4091-840d-33ca3a5bcd08   10Gi       RWO            rook-ceph-block
persistentvolumeclaim/shared-data     Bound    pvc-2cc8ab96-714d-49e6-a190-22dd0c51da22   5Gi        RWX            rook-cephfs
```

資源層面的檢查項目：

- Pod `Running` 且 `READY 1/1`，`RESTARTS` 沒有持續增加
- Service 有 Endpoints：`kubectl -n dr-demo-restore get endpointslices`
- PVC 全部 `Bound`，StorageClass 正確
- Secret 存在：`kubectl -n dr-demo-restore get secret postgres-secret`

**到這裡為止，都只證明了「骨架」回來了。**

---

## 7. 驗證資料庫資料

```bash
$ kubectl -n dr-demo-restore exec deploy/postgres -- psql -U drtest -d drdemo -c "SELECT * FROM disaster_test;"
 id |    test_key    |            test_value             |         created_at
----+----------------+-----------------------------------+----------------------------
  1 | DR-TEST-DB-001 | Kubernetes Disaster Recovery Test | 2026-09-09 03:36:10.139213
(1 row)
```

注意 `created_at` 是 **2026-09-09**——比這次備份（09-23）早兩週，證明這是
「災難前就存在的資料被救回來」，不是還原後重新產生的。

---

## 8. 驗證 CephFS / Block Storage 資料

| 儲存 | 驗證方式 | 證明了什麼 |
|---|---|---|
| Block（RBD）`postgres-data` | 上面第 7 節的 SQL 查詢 | RBD 快照 → S3 → 新 RBD image 完整無誤 |
| CephFS `shared-data` | 用**只讀**的臨時 Pod 讀 `dr-test.txt` | CephFS 快照 → S3 → 新 subvolume 完整無誤 |

為什麼 CephFS 要用「只讀的臨時 Pod」？因為 `cephfs-test-1` 每次啟動都會
**重寫** `dr-test.txt`——如果用它來驗證，就算資料沒還原，它也會自己寫一份
出來，讓你誤以為成功。**驗證工具本身不能產生被驗證的資料。**

```bash
$ kubectl -n dr-demo-restore logs cephfs-verify
total 1
-rw-r--r--    1 root     root            45 Sep 19 03:40 dr-test.txt
DR-TEST-FS-001
CephFS Disaster Recovery Test
```

檔案時間 `Sep 19 03:40` 是原始寫入時間，大小 45 bytes 跟 DataUpload 紀錄完全一致。

以上三項全部包裝在 [`script/check-data.sh`](../script/check-data.sh)：

```bash
$ ./dr/script/check-data.sh dr-demo-restore
== 1. Kubernetes 資源（namespace: dr-demo-restore）
  [PASS] PVC postgres-data Bound
  [PASS] PVC shared-data Bound
== 2. PostgreSQL 資料
  [PASS] disaster_test 查得到 DR-TEST-DB-001
== 3. CephFS 資料
  [PASS] dr-test.txt 含 DR-TEST-FS-001

結果：還原驗證通過 ✅
```

腳本有結束碼（全過 0、任一失敗 1），單元 9 的自動化 Restore Test 直接重用它。

---

## 9. 真的還原成功的判斷標準

```text
 Restore Completed          ← Velero 說它做完了
   └ Pod Running            ← K8s 說容器起來了
       └ PVC Bound          ← 儲存說磁碟接上了
           └ 資料查得到     ← 只有這一層證明「救回來了」 ✅
               └ 應用功能正常（登入、讀寫、對外連線）← 業務方確認
```

每往下一層，需要的驗證知識就越接近「應用本身」。這也是為什麼還原演練
**一定要有應用負責人參與**——只有他們知道「哪一筆資料在，才代表真的沒事」。

---

## 10. 練習

1. 用 Velero UI，把 `dr-course-backup-01` 還原到 `dr-demo-<你的名字>`，
   跑 `./dr/script/check-data.sh dr-demo-<你的名字>` 確認 3 項全 PASS。做完刪掉自己的 namespace。
2. 在 `dr-demo` 新增一筆 `DR-TEST-DB-002`（`./dr/script/write-postgres.sh dr-demo DR-TEST-DB-002`），
   **不要重新備份**，再還原一次到新 namespace。查得到 002 嗎？這在 RPO 上代表什麼？
3. （講師 demo）`./dr/script/app-disaster.sh` 刪除 dr-demo → 用
   [velero/restore-dr-demo.yaml](velero/restore-dr-demo.yaml) 原地還原 →
   `./dr/script/check-data.sh`。記錄從刪除到驗證通過花了幾分鐘——這就是這個應用的實測 RTO。
4. 在 dr-demo 還活著的時候，**不用** namespaceMapping 直接還原同一份備份，
   看 `velero restore describe` 的 Warnings 有幾個、資料有沒有被覆蓋。為什麼？
