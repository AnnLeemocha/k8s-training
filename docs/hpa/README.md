# HPA 教學文件：水平自動擴縮怎麼設、怎麼驗證

這份文件教「HPA 是什麼、怎麼設定、本教材唯一的範例（draw.io）怎麼運作」，
搭配 [`apps/01-draw.io/manifest/05-hpa.yaml`](../../apps/01-draw.io/manifest/05-hpa.yaml)
的逐行教學註解一起看效果最好——這裡講通用概念跟一次真實觸發的
scale-up/scale-down 過程，該檔案負責講「這個產品自己的參數」。

## 目錄

1. [HPA 在這門課的定位](#1-hpa-在這門課的定位)
2. [核心概念](#2-核心概念)
3. [為什麼全教材只有 draw.io 有 HPA](#3-為什麼全教材只有-drawio-有-hpa)
4. [實測驗證：真的會自動擴縮嗎？](#4-實測驗證真的會自動擴縮嗎)
5. [常見錯誤與除錯](#5-常見錯誤與除錯)
6. [練習題](#6-練習題)

---

## 1. HPA 在這門課的定位

HPA（HorizontalPodAutoscaler）解決的是「流量會變動，但沒人隨時盯著手動
調整 replicas」的問題：根據即時觀察到的指標（本教材只用最基本的 CPU
使用率），在 `minReplicas`～`maxReplicas` 之間動態調整 Deployment 的
replicas 數。這跟 [docs/resources](../resources/) 教的「怎麼抓
requests/limits」是同一組問題的兩個層面——**先**用 docs/resources 的
方法抓出「單一 Pod 的容量邊界」，**再**用這裡的 HPA 把「同時要幾個
Pod」這件事自動化，兩份文件建議搭配著看。

## 2. 核心概念

### 需要 metrics-server

HPA（用 CPU/Memory 這類 resource metrics 時）依賴叢集裝好
`metrics-server`，沒有它 `kubectl top pod`/HPA 都拿不到即時使用率資料。
本叢集已確認裝好且可用（`kubectl top pod` 全教材都能正常回應）。

### `averageUtilization` 是跟「這個容器的 `requests`」比，不是跟節點比

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

這是最容易搞錯的地方：`70` 代表「所有符合 `scaleTargetRef` 的 Pod，平均
CPU 使用率達到**這個容器 `resources.requests.cpu` 的 70%**」，不是達到
節點總 CPU 的 70%，也不是達到 `limits` 的 70%。這表示 **HPA 的行為完全
取決於 `requests` 設得準不準**——`requests` 設得太低，HPA 會在 Pod 其實
還很閒的時候就誤判過熱而擴容；設得太高，會等到 Pod 真的快撐不住才觸發，
兩種都不理想，這也是為什麼 [docs/resources](../resources/) 的實測方法
建議在調 HPA 之前先把 `requests` 量準。

### `minReplicas`/`maxReplicas`：下限跟天花板

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: drawio
  minReplicas: 2
  maxReplicas: 5
```

HPA 接管之後，Deployment 自己原本寫的 `replicas: 2` 只是「初始值」，
真正生效的下限變成 HPA 的 `minReplicas`；`maxReplicas` 則是無論流量多高
都不會超過的天花板，避免 HPA 把 `ResourceQuota` 一次吃光——調高
`maxReplicas` 前，[docs/resources 第 24 節「加一個 replica，到底要改什麼」
](../resources/README.md#加一個-replica到底要改什麼) 那份檢查清單完全
適用。

### 沒有明講的 `behavior`：預設值本身就是一種設計決策

draw.io 的 [`05-hpa.yaml`](../../apps/01-draw.io/manifest/05-hpa.yaml)
沒有寫 `spec.behavior`，代表用的是 K8s 內建預設值，這不是疏漏，而是
「先用預設值教會學員基本行為，之後再教怎麼客製化」的教學順序：

| | 預設行為 | 白話意思 |
|---|---|---|
| Scale **up** | `stabilizationWindowSeconds: 0`（不等待） | 一偵測到超標就立刻加 Pod，不會刻意拖延——本教材寧可讓使用者晚一點感受到擴容前的短暫壓力，也不要讓 HPA 對真正的尖峰反應遲鈍 |
| Scale **down** | `stabilizationWindowSeconds: 300`（預設 5 分鐘） | 縮容前會先觀察過去 5 分鐘內出現過的**最高**建議 replicas 數，取那個當縮容依據，避免流量剛降一下就立刻砍 Pod、下一秒流量又回來要重新啟動的「震盪（flapping）」 |

這也是為什麼下一節「觀察 scale-down」永遠比「觀察 scale-up」慢很多——
不是系統反應慢，是預設就刻意設計成保守。

## 3. 為什麼全教材只有 draw.io 有 HPA

見根目錄 `README.md` 的產品對照表：6 個產品的「HPA」欄位都是「無」。
不是忘記加，是每個產品各自有不適合的理由，對照著看很有教學價值：

| 產品 | 沒有 HPA 的理由 |
|---|---|
| filebrowser | `replicas: 1` + `Recreate`，因為背後是 sqlite（單一寫入者），本來就不能開多個 replica，HPA 對這種架構沒有意義 |
| flarum / planka / peertube | 應用程式本身用 Deployment 沒問題，但都搭配同 namespace 的 StatefulSet（mysql/postgres），資料庫本身不適合水平擴縮；應用層要加 HPA 在架構上是可行的，只是教材選擇把「HPA」這個教學重點集中在 draw.io 一個地方，其餘產品把篇幅留給各自的獨有主題（initContainer、跨 namespace 依賴…） |
| onlyoffice / peertube | 已經是全教材資源最吃緊的兩個產品（見根目錄 README 的節點資源記憶），平常就可能被排到 `gpu01` 這類較空的節點，多開 replica 前要先確認節點/配額都夠，教學上風險比效益高 |
| cloudbeaver | 單純的用戶端角色，流量模式（DB 管理操作）本來就不是「使用者尖峰」型態，沒有自動擴縮的實務需求 |

draw.io 適合當唯一範例，正是因為它**無狀態、無外部依賴**（純前端 SPA，
沒有資料庫、沒有需要保序的 session），是全教材架構最單純、最適合示範
「加一個 Pod 就是加一份容量」這個 HPA 核心假設的產品——這個假設在有狀態
服務上通常不成立，也是教學上刻意的對照。

## 4. 實測驗證：真的會自動擴縮嗎？

### 4.1 先用 docs/resources 的既有工具量出容量邊界（2026-09-23 實測）

[docs/resources/run-load-test.sh](../resources/README.md) 是本教材既有、
專門用來量測「單一 Pod 容量邊界」的工具，執行時會**先暫停 HPA、把
replicas 暫時縮到 1**（避免 HPA 中途加開 Pod 稀釋掉測出來的邊界），結束
後自動還原：

```bash
cd docs/resources
./run-load-test.sh drawio drawio drawio drawio.nexai.org.com
```

只打 `/`（12.7KB 的靜態外殼，見 docs/resources 第 9 節）時，實測即使
併發到 60 個 VU，單一 Pod 的 CPU 使用量仍然只有 **23m**（`requests.cpu`
是 100m 的 23%，離 HPA 的 70% 門檻還很遠）——這印證了 docs/resources
文件強調的重點：**只測 `/` 會嚴重低估真實負載**，同一份腳本帶上
`EXTRA_ASSET_PATHS`（draw.io 真正的 JS/CSS 應用程式本體，合計約 21MB）
才會量到有意義的 CPU 使用率跟真正的容量邊界。這也解釋了為什麼下一節
「觀察 HPA 真的 scale-up」刻意改用直接對 Service 施壓真實資源檔案的
方式，而不是只打首頁。

### 4.2 在 HPA 保持運作的狀態下，實際觀察 CPU 使用率爬升

跟 4.1 不同，這裡的目的是看 **HPA 自己**怎麼反應，所以不能像
`run-load-test.sh` 一樣先把它暫停——做法是維持 HPA 正常運作、對
Service 直接發送一段時間的併發請求（打真正會耗 CPU 的資源檔案，不是
`/`），全程用 `kubectl get hpa -n drawio -w` 觀察 `TARGETS`/`REPLICAS`
欄位即時變化。2026-09-23 用一個 90 秒、10 個併發 worker 反覆下載
`js/app.min.js` 的 Job（跟 docs/resources 的施壓手法同一類，只是規模
小很多）實測到的真實曲線：

```text
11:36:37   cpu: 2%/70%    REPLICAS: 2   （施壓開始前，閒置基準線）
11:36:57   cpu: 7%/70%    REPLICAS: 2
11:37:07   cpu: 64%/70%   REPLICAS: 2   （最接近門檻的一刻，但仍在 70% 以下）
11:37:23   cpu: 43%/70%   REPLICAS: 2   （Job 已跑完 90 秒 deadline，流量開始退散）
11:37:38   cpu: 41%/70%   REPLICAS: 2
11:37:53   cpu: 34%/70%   REPLICAS: 2   （持續回落）
```

**這次實測沒有真的撞過 70%、觸發 scale-up**——10 個併發 worker 撐出的
峰值是 64%，離門檻只差一點點，但 Job 本身的 90 秒時間窗在爬到峰值後就
結束了，流量退散的速度比再往上爬的速度快。這其實是很真實的教學素材：
**「有沒有觸發 HPA」對負載強度/持續時間非常敏感**，跟 4.1 的容量邊界
測試一樣，同一個目標、同一組門檻，換一種施壓的併發數/持續時間就可能得到
不同結果。想在課堂上真的看到 replicas 從 2 增加，把併發 worker 數（或
每個 worker 內迴圈次數，讓施壓時間拉長）往上加即可，例如：

```bash
# 15 個併發 worker、每個下載 1000 次，deadline 拉到 150 秒
# （用 Job 而不是裸 Pod：跑完/逾時都會自動結束，不會遺留在叢集上）
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: hpa-demo-briefload
  namespace: drawio
spec:
  activeDeadlineSeconds: 150
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: curl
          image: curlimages/curl:latest
          command:
            - sh
            - -c
            - |
              for i in $(seq 1 15); do
                (for j in $(seq 1 1000); do curl -s -o /dev/null http://drawio.drawio.svc.cluster.local/js/app.min.js; done) &
              done
              wait
EOF
# 觀察（開另一個終端機）：
kubectl get hpa drawio -n drawio -w
# 測完清理：
kubectl delete job hpa-demo-briefload -n drawio
```

一旦 `TARGETS` 真的超過 `70%`，會在**下一次 HPA 輪詢**（預設每 15 秒
一次）就看到 `REPLICAS` 立刻從 2 增加（見第 2 節：scale-up 預設沒有
stabilization window，偵測到就立刻加 Pod）；停止施壓後，`REPLICAS`
則要等 CPU 使用率過去 5 分鐘的**最高**建議值都降下來才會開始減少
（同樣見第 2 節），這也是為什麼 4.1 的容量邊界測試工具會選擇「暫停
HPA、手動控制 replicas」的做法——如果不暫停，HPA 自己的 scale-up 會在
測容量邊界的過程中把負載分攤到更多 Pod，量到的就不是「單一 Pod」的
邊界了，兩種測試方法（4.1 測邊界、4.2 看 HPA 反應）目的不同，不能
混著做。

## 5. 常見錯誤與除錯

| 現象 | 常見原因 | 排查方式 |
|---|---|---|
| HPA 的 `TARGETS` 欄位一直顯示 `<unknown>/70%` | metrics-server 還沒抓到資料（Pod 剛啟動、或 metrics-server 本身有問題） | `kubectl top pod -n <ns>` 能不能正常回應數字；再等 15~30 秒讓 metrics 管線跑起來 |
| 流量明明很高，replicas 卻不會超過某個數字 | 撞到 `maxReplicas` 天花板 | `kubectl get hpa -n <ns>` 看 `MAXPODS`，需要調高就照 [docs/resources 的「加一個 replica，到底要改什麼」](../resources/README.md#加一個-replica到底要改什麼) 檢查 ResourceQuota/節點容量 |
| 新開的 Pod 一直 `Pending` | ResourceQuota 或節點容量不夠（見上一列連結） | `kubectl describe pod` 看 Events，`FailedCreate: exceeded quota` 是配額問題，`Insufficient cpu/memory` 是節點問題，兩者原因不同 |
| replicas 頻繁上上下下（flapping） | scale-up 預設沒有 stabilization window，流量本身就在忽高忽低 | 考慮在 `spec.behavior.scaleUp` 也加上 `stabilizationWindowSeconds`，或改善 `averageUtilization` 門檻/`requests` 設得更準 |
| 流量已經降下來很久，replicas 還是沒有變少 | 預設 scale-down 有 5 分鐘 stabilization window（見第 2 節），是設計行為不是 bug | 耐心等滿 5 分鐘；教學展示時間有限的話，可以提前說明這是刻意的保守設計 |

## 6. 練習題

1. 把 `averageUtilization` 從 70 調成 30，重新跑一次 4.2 的施壓流程，
   觀察 scale-up 觸發得更早、需要的併發量更小。
2. 幫 `spec` 加上 `behavior.scaleUp.stabilizationWindowSeconds: 60`，
   驗證 scale-up 是不是真的比預設（0 秒）慢了大約 1 分鐘才發生。
3. 對照 `docs/resources` 的公式，假設「預期尖峰同時在線使用者數」改成
   500 人，重新算一次 draw.io 的 `maxReplicas` 建議值，並檢查目前的
   `ResourceQuota` 夠不夠撐到那個 `maxReplicas`。
