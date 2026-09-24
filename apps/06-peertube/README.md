# PeerTube

基於 ActivityPub 協定與 P2P 技術的去中心化影音分享平台（開源版 YouTube）。

## K8s 教育訓練用途

課程最後、最完整的整合範例：PostgreSQL（StatefulSet + PVC）+
Redis（Deployment + emptyDir）+ 應用程式本體，一次把前面學過的
概念串起來。

- **Redis 併入本產品，不是獨立共用服務**：跟 mysql（共用、跨
  namespace）、postgres（planka 專屬）一樣的判斷邏輯——Redis 是
  PeerTube 運作必要的內部元件（背景工作佇列），跟這個 namespace
  綁在一起最合理。
- **同樣是「資料庫類」服務，PVC 策略不同**：postgres 用
  StatefulSet + PVC（影片/使用者資料不能弄丟），redis 用
  Deployment + emptyDir（快取/佇列，重建 Pod 頂多背景工作重跑）。
- ⚠️ **PostgreSQL 需要先啟用 extension**：PeerTube 要求資料庫裝好
  `pg_trgm`、`unaccent` 這兩個 extension，見
  [03-postgres-initdb-configmap.yaml](manifest/03-postgres-initdb-configmap.yaml)——
  用 ConfigMap 掛一支初始化 SQL，示範 ConfigMap 除了放設定檔，也能
  放資料庫初始化腳本。
- ⚠️ **實測踩到的坑（redis/peertube 都中招）**：`redis` 和
  `peertube` 這兩個 image 的 entrypoint 都是先以 root 啟動、再切換
  成內部的非特權使用者，跟 mysql 一樣，`capabilities.drop: [ALL]`
  會讓使用者切換失敗、容器啟動不了。已經在 manifest 裡移除，
  只留 `allowPrivilegeEscalation: false`。
- **後面有反向代理（Gateway）時的協定/埠號設定**：
  `PEERTUBE_WEBSERVER_HTTPS`/`PEERTUBE_WEBSERVER_PORT` 填的是「使用者
  實際存取的網址」（https, 443），跟容器內部實際監聽的 9000 完全是
  兩回事；`PEERTUBE_TRUST_PROXY` 也要明確納入叢集 Pod 網段
  （`uniquelocal`），不然 PeerTube 記錄到的來源 IP、判斷是否為
  https 都會不準。
- **管理員密碼／Email 用 `PT_INITIAL_ROOT_PASSWORD`／`PEERTUBE_ADMIN_EMAIL`
  固定指定**（見 [07-peertube-secret.yaml](manifest/07-peertube-secret.yaml)），
  但這兩個變數**只有在資料庫完全沒有使用者（全新安裝）時才會生效**
  ——帳號名稱本身是 PeerTube 寫死的 `root`，沒有變數可以改。若資料庫
  已經有帳號，改這兩個值不會回頭改到既有帳號，密碼要另外用內建的
  reset-password 腳本重設，見下方「帳號密碼一覽」與「驗證」段落。
- 沿用 onlyoffice 的排程做法：三個 Pod 都用 `nodeSelector` +
  `toleration` 排到記憶體較寬裕的 `gpu01`。

提供三種形式，跟其他產品的教學走法一致：

| 目錄/檔案 | 用途 |
|---|---|
| [manifest/](manifest/) | 教學主線：13 支編號檔案，一支一支 apply |
| [peertube-all-in-one.yaml](peertube-all-in-one.yaml) | 合併版單檔 |
| [chart/](chart/) | Helm Chart 版本 |
| [exercises/](exercises/) | **學員練習**：半成品 YAML 填空 + 埋錯除錯兩種題型，含架構圖、提示與驗收標準，`manifest/` 就是這些題目的正解 |

**前置條件**：

```bash
kubectl top node gpu01                               # 上課前先確認節點資源狀況
kubectl apply -f ../shared-infra/00-dev-gateway.yaml
```

### 方式一：教學主線

```bash
kubectl apply -f manifest/00-namespace.yaml
kubectl apply -f manifest/01-resourcequota-limitrange.yaml
kubectl apply -f manifest/02-postgres-secret.yaml
kubectl apply -f manifest/03-postgres-initdb-configmap.yaml
kubectl apply -f manifest/04-postgres-service.yaml
kubectl apply -f manifest/05-postgres-statefulset.yaml
kubectl apply -f manifest/06-redis.yaml
kubectl apply -f manifest/07-peertube-secret.yaml
kubectl apply -f manifest/08-peertube-pvc.yaml
kubectl apply -f manifest/09-peertube-deployment.yaml
kubectl apply -f manifest/10-peertube-service.yaml
kubectl apply -f manifest/11-httproute.yaml
kubectl apply -f manifest/12-networkpolicy.yaml   # 進階、選用
```

