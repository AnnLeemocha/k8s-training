# planka Helm Chart

用 Helm 部署 [Planka](https://planka.app/)，並把 PostgreSQL 併在同一個
chart 裡（同一 namespace 的 StatefulSet）。是 flarum（mysql）的對照組：
Planka 應用映像本身以非 root 身分（`node`，uid 1000）啟動，不需要
initContainer，容器也能直接套用 `capabilities.drop: [ALL]` 完整硬化。
對應的純 yaml 教學版本見 [`../manifest/`](../manifest/)。

Chart 建立的資源（`templates/`）：Planka Deployment、postgres
StatefulSet、2 個 Service、HTTPRoute、1 個 PVC、2 個 Secret、
NetworkPolicy、ResourceQuota + LimitRange。**不包含 Namespace**——請先
手動建立或套用 [`../manifest/00-namespace.yaml`](../manifest/00-namespace.yaml)。

## 安裝

```bash
kubectl apply -f ../manifest/00-namespace.yaml
helm install planka . -n planka
helm template planka . -n planka   # 預覽渲染結果
helm uninstall planka -n planka
```

## Values 參數

### `postgres` — 併入的 StatefulSet

官方 postgres 映像的 entrypoint 需要用 root 身分自降權，所以 postgres
容器本身不套用 `capabilities.drop: [ALL]`（跟下面 planka 應用容器不同）。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `postgres.image.repository` / `.tag` | postgres 容器映像檔 | `postgres` / `16.4-alpine` |
| `postgres.auth.user` | 資料庫帳號 | `planka` |
| `postgres.auth.password` | 資料庫密碼；同一份密碼被 `planka-secret` 拿去組 `DATABASE_URL`，刻意不含特殊符號以避免 URL escape 問題（教學用明文） | `TrainingPlanka123` |
| `postgres.auth.database` | 資料庫名稱 | `planka` |
| `postgres.persistence.storageClassName` / `.size` | 資料目錄 PVC，單寫用 Ceph RBD | `rook-ceph-block` / `5Gi` |
| `postgres.resources.requests.cpu` / `.memory` | postgres 容器 requests | `200m` / `512Mi` |
| `postgres.resources.limits.cpu` / `.memory` | postgres 容器 limits | `1` / `1Gi` |

### `planka` — 應用本身

| 參數 | 說明 | 預設值 |
|---|---|---|
| `planka.image.repository` / `.tag` | Planka 容器映像檔（`ghcr.io` 在本叢集拉取較慢，實測 5-15 分鐘，正式上課前建議先在各節點預先 pull） | `ghcr.io/plankanban/planka` / `latest` |
| `planka.baseUrl` | 對外網址，寫進 `BASE_URL`，**必須跟下面 `hostnames[0]` 一致** | `http://planka.nexai.org.com` |
| `planka.secretKey` | 加密 session/cookie 用的密鑰，跟資料庫密碼無關 | `TrainingOnlySecretKey_ChangeMeInProduction` |
| `planka.admin.email` / `.name` / `.username` / `.password` | 初次啟動（資料庫為空時）建立的管理員帳號 | `admin@example.com` / `K8s Training Admin` / `admin` / `TrainingAdmin123!` |
| `planka.resources.requests.cpu` / `.memory` | Planka 容器 requests | `150m` / `384Mi` |
| `planka.resources.limits.cpu` / `.memory` | Planka 容器 limits | `500m` / `768Mi` |
| `planka.persistence.storageClassName` / `.size` | 上傳附件 PVC（掛到 `/app/data`），用 CephFS 預留未來多 replica 共享的可能性 | `rook-cephfs` / `5Gi` |

### `resourceQuota` / `limitRange`

同一個 namespace 同時跑 Planka 應用跟 postgres 兩個 workload，配額要
覆蓋兩者加總。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resourceQuota.enabled` | 是否建立 ResourceQuota | `true` |
| `resourceQuota.requestsCpu` / `.requestsMemory` / `.limitsCpu` / `.limitsMemory` | namespace 加總配額 | `1` / `1.5Gi` / `2` / `3Gi` |
| `resourceQuota.pods` | 最多 Pod 數 | `6` |
| `resourceQuota.persistentVolumeClaims` | 最多 PVC 數 | `6` |
| `resourceQuota.requestsStorage` | 儲存空間加總配額 | `20Gi` |
| `limitRange.enabled` | 是否建立 LimitRange | `true` |
| `limitRange.default.cpu` / `.memory` | 未填 `limits` 的預設值 | `250m` / `512Mi` |
| `limitRange.defaultRequest.cpu` / `.memory` | 未填 `requests` 的預設值 | `100m` / `256Mi` |
| `limitRange.max.cpu` / `.memory` | 單一容器上限 | `1` / `1Gi` |
| `limitRange.min.cpu` / `.memory` | 單一容器下限 | `50m` / `128Mi` |

### `service` / `gateway` / `hostnames` / `networkPolicy`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `service.port` | ClusterIP Service 對外 port，轉給 Planka 容器實際監聽的 `1337` | `80` |
| `gateway.name` / `.namespace` / `.sectionNames` | HTTPRoute 掛的 Gateway | `dev-gateway` / `default` / `[http, https]` |
| `hostnames` | HTTPRoute 比對 Host header 用的網域，必須跟 `planka.baseUrl` 一致 | `[planka.nexai.org.com]` |
| `networkPolicy.enabled` | 是否啟用 NetworkPolicy（same-namespace podSelector-to-podSelector：Gateway→Planka、Planka→postgres，跟 flarum 的 mysql NetworkPolicy 對稱） | `true` |

## 特殊注意事項

- `postgres.auth.password` 只在 PVC 第一次初始化（`initdb`）時套用；
  PVC 已存在後改密碼不會反映到實際的資料庫密碼，要改密碼得先清空 PVC。
- Planka 應用容器完整套用 `capabilities.drop: [ALL]`，是全教材容器安全
  模型的三種情境之一（跟 mysql/postgres/redis「不能 drop」、
  flarum「需要 initContainer」形成對照）。
- `ghcr.io` 映像拉取在本叢集較慢，正式上課前建議先預熱。
