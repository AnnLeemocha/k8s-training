# onlyoffice Helm Chart

用 Helm 部署 [ONLYOFFICE Document Server](https://github.com/ONLYOFFICE/DocumentServer)，
用官方「bundled-everything」映像（內建 Postgres/Redis/RabbitMQ），
刻意不拆外部資料庫。全教材最重的產品，也是唯一需要釘死在 GPU 節點才有
足夠記憶體的產品。對應的純 yaml 教學版本見
[`../manifest/`](../manifest/)。

Chart 建立的資源（`templates/`）：Deployment、Service、HTTPRoute、
PVC、Secret、NetworkPolicy、ResourceQuota + LimitRange。**不包含
Namespace**——請先手動建立或套用
[`../manifest/00-namespace.yaml`](../manifest/00-namespace.yaml)。

## 安裝

```bash
kubectl apply -f ../manifest/00-namespace.yaml
helm install onlyoffice . -n onlyoffice
helm template onlyoffice . -n onlyoffice   # 預覽渲染結果
helm uninstall onlyoffice -n onlyoffice
```

## Values 參數

### 基本設定

| 參數 | 說明 | 預設值 |
|---|---|---|
| `image.repository` / `image.tag` / `image.pullPolicy` | Document Server 容器映像檔 | `onlyoffice/documentserver` / `latest` / `IfNotPresent` |

### `jwt` — JWT 驗證設定

| 參數 | 說明 | 預設值 |
|---|---|---|
| `jwt.enabled` | 是否啟用 JWT 驗證（建議正式使用一定要開） | `true` |
| `jwt.secret` | JWT 共用密鑰，**必須跟 `../filebrowser/chart` 的 `onlyoffice.secret` 逐字一致**，否則雙方互相驗證會失敗 | `TrainingOnlyofficeJwtSecret_ChangeMe` |

### `pluginsEnabled`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `pluginsEnabled` | 對應 `PLUGINS_ENABLED` 環境變數。本叢集 NetworkPolicy 預設 deny 出網流量，若不關掉，官方內建的 `pluginsmanager` 行程會一直重試連 github.com 抓外掛，被擋住後在受限網路下無限重試，白白吃掉將近一整個 CPU core（已在真實叢集踩過這個坑） | `false` |

### `resources`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resources.requests.cpu` / `.memory` | 容器 requests（實測拿掉 `pluginsmanager` CPU-loop 問題後，穩定狀態約 400-500Mi 記憶體，這裡抓貼近實測用量） | `1` / `2Gi` |
| `resources.limits.cpu` / `.memory` | 容器 limits（保留官方建議的 2 CPU/4Gi 最低需求作為上限） | `2` / `4Gi` |

### `resourceQuota` / `limitRange`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resourceQuota.enabled` | 是否建立 ResourceQuota | `true` |
| `resourceQuota.requestsCpu` / `.requestsMemory` / `.limitsCpu` / `.limitsMemory` | namespace 加總配額 | `2` / `3Gi` / `4` / `6Gi` |
| `resourceQuota.pods` | 最多 Pod 數 | `3` |
| `resourceQuota.persistentVolumeClaims` | 最多 PVC 數 | `4` |
| `resourceQuota.requestsStorage` | 儲存空間加總配額 | `20Gi` |
| `limitRange.enabled` | 是否建立 LimitRange | `true` |
| `limitRange.default.cpu` / `.memory` | 未填 `limits` 的預設值 | `2` / `4Gi` |
| `limitRange.defaultRequest.cpu` / `.memory` | 未填 `requests` 的預設值 | `1` / `2Gi` |
| `limitRange.max.cpu` / `.memory` | 單一容器上限 | `4` / `6Gi` |
| `limitRange.min.cpu` / `.memory` | 單一容器下限 | `250m` / `512Mi` |

### `persistence`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `persistence.storageClassName` / `.size` | 唯一持久化的 PVC（掛到 `/var/www/onlyoffice/Data`）；log/cache 用 emptyDir 即可。內建的 Postgres/Redis/RabbitMQ 資料目錄刻意不持久化——路徑跟映像版本綁得很緊，且叢集記憶體吃緊，額外跑外部服務被判斷超出範圍 | `rook-ceph-block` / `5Gi` |

### `nodePlacement`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `nodePlacement.nodeSelector` | 把 Pod 釘死在 `gpu01` 節點——`k8s01~03` 記憶體長期在 81-91% 使用率，扛不住這個產品的 requests | `kubernetes.io/hostname: gpu01` |
| `nodePlacement.tolerations` | 對應 `gpu01` 的 `nvidia.com/gpu=true:NoSchedule` taint | `[{key: nvidia.com/gpu, operator: Equal, value: "true", effect: NoSchedule}]` |

### `service` / `gateway` / `hostnames` / `networkPolicy`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `service.port` | ClusterIP Service 對外 port | `80` |
| `gateway.name` / `.namespace` / `.sectionNames` | HTTPRoute 掛的 Gateway | `dev-gateway` / `default` / `[http, https]` |
| `hostnames` | HTTPRoute 比對 Host header 用的網域 | `[onlyoffice.nexai.org.com]` |
| `networkPolicy.enabled` | 是否啟用 NetworkPolicy（default-deny + 放行 Gateway 進來、DNS egress、對 `filebrowserNamespace` 的 egress） | `true` |
| `networkPolicy.filebrowserNamespace` | filebrowser 所在的 namespace 名稱——Document Server 要主動連回 filebrowser 抓檔案/回報存檔結果 | `filebrowser` |

## 特殊注意事項

- `jwt.secret` 必須跟 [`../filebrowser`](../../filebrowser/) 產品的
  `onlyoffice.secret` 逐字一致；兩邊各自獨立部署，改動時要記得同步。
- 這是唯一需要 `nodePlacement` 才排得進去的產品之一（跟 peertube
  一樣），部署前先 `kubectl top nodes` 確認 `gpu01` 還有空間。
- `pluginsEnabled: false` 是實測踩坑後的修正，不要因為「看起來像進階
  功能」而改回 `true`，除非已確認 NetworkPolicy 允許出網。
