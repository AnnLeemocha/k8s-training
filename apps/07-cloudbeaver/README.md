# CloudBeaver

DBeaver 官方推出的 Web 版本，同一個介面可以建立多組連線、支援
MySQL/PostgreSQL 等多種資料庫。

## K8s 教育訓練用途

課程裡第一個「不屬於任何單一應用、專門拿來管理其他產品資料庫」的工具型
產品。掃過目前所有產品的 `*-all-in-one.yaml` 之後，真正跑著一個「可以
用一般 SQL client 連進去」的網路資料庫的，只有三個：

| 產品 | 資料庫 | Host（在 cloudbeaver 這個 namespace 裡看） | Port |
|---|---|---|---|
| [../flarum](../flarum/)（mysql 併在自己 namespace 裡） | MySQL 8.0 | `mysql.flarum.svc.cluster.local` | 3306 |
| [../planka](../planka/)（postgres 併在自己 namespace 裡） | PostgreSQL 16 | `postgres.planka.svc.cluster.local` | 5432 |
| [../peertube](../peertube/)（專屬的 postgres） | PostgreSQL 16 | `postgres.peertube.svc.cluster.local` | 5432 |

**沒有列進來、也不建議接的**：
- filebrowser 用 sqlite（單一檔案、沒有對外的網路埠，不適合這種
  client-server 連線方式）。
- onlyoffice 把 postgres/redis/rabbitmq 全部包在自己 image 內部，沒有
  獨立曝露 Service。
- peertube 的 redis 是 key-value store，不是 CloudBeaver 這類 SQL 用戶端
  主要照顧的對象；如果之後想管理 redis，建議另外找專門的 redis GUI
  工具，而不是勉強塞進同一個介面。

教學重點：

- **這是第一個「主動連到好幾個不同 namespace」的產品**：NetworkPolicy
  的 egress 規則用 `namespaceSelector` 分別指到 flarum/planka/peertube
  三個 namespace（用叢集自動加上的 `kubernetes.io/metadata.name` 標籤
  比對），對應地，那三個產品各自的 NetworkPolicy 也都加了一條 ingress
  規則，放行「namespace 名稱是 cloudbeaver」的來源連進資料庫的 port。
- **跟 mysql/postgres/redis/flarum 同樣的「entrypoint 需要 root」教訓**：
  CloudBeaver 官方 image 一樣是用 root 啟動、chown 掛進來的 workspace
  PVC 之後才降權，`capabilities.drop: [ALL]` 實測會直接啟動失敗
  （`Operation not permitted`），所以沒有比照 Adminer 做完整安全強化。
- **livenessProbe 刻意給比較保守的 initialDelaySeconds**：這是接續
  「mysql 併入 flarum」時踩到的教訓（livenessProbe 太早開始檢查，會在
  應用程式還在初始化時就把容器砍掉）——Java 應用冷啟動通常比 PHP/Node
  慢，這裡直接抓寬鬆一點。
- **需要持久化 workspace**：CloudBeaver 把使用者、權限、以及使用者自己
  建立的連線設定存在 workspace 目錄底下的內部資料庫，不是無狀態應用，
  用 RWO PVC 掛住，Pod 重建後設定不會不見。

提供三種形式，跟其他產品的教學走法一致：

| 目錄/檔案 | 用途 |
|---|---|
| [manifest/](manifest/) | 教學主線：7 支編號檔案，一支一支 apply |
| [cloudbeaver-all-in-one.yaml](cloudbeaver-all-in-one.yaml) | 合併版單檔 |
| [chart/](chart/) | Helm Chart 版本 |
| [exercises/](exercises/) | **學員練習**：半成品 YAML 填空 + 埋錯除錯兩種題型，含架構圖、提示與驗收標準，`manifest/` 就是這些題目的正解 |

**前置條件**：
1. 先套用共用的教學 Gateway：
   ```bash
   kubectl apply -f ../shared-infra/00-dev-gateway.yaml
   ```
2. flarum、planka、peertube 都要先部署好，而且要重新 apply 過各自最新的
   NetworkPolicy 檔案（`flarum/manifest/10-networkpolicy.yaml`、
   `planka/manifest/10-networkpolicy.yaml`、
   `peertube/manifest/12-networkpolicy.yaml`），確保裡面已經包含放行
   cloudbeaver 連進來的規則。

### 方式一：教學主線

```bash
kubectl apply -f manifest/00-namespace.yaml
kubectl apply -f manifest/01-resourcequota-limitrange.yaml
kubectl apply -f manifest/02-pvc.yaml
kubectl apply -f manifest/03-deployment.yaml
kubectl apply -f manifest/04-service.yaml
kubectl apply -f manifest/05-httproute.yaml
kubectl apply -f manifest/06-networkpolicy.yaml   # 進階、選用
```

### 方式二：合併版一次套用

```bash
kubectl apply -f cloudbeaver-all-in-one.yaml
```

### 方式三：Helm Chart

```bash
kubectl apply -f manifest/00-namespace.yaml
helm install cloudbeaver ./chart -n cloudbeaver
# 移除：helm uninstall cloudbeaver -n cloudbeaver
```

### 上課前請先確認 / 調整：第一次啟動要手動完成設定精靈