### 方式二：合併版一次套用

```bash
kubectl apply -f peertube-all-in-one.yaml
```

### 方式三：Helm Chart

```bash
kubectl apply -f manifest/00-namespace.yaml
helm install peertube ./chart -n peertube
# 移除：helm uninstall peertube -n peertube
```

### 上課前請先確認 / 調整

- `09-peertube-deployment.yaml`（或 chart 的 `peertube.webserverHostname`）
  裡的 hostname 要跟 `11-httproute.yaml` 一致，並確認 DNS/hosts
  指向 `dev-gateway` 的 EXTERNAL-IP。這個產品只掛 https 監聽器
  （見 `PEERTUBE_WEBSERVER_HTTPS=true`），請用 https 存取。
- 密碼／`PEERTUBE_SECRET` 僅供教學使用。
- 第一次啟動要跑資料庫 migration、產生 RSA 金鑰、建立管理員帳號，
  實測約 30~60 秒。

### 帳號密碼一覽

| 用途 | 帳號 | 密碼／值 | 來源 |
|---|---|---|---|
| PeerTube 管理員登入 | `root`（寫死，不可改） | `TrainingPeertubeRoot123` | [07-peertube-secret.yaml](manifest/07-peertube-secret.yaml) `PT_INITIAL_ROOT_PASSWORD` |
| PeerTube 管理員 Email | — | `admin@example.com` | [07-peertube-secret.yaml](manifest/07-peertube-secret.yaml) `PEERTUBE_ADMIN_EMAIL` |
| PeerTube session/cookie 簽章金鑰 | — | `TrainingOnlyPeertubeSecret_ChangeMeInProduction` | [07-peertube-secret.yaml](manifest/07-peertube-secret.yaml) `PEERTUBE_SECRET` |
| PostgreSQL | `peertube` | `TrainingPeertube123` | [02-postgres-secret.yaml](manifest/02-postgres-secret.yaml) `POSTGRES_USER`/`POSTGRES_PASSWORD`（`PEERTUBE_DB_PASSWORD` 同一組值） |
| Redis | 無驗證 | — | [06-redis.yaml](manifest/06-redis.yaml)，教學用途未開 `requirepass` |

⚠️ 全部僅供教學使用，正式環境請務必更換。`PT_INITIAL_ROOT_PASSWORD`／
`PEERTUBE_ADMIN_EMAIL` 只在資料庫全新初始化時生效（見上方說明）；
既有實例要改密碼，用下方「驗證」段落提到的 reset-password 腳本。

### 驗證與教學觀察點

```bash
kubectl get pod -n peertube -o wide
# 全新安裝（資料庫是空的）時，管理員帳號會用 07-peertube-secret.yaml
# 裡的 PT_INITIAL_ROOT_PASSWORD／PEERTUBE_ADMIN_EMAIL 建立，可以在
# 啟動 log 裡確認建立時用的是哪組值：
kubectl logs -n peertube deploy/peertube | grep -A1 "Username: root"
kubectl exec -n peertube postgres-0 -- psql -U peertube -d peertube -c "\dx"   # 確認 extension
kubectl top pod -n peertube                                                    # 觀察三個 Pod 的實際資源用量
```

⚠️ **實測確認**：`PT_INITIAL_ROOT_PASSWORD`／`PEERTUBE_ADMIN_EMAIL` 只有
在資料庫是空的、帳號第一次被建立的那一刻才會被讀取；之後不管重啟幾次
Pod、或事後改 secret 裡的值，都不會回頭改到已經存在的帳號（密碼在
DB 裡是雜湊過的，也無法反查明文）。如果既有帳號的密碼要換成跟 secret
裡一致（或忘記密碼），要用 PeerTube 內建的重設密碼腳本：

```bash
printf '<新密碼>\n<新密碼>\n' | kubectl exec -i -n peertube deploy/peertube -- \
  node ./dist/scripts/reset-password.js -u root
```

### 清除環境

```bash
kubectl delete namespace peertube
```
