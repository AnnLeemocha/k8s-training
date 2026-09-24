# flarum Helm Chart

用 Helm 部署 [Flarum](https://flarum.org/)（社群映像 `mondedie/flarum`，Flarum 官方沒有提供
映像），並把 mysql 併在同一個 chart 裡（比照 planka 把 postgres 併進
自己 chart 的做法，不再是獨立的 mysql chart）。全教材第一個
StatefulSet + initContainer + 兩個 Secret 互相引用的範例。對應的純
yaml 教學版本見 [`../manifest/`](../manifest/)。

Chart 建立的資源（`templates/`）：Flarum Deployment、mysql
StatefulSet、2 個 Service、HTTPRoute、2 個 PVC、2 個 Secret、
NetworkPolicy、ResourceQuota + LimitRange。**不包含 Namespace**——請先
手動建立或套用 [`../manifest/00-namespace.yaml`](../manifest/00-namespace.yaml)。

## 安裝

```bash
kubectl apply -f ../manifest/00-namespace.yaml
helm install flarum . -n flarum
helm template flarum . -n flarum   # 預覽渲染結果
helm uninstall flarum -n flarum
```

## Values 參數

### 基本設定

| 參數 | 說明 | 預設值 |
|---|---|---|
| `image.repository` / `image.tag` / `image.pullPolicy` | Flarum 容器映像檔 | `mondedie/flarum` / `latest` / `IfNotPresent` |

### `db` — Flarum 連線 mysql 的參數

寫進 Deployment 的環境變數 `DB_HOST`/`DB_PORT`/`DB_DATABASE`/
`DB_USERNAME`。密碼不在這裡設定，Deployment 直接用 `secretKeyRef` 讀
`mysql.auth.password` 產生的 Secret（同 namespace 內 Secret 可互相
引用，不用重複複製密碼）。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `db.host` | mysql Service 的短名稱（同 namespace 內不需要 FQDN） | `mysql` |
| `db.port` | mysql port | `3306` |
| `db.name` | 資料庫名稱 | `appdb` |
| `db.user` | 應用連線帳號 | `appuser` |

### `forum` — Flarum 論壇設定

| 參數 | 說明 | 預設值 |
|---|---|---|
| `forum.url` | 論壇對外網址，寫進 `FLARUM_URL`，**必須跟下面 `hostnames[0]` 一致**否則內部連結網域會錯 | `http://flarum.nexai.org.com` |
| `forum.title` | 論壇標題 | `K8s Training Forum` |
| `forum.adminUser` | 初次安裝建立的管理員帳號 | `admin` |
| `forum.adminMail` | 管理員信箱 | `admin@example.com` |
| `forum.adminPassword` | 管理員密碼（教學用明文，正式環境請改用外部密鑰管理） | `TrainingAdmin123!` |

### `resources` / `resourceQuota` / `limitRange`

同一個 namespace 現在同時跑 Flarum 跟 mysql 兩個 workload，配額要覆蓋
兩者加總。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resources.requests.cpu` / `.memory` | Flarum 容器 requests | `100m` / `256Mi` |
| `resources.limits.cpu` / `.memory` | Flarum 容器 limits | `500m` / `1Gi` |
| `resourceQuota.enabled` | 是否建立 ResourceQuota | `true` |
| `resourceQuota.requestsCpu` / `.requestsMemory` / `.limitsCpu` / `.limitsMemory` | namespace 加總配額（涵蓋 Flarum + mysql） | `750m` / `1Gi` / `2` / `3Gi` |
| `resourceQuota.pods` | 最多 Pod 數 | `5` |
| `resourceQuota.persistentVolumeClaims` | 最多 PVC 數 | `4` |
| `resourceQuota.requestsStorage` | 儲存空間加總配額 | `20Gi` |
| `limitRange.enabled` | 是否建立 LimitRange | `true` |
| `limitRange.default.cpu` / `.memory` | 未填 `limits` 的預設值 | `250m` / `512Mi` |
| `limitRange.defaultRequest.cpu` / `.memory` | 未填 `requests` 的預設值 | `100m` / `256Mi` |
| `limitRange.max.cpu` / `.memory` | 單一容器上限（要 ≥ mysql 自己的 limits） | `1` / `2Gi` |
| `limitRange.min.cpu` / `.memory` | 單一容器下限 | `50m` / `128Mi` |

### `persistence` — Flarum 的兩個 PVC

刻意只掛「兩個子路徑」而不是整個 `/flarum/app`，因為該路徑上還有映像
內建的應用程式碼，整包掛 PVC 會蓋掉程式碼。initContainer 會在 Pod
啟動時補上這兩個空 PVC 的預期子目錄結構。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `persistence.storage.storageClassName` / `.size` | `/flarum/app/storage`（session/cache 等執行期資料），單寫用 Ceph RBD | `rook-ceph-block` / `2Gi` |
| `persistence.assets.storageClassName` / `.size` | `/flarum/app/public/assets`（使用者上傳/發布的靜態資源），可能多 Pod 共享用 CephFS | `rook-cephfs` / `5Gi` |

### `service` / `gateway` / `hostnames` / `networkPolicy`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `service.port` | ClusterIP Service 對外 port | `80` |
| `service.containerPort` | Flarum 容器實際監聽的 port（非 80，是踩過 K8s 自動注入 `FLARUM_PORT` 環境變數衝突之後改用 `enableServiceLinks: false` 解決的） | `8888` |
| `gateway.name` / `.namespace` / `.sectionNames` | HTTPRoute 掛的 Gateway | `dev-gateway` / `default` / `[http, https]` |
| `hostnames` | HTTPRoute 比對 Host header 用的網域，必須跟 `forum.url` 一致 | `[flarum.nexai.org.com]` |
| `networkPolicy.enabled` | 是否啟用 NetworkPolicy（same-namespace podSelector：Gateway→Flarum、Flarum→mysql 兩條主線 + default-deny + DNS） | `true` |

### `mysql` — 併入的 StatefulSet

比照 planka 把 postgres 併進自己 chart 的做法，`enabled: false` 可以
整個關掉這組資源（例如改連外部既有的 mysql）。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `mysql.enabled` | 是否建立 mysql StatefulSet | `true` |
| `mysql.image.repository` / `.tag` / `.pullPolicy` | mysql 容器映像檔（官方映像需要 root 自降權，不能套用 `capabilities.drop: [ALL]`） | `mysql` / `8.0.40` / `IfNotPresent` |
| `mysql.auth.rootPassword` | root 密碼 | `TrainingRoot123!` |
| `mysql.auth.database` | 資料庫名稱 | `appdb` |
| `mysql.auth.username` | 應用帳號 | `appuser` |
| `mysql.auth.password` | 應用密碼（Flarum 的 `DB_PASS` 直接 `secretKeyRef` 讀這裡，不重複填） | `TrainingApp123!` |
| `mysql.resources.requests.cpu` / `.memory` | mysql 容器 requests | `250m` / `512Mi` |
| `mysql.resources.limits.cpu` / `.memory` | mysql 容器 limits | `1` / `1Gi` |
| `mysql.persistence.storageClassName` / `.size` | mysql 資料目錄 PVC，單寫用 Ceph RBD | `rook-ceph-block` / `5Gi` |

## 特殊注意事項

- `mysql.auth.*` 只在 PVC 第一次初始化（`initdb`）時套用；PVC 已存在
  後改密碼不會反映到實際的 mysql 帳密，要改密碼得先清空 PVC。
- mysql 首次 `initdb` 在本叢集實測約需 97 秒，StatefulSet 的
  `livenessProbe.initialDelaySeconds` 必須設得比這個時間長，太短會在
  `initdb` 過程中把容器殺掉，導致密碼設定「半完成」而永久鎖死
  （`Host 'x' is not allowed to connect`）。
- 若曾清空 mysql 的 PVC 重新初始化，記得同時檢查 Flarum 自己的
  `assets` PVC 是否留有安裝完成的標記檔（`._flarum-installed.lock`），
  否則 Flarum 會跳過安裝流程直接崩潰。
