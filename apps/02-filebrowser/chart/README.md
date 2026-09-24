# filebrowser（FileBrowser Quantum）Helm Chart

用 Helm 部署 [FileBrowser Quantum](https://github.com/gtstef/filebrowser)，全教材第一個
「有狀態」產品：兩個 PVC 分別示範 RWX（多 Pod 共享檔案）跟 RWO（單寫
sqlite 資料庫），單一副本也是「不裝 HPA」的對照組。本產品已從官方
`filebrowser/filebrowser`（2026-09-01 封存）遷移到 FileBrowser
Quantum，詳見 [`../README.md`](../README.md)。對應的純 yaml 教學版本見
[`../manifest/`](../manifest/)。

Chart 建立的資源（`templates/`）：Deployment、Service、HTTPRoute、
ConfigMap、2 個 PVC、NetworkPolicy、ResourceQuota + LimitRange。
**不包含 Namespace**——請先手動建立或套用
[`../manifest/00-namespace.yaml`](../manifest/00-namespace.yaml)。

## 安裝

```bash
kubectl apply -f ../manifest/00-namespace.yaml
helm install filebrowser . -n filebrowser
helm template filebrowser . -n filebrowser   # 預覽渲染結果
helm uninstall filebrowser -n filebrowser
```

## Values 參數

### 基本設定

| 參數 | 說明 | 預設值 |
|---|---|---|
| `replicaCount` | Deployment 副本數，固定 `1`：sqlite 不支援多寫入者，RWO 的 db PVC 也無法同時掛給兩個 Pod，所以不做 HPA | `1` |
| `image.repository` / `image.tag` / `image.pullPolicy` | 容器映像檔 | `gtstef/filebrowser` / `1.5.6-stable` / `IfNotPresent` |
| `containerPort` | 容器監聽 port，同時是探測 port、NetworkPolicy 放行的 port，也寫入 `config.yaml` 的 `server.port` | `80` |

### `config` — FileBrowser 設定

FileBrowser Quantum 用 `config.yaml`（由 `templates/configmap.yaml` 產生）
取代舊版的 `FB_ROOT`/`FB_DATABASE` 環境變數，這裡只暴露教學上常需要
調整的欄位，其餘沿用 template 裡寫死的官方預設值。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `config.adminUsername` | 初次啟動建立的管理員帳號 | `admin` |
| `config.adminPassword` | 初次啟動建立的管理員密碼（**預設帳密務必在上課/正式使用前更改**） | `admin` |

### `onlyoffice` — 跨產品整合設定

讓 filebrowser 內可以直接開啟/編輯 Office 文件，寫進
`templates/configmap.yaml` 的 `config.yaml`。

| 參數 | 說明 | 預設值 |
|---|---|---|
| `onlyoffice.namespace` | onlyoffice 產品所在的 namespace，同時被 `templates/networkpolicy.yaml` 用來組 egress 規則 | `onlyoffice` |
| `onlyoffice.url` | 使用者瀏覽器載入 Document Server 的位址（走 Gateway 對外網域） | `http://onlyoffice.nexai.org.com` |
| `onlyoffice.internalUrl` | filebrowser 後端呼叫 Document Server 用的叢集內部 Service DNS | `http://onlyoffice.onlyoffice.svc.cluster.local` |
| `onlyoffice.secret` | JWT 共用密鑰，**必須跟 `../onlyoffice/chart` 的 `jwt.secret` 逐字一致**，否則雙方互相驗證會失敗 | `TrainingOnlyofficeJwtSecret_ChangeMe` |

### `resources` / `resourceQuota` / `limitRange`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resources.requests.cpu` / `.memory` | 容器 requests | `50m` / `64Mi` |
| `resources.limits.cpu` / `.memory` | 容器 limits | `200m` / `256Mi` |
| `resourceQuota.enabled` | 是否建立 ResourceQuota | `true` |
| `resourceQuota.requestsCpu` / `.requestsMemory` / `.limitsCpu` / `.limitsMemory` | namespace 加總配額 | `500m` / `512Mi` / `1` / `1Gi` |
| `resourceQuota.pods` | 最多 Pod 數 | `5` |
| `resourceQuota.persistentVolumeClaims` | 最多 PVC 數（要覆蓋下面 `persistence` 兩個 PVC） | `4` |
| `resourceQuota.requestsStorage` | 儲存空間加總配額 | `20Gi` |
| `limitRange.enabled` | 是否建立 LimitRange | `true` |
| `limitRange.default.cpu` / `.memory` | 未填 `limits` 的預設值 | `200m` / `256Mi` |
| `limitRange.defaultRequest.cpu` / `.memory` | 未填 `requests` 的預設值 | `50m` / `64Mi` |
| `limitRange.max.cpu` / `.memory` | 單一容器上限 | `500m` / `512Mi` |
| `limitRange.min.cpu` / `.memory` | 單一容器下限 | `25m` / `32Mi` |

### `persistence` — 兩個 PVC

| 參數 | 說明 | 預設值 |
|---|---|---|
| `persistence.srv.storageClassName` | 實際檔案存放區（掛到 `/srv`），多 Pod 共享讀寫用 CephFS | `rook-cephfs` |
| `persistence.srv.accessMode` | 存取模式 | `ReadWriteMany` |
| `persistence.srv.size` | 容量 | `10Gi` |
| `persistence.db.storageClassName` | filebrowser 自己的 sqlite db（掛到 `/database`），單寫用 Ceph RBD | `rook-ceph-block` |
| `persistence.db.accessMode` | 存取模式 | `ReadWriteOnce` |
| `persistence.db.size` | 容量 | `1Gi` |

本叢集沒有 default StorageClass，`storageClassName` 必須明確指定。

### `service` / `gateway` / `hostnames` / `networkPolicy`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `service.port` | ClusterIP Service 對外 port | `80` |
| `gateway.name` / `.namespace` / `.sectionNames` | HTTPRoute 掛的 Gateway | `dev-gateway` / `default` / `[http, https]` |
| `hostnames` | HTTPRoute 比對 Host header 用的網域 | `[filebrowser.nexai.org.com]` |
| `networkPolicy.enabled` | 是否啟用 NetworkPolicy（default-deny + 放行 Gateway 進來、DNS egress、與 `onlyoffice.namespace` 之間的 egress） | `true` |

## 特殊注意事項

- 預設管理員帳密是 `admin`/`admin`，正式上課前務必提醒學員登入後立刻改密碼。
- `onlyoffice.secret` 必須跟 [`../onlyoffice`](../../onlyoffice/) 產品的
  `jwt.secret` 逐字一致；兩邊各自獨立部署，改動時要記得同步。
- 兩個 PVC 的 StorageClass 選擇是本產品的教學重點：檔案用 RWX
  （CephFS），資料庫用 RWO（Ceph RBD），資源判斷方法見
  [`../../docs/resources/README.md`](../../docs/resources/README.md)。
