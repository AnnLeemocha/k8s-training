# draw.io (Diagrams.net)

開源的圖表繪製工具，可用於繪製架構圖、流程圖、心智圖等。

## K8s 教育訓練用途

無狀態應用，不需要 PVC、不需要資料庫，是整個課程的第一個範例，
用來介紹 Namespace / ResourceQuota / LimitRange / Deployment / Service /
Gateway API（HTTPRoute）/ HPA / NetworkPolicy 等基礎與進階概念。

提供三種形式，教學情境不同，選一種或搭配使用：

| 目錄/檔案 | 用途 |
|---|---|
| [manifest/](manifest/) | **教學主線**：拆成 7 支編號檔案，一支一支 apply，逐步講解每個資源的作用 |
| [drawio-all-in-one.yaml](drawio-all-in-one.yaml) | 內容與 manifest/ 完全一致的合併版，教完拆解版後快速重建環境，或 demo 用 |
| [chart/](chart/) | Helm Chart 版本，教完純 yaml 後，用同一個產品講解「Helm 把重複設定樣板化」的概念 |
| [exercises/](exercises/) | **學員練習**：半成品 YAML 填空 + 埋錯除錯兩種題型，含架構圖、提示與驗收標準，`manifest/` 就是這些題目的正解 |

**前置條件（三種形式都要先做）**：先套用共用的教學 Gateway
（一次即可，之後每個產品都共用同一個）：

```bash
kubectl apply -f ../shared-infra/00-dev-gateway.yaml
```

### 方式一：教學主線（依編號逐步 apply）

```bash
kubectl apply -f manifest/00-namespace.yaml
kubectl apply -f manifest/01-resourcequota-limitrange.yaml
kubectl apply -f manifest/02-deployment.yaml
kubectl apply -f manifest/03-service.yaml
kubectl apply -f manifest/04-httproute.yaml
kubectl apply -f manifest/05-hpa.yaml
kubectl apply -f manifest/06-networkpolicy.yaml   # 進階、選用，上課前請先自行驗證
```

### 方式二：合併版一次套用

```bash
kubectl apply -f drawio-all-in-one.yaml
```

### 方式三：Helm Chart

Namespace 不由 chart 建立（避免 Helm 對 Namespace 資源的 ownership 問題），
先建立 namespace 再安裝：

```bash
kubectl apply -f manifest/00-namespace.yaml
helm install drawio ./chart -n drawio
# 調整參數示範：helm upgrade drawio ./chart -n drawio --set replicaCount=3
# 預覽渲染結果：helm template drawio ./chart -n drawio
# 移除：helm uninstall drawio -n drawio
```

### 上課前請先確認 / 調整

- `04-httproute.yaml`（以及 chart 的 `values.yaml`）的 `hostnames`
  目前填的是 `drawio.nexai.org.com`，沿用叢集現有服務（rancher / ceph
  dashboard 等）的網域慣例，請依實際可用網域調整，並確保 DNS 或學員
  筆電的 hosts 檔指向 `dev-gateway` 的 EXTERNAL-IP
  （`kubectl get gateway dev-gateway -n default` 查詢）。
- 這座叢集用 **Gateway API（Cilium）**，不是傳統 Ingress／ingress-nginx，
  適合藉此讓學員理解新舊兩種對外曝露服務的方式差異。
- HTTPRoute 掛的是教學專屬的 `dev-gateway`，不是正式環境的
  `app-gateway`/`admin-gateway`，詳見 [../shared-infra/README.md](../shared-infra/README.md)。
- `06-networkpolicy.yaml`（或 chart 的 NetworkPolicy 樣板）標記為選用，
  正式上課前請先實測連線是否正常，避免當場示範時網路被擋。

### 驗證與教學觀察點

```bash
kubectl get pods -n drawio -w              # 觀察 Pod 從 Pending -> Running
kubectl get deploy,rs,pod -n drawio        # Deployment/ReplicaSet/Pod 的關聯
kubectl describe httproute drawio -n drawio
kubectl get hpa -n drawio -w               # 施加負載後觀察 replicas 變化
```

### 清除環境

```bash
kubectl delete namespace drawio
```
