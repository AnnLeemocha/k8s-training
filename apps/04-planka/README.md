# Planka

輕量級、開源的看板式專案管理工具（類似 Trello），適合團隊進行任務追蹤。

## K8s 教育訓練用途

課程第五個範例，也是第一個「自帶專屬資料庫」的產品（PostgreSQL 跟
Planka 應用程式放在同一個 namespace，只服務這一個產品）——flarum
後來把它的 mysql 也併進同一個 namespace，變成同一種架構，兩個產品可以
互相對照講解。

- ⚠️ **官方文件常說 Planka 要用 mysql——這是錯的**：Planka 官方
  docker-compose 實際用的是 **PostgreSQL**，所以這裡部署一份專屬的
  PostgreSQL，跟 flarum 用的 mysql 是不同的資料庫產品。
- **同 namespace 內部的服務隔離**：NetworkPolicy 用 podSelector 示範
  同一個 namespace 裡，只有貼 `app=planka` 標籤的 Pod 能連到
  postgres，其他 Pod 一樣連不到——跟 flarum 併入 mysql 之後的
  NetworkPolicy 是同一種寫法。
- **同一份「安全強化」不是每個 image 都能套用，也不是每個 image 都不能**：
  官方 planka image 實測發現本來就是用非 root 的 `node`
  使用者（uid 1000）啟動，不像 mysql/postgres/flarum 需要以 root
  啟動再降權，所以這裡放心把 capabilities 全部 drop 掉——延續
  mysql/flarum 教的「先驗證、別預設套用同一套安全模板」。
- **PVC 存取模式決定能不能做零停機更新**：`planka-data` 用 RWX，
  所以這裡的 Deployment 用預設的 RollingUpdate 就行，不像 flarum/
  filebrowser 因為 RWO 被迫用 Recreate。
- **DATABASE_URL 是組合好的連線字串**：跟 mysql/flarum 用一組一組
  獨立的 DB_HOST/DB_USER/DB_PASS 環境變數不同，Planka 是單一個
  `postgresql://user:pass@host/db` 字串，密碼裡不能有沒編碼的
  `@` `:` `/` 等保留字元，這裡故意選一個不含特殊符號的密碼繞開這個問題。

提供三種形式，跟其他產品的教學走法一致：

| 目錄/檔案 | 用途 |
|---|---|
| [manifest/](manifest/) | 教學主線：11 支編號檔案，一支一支 apply |
| [planka-all-in-one.yaml](planka-all-in-one.yaml) | 合併版單檔 |
| [chart/](chart/) | Helm Chart 版本 |
| [exercises/](exercises/) | **學員練習**：半成品 YAML 填空 + 埋錯除錯兩種題型，含架構圖、提示與驗收標準，`manifest/` 就是這些題目的正解 |

**前置條件**：只需要共用的教學 Gateway（這個產品自帶專屬的 PostgreSQL，
不依賴其他產品的資料庫）：

```bash
kubectl apply -f ../shared-infra/00-dev-gateway.yaml
```

⚠️ **第一次在某個 Node 上部署，`ghcr.io/plankanban/planka` 這個 image
拉取實測要 5～10 分鐘**（比 Docker Hub 上的其他 image 慢很多，
可能是 ghcr.io 對這個網路環境的頻寬/流量限制），建議正式上課前，
先在每個會排到 Pod 的 Node 上手動 `docker`/`crictl pull` 過一次
預熱，避免課堂上乾等。

### 方式一：教學主線

```bash
kubectl apply -f manifest/00-namespace.yaml
kubectl apply -f manifest/01-resourcequota-limitrange.yaml
kubectl apply -f manifest/02-postgres-secret.yaml
kubectl apply -f manifest/03-postgres-service.yaml
kubectl apply -f manifest/04-postgres-statefulset.yaml
kubectl apply -f manifest/05-planka-secret.yaml
kubectl apply -f manifest/06-planka-pvc.yaml
kubectl apply -f manifest/07-planka-deployment.yaml
kubectl apply -f manifest/08-planka-service.yaml
kubectl apply -f manifest/09-httproute.yaml
kubectl apply -f manifest/10-networkpolicy.yaml   # 進階、選用
```

### 方式二：合併版一次套用

```bash
kubectl apply -f planka-all-in-one.yaml
```

### 方式三：Helm Chart

```bash
kubectl apply -f manifest/00-namespace.yaml
helm install planka ./chart -n planka
# 移除：helm uninstall planka -n planka
```

### 上課前請先確認 / 調整

- `07-planka-deployment.yaml`（或 chart 的 `planka.baseUrl`）裡的
  `BASE_URL` 要跟 `09-httproute.yaml` 的 `hostnames` 一致，並確認
  DNS/hosts 指向 `dev-gateway` 的 EXTERNAL-IP。
- 密碼／`SECRET_KEY` 僅供教學使用，正式環境請改用隨機字串。
- 預設管理員帳號密碼是 `admin` / `TrainingAdmin123!`，上課示範完
  請提醒學員修改。
- ⚠️ **實測踩到的坑**：PostgreSQL 官方 image 只有在資料目錄「第一次
  初始化」時才會套用 `POSTGRES_PASSWORD`。如果 `02-postgres-secret.yaml`
  的密碼在 PVC 已經初始化過之後才修改，postgres Pod 重啟並不會
  套用新密碼，會變成 Secret 裡的密碼（也是 Planka 用來組
  `DATABASE_URL` 的密碼）跟資料庫裡實際的密碼對不上，導致
  Planka 連線出現 `password authentication failed`。修改密碼的正確做法
  是先確認資料還沒有要保留（`kubectl delete pvc data-postgres-0 -n planka`
  讓它重新初始化），或改用 `ALTER USER` 直接在資料庫裡改密碼，
  而不是只改 Secret 就期待它生效。

### 驗證與教學觀察點

```bash
kubectl get pod -n planka -o wide
kubectl exec -n planka postgres-0 -- psql -U planka -d planka -c "\dt"   # 看 Planka 自動建的資料表
kubectl get pvc -n planka
```

### 清除環境

```bash
kubectl delete namespace planka
```