跟這門課其他產品不同，CloudBeaver **沒有**用環境變數自動建立管理員帳號
（實測過目前這個版本的 GraphQL API 在 `configurationMode: true` 狀態下
沒有對外開放可程式化完成設定的 mutation，只能透過瀏覽器精靈完成）。

#### 步驟一：設定管理員帳號（一次性精靈）

1. 瀏覽器打開 `https://cloudbeaver.nexai.org.com`（自簽憑證會有不受信任
   警告，屬預期行為，跟其他產品一樣）。
2. CloudBeaver 偵測到還沒設定過，會直接顯示**設定精靈**，而不是登入畫面。
   依序完成：
   - **Server configuration**：Server Name 隨意填（例如
     `K8s Training`），其他選項用預設值即可（不需要開啟匿名/公開存取）。
   - **Administrator account**：設定管理員帳號密碼——**帳號名稱請勿用
     `admin`**（見下方「實測踩到的真坑」，這是已知會失敗的名稱），改用
     例如 `cbadmin` 或 `trainingadmin`。**這一步只會出現一次**，精靈跑完
     之後，這個版本的 API 無法再用程式化方式重新設定，請務必記下密碼，
     行為模式跟 peertube 的「只印一次」帳密提醒類似。
     * account: `cbadmin`
     * password: `TrainingSQL123!`
3. 完成精靈後會直接以該管理員帳號登入主畫面。

**實測踩到的真坑（如果精靈送出後顯示
`User or team 'admin' already exists`）**：這不是暫存狀態損毀，而是這個
版本 CloudBeaver 的真實 bug——`conf/initial-data.conf`（image 內建，資料庫
第一次初始化時就會套用）預先種了一個 `subjectId: "admin"` 的內建團隊
（Admin team），跟使用者/團隊共用同一張 `CB_AUTH_SUBJECT` 表、同一個
命名空間。如果精靈裡的管理員帳號也取名 `admin`，`createAdminUser` 一定
會跟這個內建團隊的 ID 撞名，**不管重試幾次、密碼改成什麼都一樣會失敗**，
清掉 workspace PVC 重來也沒用（乾淨的全新資料庫一樣會種出這個內建
`admin` 團隊）。目前唯一的解法就是換一個不叫 `admin` 的帳號名稱。

（另外也試過用 ConfigMap 蓋掉 `initial-data.conf`、透過
`adminName`/`adminPassword` 欄位讓管理員帳號在資料庫初始化時就自動建立，
想完全跳過網頁精靈——結果在這個版本反而觸發另一個更嚴重的 schema
migration bug（`Duplicate column name "UPDATE_TIME"`），容器直接開機
失敗。兩個方向都踩到真的 bug，最後還是回到「手動跑精靈、但帳號別取名
admin」這個最簡單可靠的做法。）

#### 步驟二：串接三個資料庫

在左側 Connections 面板點 `New Connection`（+ 號/插頭圖示），每個資料庫
重複一次：

| 欄位 | flarum（MySQL） | planka（PostgreSQL） | peertube（PostgreSQL） |
|---|---|---|---|
| Connection name | `flarum-mysql` | `planka-postgres` | `peertube-postgres` |
| Driver | MySQL | PostgreSQL | PostgreSQL |
| Host | `mysql.flarum.svc.cluster.local` | `postgres.planka.svc.cluster.local` | `postgres.peertube.svc.cluster.local` |
| Port | 3306 | 5432 | 5432 |
| Database | `appdb` | `planka` | `peertube` |
| Username | `appuser` | `planka` | `peertube` |
| Password | `TrainingApp123!` | `TrainingPlanka123` | `TrainingPeertube123` |

1. 選好 Driver 之後，如果是第一次用該類型，CloudBeaver 會提示下載對應
   的 JDBC driver，屬正常流程，每種資料庫類型只需要下載一次。
2. 依上表填入 Connection name（必填，純粹是顯示用的名稱，不影響實際
   連線，方便在左側清單分辨這是哪個資料庫）以及 Host/Port/Database/
   Username/Password。
3. 點 `Test Connection`，應該顯示連線成功（NetworkPolicy 已經放行這幾條
   路徑，見下方「驗證與教學觀察點」）。
4. 儲存連線。

密碼如果要覆核，來源分別在：`flarum/manifest/02-mysql-secret.yaml`、
`planka/manifest/02-postgres-secret.yaml`、
`peertube/manifest/02-postgres-secret.yaml`。

### 驗證與教學觀察點

```bash
kubectl get pod,pvc -n cloudbeaver
kubectl get httproute cloudbeaver -n cloudbeaver -o yaml   # 看 Accepted/ResolvedRefs
# 從 cloudbeaver pod 內測 TCP 是否真的連得到三個資料庫（不需要密碼，
# 純粹驗證 NetworkPolicy 有沒有放行）：
POD=$(kubectl get pod -n cloudbeaver -l app=cloudbeaver -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n cloudbeaver "$POD" -- bash -c 'echo > /dev/tcp/mysql.flarum.svc.cluster.local/3306 && echo OK'
kubectl exec -n cloudbeaver "$POD" -- bash -c 'echo > /dev/tcp/postgres.planka.svc.cluster.local/5432 && echo OK'
kubectl exec -n cloudbeaver "$POD" -- bash -c 'echo > /dev/tcp/postgres.peertube.svc.cluster.local/5432 && echo OK'
```

### 清除環境

```bash
kubectl delete namespace cloudbeaver
```
