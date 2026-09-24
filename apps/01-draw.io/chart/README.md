# draw.io Helm Chart

用 Helm 部署 [draw.io (diagrams.net)](https://github.com/jgraph/drawio)，全教材唯一啟用
HPA 的產品，也是純無狀態、不需要任何 PVC 的基礎範例。對應的純 yaml
教學版本見 [`../manifest/`](../manifest/)，兩者內容應保持一致。

Chart 建立的資源（`templates/`）：Deployment、Service、HTTPRoute、
HorizontalPodAutoscaler、NetworkPolicy、ResourceQuota + LimitRange。
**不包含 Namespace**——請先手動建立或套用
[`../manifest/00-namespace.yaml`](../manifest/00-namespace.yaml)。

## 安裝

```bash
kubectl apply -f ../manifest/00-namespace.yaml
helm install drawio . -n drawio

# 預覽渲染結果（不會真的送進叢集）
helm template drawio . -n drawio

# 調整參數示範
helm upgrade drawio . -n drawio --set replicaCount=3

# 移除
helm uninstall drawio -n drawio
```

## Values 參數

### 基本設定

| 參數 | 說明 | 預設值 |
|---|---|---|
| `replicaCount` | Deployment 初始副本數；因為啟用了 HPA，實際數量會在 `hpa.minReplicas`~`hpa.maxReplicas` 間動態調整 | `2` |
| `image.repository` | 容器映像檔 repository | `jgraph/drawio` |
| `image.tag` | 映像檔 tag | `24.7.17` |
| `image.pullPolicy` | 映像檔拉取策略 | `IfNotPresent` |
| `containerPort` | 容器監聽 port，同時是 probe port、NetworkPolicy 放行的 port | `8080` |

### `resources` — 單一容器資源請求/上限

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resources.requests.cpu` | 平常穩定執行所需 CPU | `100m` |
| `resources.requests.memory` | 平常穩定執行所需記憶體 | `256Mi` |
| `resources.limits.cpu` | 尖峰時最多可用 CPU（可壓縮資源，緩衝可抓寬） | `500m` |
| `resources.limits.memory` | 尖峰時最多可用記憶體（不可壓縮，超過會 OOMKilled） | `512Mi` |

必須落在 `limitRange.min`~`limitRange.max` 之間；判斷方法見
[`../../docs/resources/README.md`](../../docs/resources/README.md)。

### `resourceQuota` — Namespace 總量配額

| 參數 | 說明 | 預設值 |
|---|---|---|
| `resourceQuota.enabled` | 是否建立 ResourceQuota | `true` |
| `resourceQuota.requestsCpu` | namespace 內所有 Pod 的 requests.cpu 加總上限 | `1` |
| `resourceQuota.requestsMemory` | requests.memory 加總上限 | `1Gi` |
| `resourceQuota.limitsCpu` | limits.cpu 加總上限 | `2` |
| `resourceQuota.limitsMemory` | limits.memory 加總上限 | `2Gi` |
| `resourceQuota.pods` | 最多可建立的 Pod 數（要留給 HPA 擴到 `maxReplicas` 的空間） | `10` |

### `limitRange` — 單一容器的地板/天花板

| 參數 | 說明 | 預設值 |
|---|---|---|
| `limitRange.enabled` | 是否建立 LimitRange | `true` |
| `limitRange.default.cpu` / `.memory` | 沒填 `limits` 時的自動預設值 | `250m` / `256Mi` |
| `limitRange.defaultRequest.cpu` / `.memory` | 沒填 `requests` 時的自動預設值 | `100m` / `128Mi` |
| `limitRange.max.cpu` / `.memory` | 單一容器 `limits` 上限，必須 ≥ `resources.limits` | `1` / `1Gi` |
| `limitRange.min.cpu` / `.memory` | 單一容器 `requests` 下限，必須 ≤ `resources.requests` | `50m` / `64Mi` |

### `service` / `gateway` / `hostnames` — 對外曝露

| 參數 | 說明 | 預設值 |
|---|---|---|
| `service.port` | ClusterIP Service 對外 port，轉給 `containerPort` | `80` |
| `gateway.name` | HTTPRoute 掛的 Gateway 名稱（本叢集用 Gateway API 取代 Ingress） | `dev-gateway` |
| `gateway.namespace` | 該 Gateway 所在的 namespace | `default` |
| `gateway.sectionNames` | 要掛上 Gateway 的哪些 listener | `[http, https]` |
| `hostnames` | HTTPRoute 比對 Host header 用的網域 | `[drawio.nexai.org.com]` |

### `hpa` — 水平自動擴縮

| 參數 | 說明 | 預設值 |
|---|---|---|
| `hpa.enabled` | 是否建立 HPA；關掉則改回固定 `replicaCount` | `true` |
| `hpa.minReplicas` | 最少副本數 | `2` |
| `hpa.maxReplicas` | 最多副本數 | `5` |
| `hpa.targetCPUUtilizationPercentage` | 以 `resources.requests.cpu` 為基準的目標使用率 | `70` |

### `networkPolicy`

| 參數 | 說明 | 預設值 |
|---|---|---|
| `networkPolicy.enabled` | 是否啟用 NetworkPolicy（default-deny + 開放 Gateway 進來的流量與 DNS egress） | `true` |

## 特殊注意事項

- Namespace 不由這個 chart 建立，避免 Helm 對 Namespace 資源的
  ownership 判定問題。
- 這是全教材唯一有 HPA 的產品；調高 `hpa.maxReplicas` 前，記得同步檢查
  `resourceQuota` 是否有留夠空間，方法見
  [`../../docs/resources/README.md`](../../docs/resources/README.md)。
- `hostnames` 需要 DNS 或學員筆電的 hosts 檔指向 `dev-gateway` 的
  EXTERNAL-IP 才能連線。
