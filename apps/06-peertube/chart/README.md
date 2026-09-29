# peertube Helm Chart

用 Helm 部署 [PeerTube](https://github.com/Chocobozzz/PeerTube)，全教材整合度最高的產品：
PostgreSQL（StatefulSet+PVC）+ Redis（Deployment+emptyDir）+ PeerTube
應用本身，三個元件都容忍 GPU 節點的 taint（預設不指定節點）。對應的純 yaml 教學版本見
[`../manifest/`](../manifest/)。

Chart 建立的資源（`templates/`）：PeerTube Deployment、postgres
StatefulSet（含 initdb ConfigMap）、redis Deployment、3 個 Service、
HTTPRoute、PVC、2 個 Secret、NetworkPolicy、ResourceQuota +
LimitRange。**不包含 Namespace**——請先手動建立或套用
[`../manifest/00-namespace.yaml`](../manifest/00-namespace.yaml)。

## 安裝

```bash
kubectl apply -f ../manifest/00-namespace.yaml
helm install peertube . -n peertube
helm template peertube . -n peertube   # 預覽渲染結果
helm uninstall peertube -n peertube
```

## Values 參數

### `nodePlacement`

三個元件（postgres/redis/peertube）共用同一組設定。預設只給
tolerations、不指定節點，由 Scheduler 自行挑選；本叢集 `k8s01~03`
記憶體長期在 81-91% 使用率，若扛不住這個產品三個 workload 的加總，
再設定 `nodeSelector` 把三個元件都釘到 `gpu01`。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `nodePlacement.nodeSelector` | 指定節點（預設不設） | 未設定（`values.yaml` 內註解保留 `kubernetes.io/hostname: gpu01`） |
| `nodePlacement.tolerations` | 對應 `gpu01` 的 GPU taint，允許（不強制）排到 `gpu01` | `[{key: nvidia.com/gpu, operator: Equal, value: "true", effect: NoSchedule}]` |

### `postgres`

搭配 ConfigMap 掛載到 `/docker-entrypoint-initdb.d/`，自動安裝
`pg_trgm`/`unaccent` 兩個 PeerTube 需要的 PostgreSQL extension。官方
映像需要 root 自降權，不能套用 `capabilities.drop: [ALL]`。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `postgres.image.repository` / `.tag` | postgres 容器映像檔 | `postgres` / `16.4-alpine` |
| `postgres.auth.user` / `.database` | 資料庫帳號/名稱 | `peertube` / `peertube` |
| `postgres.auth.password` | 資料庫密碼；`PEERTUBE_DB_PASSWORD` 直接讀這裡，不重複填（教學用明文）。只在 PVC 第一次 `initdb` 時套用，改密碼得先清空 PVC | `TrainingPeertube123` |
| `postgres.persistence.storageClassName` / `.size` | 資料目錄 PVC，單寫用 Ceph RBD | `rook-ceph-block` / `5Gi` |
| `postgres.resources.requests.cpu` / `.memory` | postgres 容器 requests | `200m` / `512Mi` |
| `postgres.resources.limits.cpu` / `.memory` | postgres 容器 limits | `1` / `1Gi` |

### `redis`

用 Deployment + emptyDir，不用 PVC——job queue/cache 資料重啟遺失是
可接受的，刻意跟 postgres 的 StatefulSet+PVC 做對照。官方映像同樣需要
root 自降權，不能套用 `capabilities.drop: [ALL]`。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `redis.image.repository` / `.tag` | redis 容器映像檔 | `redis` / `7.4-alpine` |
| `redis.resources.requests.cpu` / `.memory` | redis 容器 requests | `50m` / `128Mi` |
| `redis.resources.limits.cpu` / `.memory` | redis 容器 limits | `250m` / `256Mi` |

### `peertube`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `peertube.image.repository` / `.tag` | PeerTube 容器映像檔（`chocobozzz/peertube` 官方映像需要 root 自降權，不能套用 `capabilities.drop: [ALL]`） | `chocobozzz/peertube` / `production-bookworm` |
| `peertube.webserverHostname` | 對外網域，寫進 `PEERTUBE_WEBSERVER_HOSTNAME` 及 HTTPRoute 的 `hostnames`。教學重點：這組 `WEBSERVER_*` 環境變數描述的是「使用者從外部連進來」看到的 scheme/port（走 Gateway 的 443/https），跟容器實際監聽的 port `9000` 是兩個不同概念 | `peertube.nexai.org.com` |
| `peertube.secret` | PeerTube 內部加密 session/cookie 用的密鑰，跟整合密鑰（JWT 之類）無關 | `TrainingOnlyPeertubeSecret_ChangeMeInProduction` |
| `peertube.adminEmail` | 管理員信箱 | `admin@example.com` |
| `peertube.rootPassword` | 初次啟動（資料庫為空時）建立的 root 密碼，**建立後只存雜湊，之後改這裡的值不會生效、也讀不回明文**，務必第一次部署後立刻從開機日誌記下密碼 | `TrainingPeertubeRoot123` |
| `peertube.persistence.storageClassName` / `.size` | 影片/縮圖等資料的 PVC（掛到 `/app/storage`），單寫用 Ceph RBD | `rook-ceph-block` / `10Gi` |
| `peertube.resources.requests.cpu` / `.memory` | PeerTube 容器 requests | `500m` / `1Gi` |
| `peertube.resources.limits.cpu` / `.memory` | PeerTube 容器 limits | `2` / `2Gi` |

### `resourceQuota` / `limitRange`

要同時覆蓋 postgres + redis + peertube 三個 workload 的加總，是全教材
資源需求最高的 namespace 之一。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resourceQuota.enabled` | 是否建立 ResourceQuota | `true` |
| `resourceQuota.requestsCpu` / `.requestsMemory` / `.limitsCpu` / `.limitsMemory` | namespace 加總配額 | `2` / `3Gi` / `4` / `6Gi` |
| `resourceQuota.pods` | 最多 Pod 數 | `6` |
| `resourceQuota.persistentVolumeClaims` | 最多 PVC 數 | `4` |
| `resourceQuota.requestsStorage` | 儲存空間加總配額 | `30Gi` |
| `limitRange.enabled` | 是否建立 LimitRange | `true` |
| `limitRange.default.cpu` / `.memory` | 未填 `limits` 的預設值 | `500m` / `1Gi` |
| `limitRange.defaultRequest.cpu` / `.memory` | 未填 `requests` 的預設值 | `100m` / `256Mi` |
| `limitRange.max.cpu` / `.memory` | 單一容器上限（要 ≥ 三者中 limits 最大者） | `2` / `3Gi` |
| `limitRange.min.cpu` / `.memory` | 單一容器下限（要 ≤ 三者中 requests 最小者，這裡是 redis） | `50m` / `64Mi` |

### `gateway` / `networkPolicy`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `gateway.name` / `.namespace` | HTTPRoute 掛的 Gateway；`hostnames` 直接讀 `peertube.webserverHostname`，不重複填 | `dev-gateway` / `default` |
| `networkPolicy.enabled` | 是否啟用 NetworkPolicy（default-deny + Gateway→PeerTube(9000)、PeerTube→postgres(5432)、PeerTube→redis(6379)、DNS egress；same-namespace podSelector-to-podSelector，規則數是全教材最多的） | `true` |

## 特殊注意事項

- `peertube.rootPassword` 只在首次啟動生效，建立後無法從資料庫復原，
  務必第一次部署後立刻記錄。
- 預設只給 tolerations、不指定節點，部署前先 `kubectl top nodes`
  確認有節點塞得下；排不進去時用
  `--set nodePlacement.nodeSelector."kubernetes\.io/hostname"=gpu01`
  把三個元件一起釘到 `gpu01`。
- `postgres`/`redis`/`peertube.image` 三個官方映像都不能套用
  `capabilities.drop: [ALL]`，是這個產品裡重複驗證過的容器安全模型
  慣例。
