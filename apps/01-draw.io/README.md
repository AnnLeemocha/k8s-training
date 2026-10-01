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

### HPA 施壓實測（2026-09-30）

用 [hpa-busy-job.yaml](hpa-busy-job.yaml) 對 Service 施壓，觀察 HPA 擴容：

```bash
# 終端機 A：觀察
kubectl get hpa drawio -n drawio -w
# 終端機 B：施壓（2 個 Pod × 30 個 curl 迴圈反覆下載 js/app.min.js，300 秒後自動結束）
kubectl apply -f hpa-busy-job.yaml
# 重跑前先刪掉舊 Job；全部測完清理整個 namespace
kubectl delete job hpa-loadgen -n hpa-loadgen
kubectl delete namespace hpa-loadgen
```

**施壓 Job 為什麼要放在獨立的 `hpa-loadgen` namespace**：第一次把 Job
放在 `drawio` namespace 裡跑（30 個 worker、5 分鐘），CPU 只衝到 53%
就掉回 22~25%，完全沒觸發擴容。原因是 Job 沒寫 `resources`，被 drawio
的 LimitRange 套上預設 `cpu limit: 250m`，**施壓端自己被限流**，壓力
送不出去。但也不能直接在 drawio namespace 調高它的 limit，否則會吃掉
drawio 的 ResourceQuota，HPA 要開新 Pod 時反而沒額度。移到獨立
namespace（每個施壓 Pod limit 1 核）後，實測曲線如下：

```text
07:54:08  cpu:   2%/70%  replicas=2   施壓 Pod 開始運作
07:54:23  cpu:  42%/70%  replicas=2
07:54:39  cpu: 109%/70%  replicas=2   超過門檻
07:54:54  cpu: 154%/70%  replicas=4   一次從 2 加到 4
07:55:56  cpu: 111%/70%  replicas=5   HPA 要求加到上限 5
07:56~07:58  cpu: 76~98%              負載分散到更多 Pod
07:58:37                               Job 跑滿 300 秒自動結束
08:00:30  cpu:   2%/70%  replicas=5   CPU 已回落，縮容要等約 5 分鐘冷卻
```

**第 5 個 Pod 其實建不起來**：HPA 把 replicas 設成 5，但 Deployment
一直停在 `4/5`，Events 出現：

```text
FailedCreate ... exceeded quota: drawio-quota, requested: limits.cpu=500m,
limits.memory=512Mi,requests.memory=256Mi, used: limits.cpu=2,limits.memory=2Gi,
requests.memory=1Gi
```

ResourceQuota 在**建立 Pod 當下**檢查「已用量 + 新 Pod 需求」，requests
和 limits 都算，任何一項超過就直接拒絕，Pod 不會出現在 `kubectl get pods`：

| Quota 項目 | 上限 | 4 個 Pod 已用 | 第 5 個再加 | 結果 |
|---|---|---|---|---|
| requests.cpu | 1 | 400m | +100m → 500m | ✅ 還夠 |
| requests.memory | 1Gi | 1Gi | +256Mi → 1.25Gi | ❌ 超過 |
| limits.cpu | 2 | 2 | +500m → 2.5 | ❌ 超過 |
| limits.memory | 2Gi | 2Gi | +512Mi → 2.5Gi | ❌ 超過 |

也就是說，目前的 Quota 只容得下 4 個 Pod，`05-hpa.yaml` 的
`maxReplicas: 5` 實際上到不了。**這裡刻意保留不修**，當作課堂教材：

- HPA 只負責改 Deployment 的 replicas 數字，不保證 Pod 真的建得出來；
  ReplicaSet 會一直重試、一直 `FailedCreate`，直到 replicas 降回 4 以下。
- 「HPA 上限 × 每個 Pod 的 requests/limits」必須小於等於 ResourceQuota，
  三者要一起算。
- 分辨兩種「新 Pod 起不來」：**沒有 Pod** + `FailedCreate: exceeded quota`
  是 namespace 配額問題（看 ReplicaSet/namespace Events）；**有 Pod 但一直
  `Pending`** + `Insufficient cpu/memory` 是節點容量問題（看
  `kubectl describe pod`）。

排查指令：

```bash
kubectl get deploy drawio -n drawio                  # READY 4/5
kubectl get resourcequota -n drawio                  # 看哪幾項已經滿了
kubectl get events -n drawio --field-selector reason=FailedCreate
```

想讓它真的擴到 5 個，Quota 至少要 `requests.memory ≥ 1280Mi`、
`limits.cpu ≥ 2500m`、`limits.memory ≥ 2560Mi`；或者把 `maxReplicas`
改成 4，讓設定跟實際一致。可以留給學員當練習題。

### 清除環境

```bash
kubectl delete namespace drawio
kubectl delete namespace hpa-loadgen   # 若有跑過 HPA 施壓測試
```
