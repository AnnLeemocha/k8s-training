# cloudbeaver Helm Chart

用 Helm 部署 [CloudBeaver](https://github.com/dbeaver/cloudbeaver)（DBeaver 官方的 Web
版），作為 flarum/planka/peertube 三個資料庫的共用視覺化用戶端。全教材
唯一「跨 namespace 存取」的產品：CloudBeaver 本身不存任何資料庫密碼
（連線資訊由使用者登入後在網頁上輸入）。對應的純 yaml 教學版本見
[`../manifest/`](../manifest/)。

Chart 建立的資源（`templates/`）：Deployment、Service、HTTPRoute、
PVC、NetworkPolicy、ResourceQuota + LimitRange。**不包含
Namespace**——請先手動建立或套用
[`../manifest/00-namespace.yaml`](../manifest/00-namespace.yaml)。

**部署前置條件**：flarum/planka/peertube 這三個 namespace 各自的
NetworkPolicy 都要先套用過允許 cloudbeaver 連進來的規則（已內建在那
三個產品的 manifest 裡）。

## 安裝

```bash
kubectl apply -f ../manifest/00-namespace.yaml
helm install cloudbeaver . -n cloudbeaver
helm template cloudbeaver . -n cloudbeaver   # 預覽渲染結果
helm uninstall cloudbeaver -n cloudbeaver
```

## Values 參數

### 基本設定

| 參數 | 說明 | 預設值 |
|---|---|---|
| `image.repository` / `image.tag` / `image.pullPolicy` | CloudBeaver 容器映像檔 | `dbeaver/cloudbeaver` / `latest` / `IfNotPresent` |

### `resources`

CloudBeaver 是 JVM 應用，冷啟動較慢，資源抓得比同類單體應用寬（配合
`livenessProbe.initialDelaySeconds` 拉長）。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resources.requests.cpu` / `.memory` | 容器 requests | `250m` / `512Mi` |
| `resources.limits.cpu` / `.memory` | 容器 limits | `1` / `1536Mi` |

### `resourceQuota` / `limitRange`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resourceQuota.enabled` | 是否建立 ResourceQuota | `true` |
| `resourceQuota.requestsCpu` / `.requestsMemory` / `.limitsCpu` / `.limitsMemory` | namespace 加總配額 | `500m` / `1Gi` / `2` / `2Gi` |
| `resourceQuota.pods` | 最多 Pod 數 | `3` |
| `resourceQuota.persistentVolumeClaims` | 最多 PVC 數 | `2` |
| `resourceQuota.requestsStorage` | 儲存空間加總配額 | `10Gi` |
| `limitRange.enabled` | 是否建立 LimitRange | `true` |
| `limitRange.default.cpu` / `.memory` | 未填 `limits` 的預設值 | `500m` / `1Gi` |
| `limitRange.defaultRequest.cpu` / `.memory` | 未填 `requests` 的預設值 | `250m` / `512Mi` |
| `limitRange.max.cpu` / `.memory` | 單一容器上限 | `2` / `2Gi` |
| `limitRange.min.cpu` / `.memory` | 單一容器下限（本教材曾在幫這個 namespace 加 Adminer 時，真的踩過 `min` 抓太高擋掉合理輕量容器的坑，後來改把 DB 管理工具獨立成 cloudbeaver 這個產品） | `100m` / `256Mi` |

### `persistence`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `persistence.storageClassName` / `.size` | 工作區 PVC（存放使用者設定、連線資訊、內建 H2 中繼資料庫，不含目標資料庫密碼），單一 replica 單寫用 Ceph RBD | `rook-ceph-block` / `2Gi` |

### `service`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `service.port` | ClusterIP Service 對外 port | `80` |
| `service.containerPort` | CloudBeaver 容器實際監聽的 port，同時是 NetworkPolicy 放行的 port | `8978` |

### `gateway` / `hostnames`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `gateway.name` / `.namespace` / `.sectionNames` | HTTPRoute 掛的 Gateway | `dev-gateway` / `default` / `[http, https]` |
| `hostnames` | HTTPRoute 比對 Host header 用的網域 | `[cloudbeaver.nexai.org.com]` |

### `networkPolicy`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `networkPolicy.enabled` | 是否啟用 NetworkPolicy（default-deny + Gateway 進來、DNS egress、對 `databaseTargets` 逐條展開的 egress 規則） | `true` |
| `networkPolicy.databaseTargets` | 一個陣列，每筆 `{namespace, port}` 用 `range` 展開成一條 egress 規則（`namespaceSelector` 比對目標 namespace 的內建 label `kubernetes.io/metadata.name`）。只列出「真的有網路 port 可連」的資料庫：flarum 的 mysql（3306）、planka/peertube 各自的 postgres（5432）；刻意排除 filebrowser 的 sqlite（無網路 port）、onlyoffice 內建的 postgres/redis/rabbitmq（無獨立 Service）、peertube 的 redis（非 CloudBeaver 使用情境） | `[{flarum,3306},{planka,5432},{peertube,5432}]` |

## 特殊注意事項

- 對應地，flarum/planka/peertube 三個產品自己的 NetworkPolicy 也各加了
  一條 ingress 規則放行 `cloudbeaver` namespace 進來，兩邊要同時套用
  才會通。
- CloudBeaver 首次啟動的管理員設定精靈**不要**把帳號取名為 `admin`——
  該版本映像內部預先建立了 `subjectId: "admin"` 的預設 Team，跟這個
  名稱衝突會導致 `User or team 'admin' already exists` 永遠失敗，是
  已知且與密碼/重試次數無關的映像問題。改用其他帳號（例如
  `cbadmin`）即可。
- CloudBeaver 只是資料庫的視覺化用戶端，本身不存任何目標資料庫密碼，
  登入後在網頁上輸入即可連線到 `networkPolicy.databaseTargets` 裡列出
  的三個資料庫。
