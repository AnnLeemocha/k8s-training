# 資源 (Resources) 該給多少？判斷方法 + k6 實測工具

這份文件是給所有產品共用的「資源判斷方法」通用參考，兩種方法互補使用：

- **方法一：理論估算** —— 部署前，靠官方建議值 + 資源分層規則推算一個起手值。
- **方法二：k6 實測驗證** —— 部署後，用真實負載測出「這個 Pod 實際會用多少」，
  回頭修正方法一估的數字。

單一產品的詳細填空練習（例如 draw.io 的 `__FILL_ME_3__`～`__FILL_ME_5__`）
請見各產品自己的 `exercises/README.md`；這裡只講通用方法跟共用的測試工具。

---

## 方法一：理論估算

資源設定分兩層，兩層要互相對得上：

```text
LimitRange.min  
  ≤  
Container.requests  
  ≤  
Container.limits  
  ≤  
LimitRange.max
Σ(replicas × 每個 Pod 的 requests)  
  ≤  
ResourceQuota.hard.requests
Σ(replicas × 每個 Pod 的 limits)  
  ≤  
ResourceQuota.hard.limits
```

### 1. Container 的 `requests`

代表這個容器「平常穩定執行」大概需要的量，是**排程器**用來決定把 Pod
排到哪個節點的依據（節點剩餘可分配資源必須 ≥ requests 才會被排進去）。
判斷依據：官方文件建議的最低需求，或先用預估值上線後拿 `kubectl top pod`
觀察一段時間的實際用量再回頭調整（也可以直接用下面的 k6 實測工具跑一次）。

### 2. Container 的 `limits`

允許這個容器「尖峰時最多」能用到的量，通常抓 `requests` 的 **2～5 倍**當
緩衝，但 CPU 跟 Memory 要分開想，因為超用後果不同：

- **CPU 是可壓縮資源**：超過 `limits` 只會被「節流（throttle）」變慢，
  不會被殺，比例可以抓寬一點（例如 draw.io 抓 5 倍：100m request /
  500m limit）。
- **Memory 是不可壓縮資源**：超過 `limits` 會直接被 **OOMKilled**，
  比例要抓保守一點（例如 draw.io 抓 2 倍：256Mi request / 512Mi limit）。

### 3. `LimitRange.max` / `min`

幫**整個 namespace**訂「單一容器」的天花板與地板，不是針對某一個
Deployment，要抓得比目前已知的工作負載再留一點空間：

- `max`：namespace 裡任何一個容器最多能要多少，必須 **≥** 該 namespace
  裡所有 Deployment/StatefulSet 實際填的 `limits`，否則 Pod 會被
  LimitRange 直接擋掉、連 Pending 都排不進去。
- `min`：namespace 裡任何一個容器最少要 request 多少，必須 **≤** 最小的
  那個容器實際填的 `requests`。抓太高會擋掉合理的輕量容器（本教材在
  幫 cloudbeaver 加 Adminer 時真的踩過這個坑：50m/64Mi 的正常小容器被
  100m/256Mi 的 LimitRange 下限擋掉）。
- `default`/`defaultRequest`：使用者忘記寫 `requests`/`limits` 時的自動
  預設值，通常設在「這個 namespace 裡最常見工作負載」的量附近。

### 4. `ResourceQuota.hard.requests` / `limits`

Namespace 總量配額，計算基準是**這個 namespace 裡所有 Pod 的 `requests`
加總**（不是 `limits`）：

```text
Σ(每個 Deployment/StatefulSet 的 replicas × 每個 Pod 的 requests)  ≤  ResourceQuota.hard.requests
```

配額不能只填「剛好夠目前用量」——要留擴容餘裕，尤其若這個產品有 HPA，
要算到 `maxReplicas` 全開時 requests 總量還在配額內。`limits` 總量同理，
但注意 `limits` 加總是「上限承諾」，實務上很少要求每個 Pod 都真的同時
吃滿 limit，屬於合理的超額訂閱（overcommit），不必要求 quota 的 limits
能同時滿足所有 Pod 都吃到頂。

**填數字前，問自己三個問題**：
1. 這個配額能同時容納 Deployment/StatefulSet 目前的 `replicas` 嗎？
2. 如果有 HPA、真的擴到 `maxReplicas`，配額還夠嗎？
3. LimitRange 的 `max`/`min` 有沒有把所有工作負載實際的
   `requests`/`limits` 包在中間，而不是卡在外面？

---

## 方法二：k6 階梯式壓測，一次找到容量邊界

理論估算只是起手值，實際流量模式往往跟猜的不一樣。本目錄提供一個共用
工具，用 [k6](https://k6.io/) 對指定產品做**階梯式壓測**：併發使用者數
（VU）每隔一段時間就往上加一階，一路爬到延遲或錯誤率觸發門檻為止就
自動停止——不用自己猜 `max_vus` 反覆重跑，一次執行就能量到「這一個
Pod 撐得住的容量邊界」在哪。測試期間同步取樣 `kubectl top pod`，測完
直接印出「k6 結果 + 容量邊界 + 資源取樣 + requests/limits/HPA 建議值 +
之後想加 replica 要改什麼」。

### 檔案

- [`k6-script.js`](k6-script.js) —— k6 測試腳本本體，透過 `dev-gateway`
  打進目標產品（跟真實使用者路徑一致）。VU 數從 `START_VUS` 開始，每
  `STEP_DURATION` 增加 `STEP_VUS`，最多爬 `MAX_STEPS` 階；同時設定
  `http_req_duration`（p95）與 `http_req_failed`（錯誤率）兩個
  `abortOnFail` 門檻，只要撞到任何一個，k6 立刻中止整個測試——那一刻
  的併發數就是容量邊界。腳本內建 `handleSummary()`，會印出一段固定格式
  的摘要區塊給 `run-load-test.sh` 解析。
- [`run-load-test.sh`](run-load-test.sh) —— 執行腳本，除了跑 k6 Job +
  取樣 `kubectl top pod`，還會：
  1. 測試前先記錄並**暫停目標 Deployment 的 HPA**、把 `replicas` 暫時
     **縮到 1**——這樣量到的邊界才是「單一 Pod」的真實容量，不會被 HPA
     中途加開新 Pod 或原本的多個 replica 分攤流量稀釋掉。
  2. 測試後不論成功/失敗/中斷，都會自動還原 HPA 與原本的 `replicas`
     （靠 `trap` 保證，不會留下改過的叢集狀態）。
  3. 算出 requests/limits 建議值之後，進一步換算成 **HPA 建議**
     （`minReplicas`/`targetCPUUtilizationPercentage`/`maxReplicas`），
     並對照目標 namespace 現有的 `ResourceQuota` 即時檢查「如果照建議
     調高 maxReplicas，現在的配額夠不夠」。

### 用法

```bash
./run-load-test.sh <namespace> <deployment-name> <app-label-value> <host-header>
```

以 draw.io 為例：

```bash
cd docs/resources
./run-load-test.sh drawio drawio drawio drawio.nexai.org.com
```

參數對照：
| 參數 | 從哪裡找 | draw.io 範例 |
|---|---|---|
| `namespace` | 產品的 `00-namespace.yaml` | `drawio` |
| `deployment-name` | Deployment 的 `metadata.name` | `drawio` |
| `app-label-value` | Deployment 的 `spec.template.metadata.labels.app`（`kubectl top pod` 要用這個 label 篩選） | `drawio` |
| `host-header` | HTTPRoute 的 `hostnames[0]` | `drawio.nexai.org.com` |

壓測階梯與判斷門檻可用環境變數覆寫（都有預設值，通常不用改）：
| 環境變數 | 預設值 | 意義 |
|---|---|---|
| `START_VUS` | `5` | 第一階的併發使用者數 |
| `STEP_VUS` | `5` | 每一階增加的併發使用者數 |
| `STEP_DURATION` | `30s` | 每一階維持多久 |
| `MAX_STEPS` | `30` | 安全上限，爬到這階還沒撞門檻就自動收尾 |
| `P95_THRESHOLD_MS` | `800` | p95 延遲超過這個值視為「壞了」 |
| `ERROR_RATE_THRESHOLD` | `0.05` | 錯誤率超過 5% 視為「壞了」 |
| `EXPECTED_PEAK_USERS` | `100` | 只用於 HPA 建議裡示範 `maxReplicas` 怎麼算，請依實際情境覆寫 |
| `EXTRA_ASSET_PATHS` | 空 | 逗號分隔的相對路徑，每輪除了 `/` 之外，用 `http.batch()` 平行一起抓（模擬瀏覽器載入頁面時的行為）。見下方「只測 `/` 會低估真實負載」 |
| `THINK_TIME_SEC` | `1` | 每輪之間的思考時間（秒）。有帶 `EXTRA_ASSET_PATHS` 時建議調大，避免每秒重複下載整包資源 |

```bash
MAX_STEPS=50 EXPECTED_PEAK_USERS=300 ./run-load-test.sh drawio drawio drawio drawio.nexai.org.com
```

### 只測 `/` 會低估真實負載——例如 draw.io

預設只打 `/`，這是最通用、對任何產品都成立的測法，但對 draw.io 這種純前端
SPA 來說會嚴重低估真實負載：實測 `/` 只是一個 **12.7KB** 的靜態 HTML 外殼
（`etag`/`last-modified` 都在，nginx 直接吃檔案快取回，幾乎零運算成本）。
真實使用者打開頁面時，瀏覽器接著會下載它的 JS/CSS 應用程式本體：

| 檔案 | 大小 |
|---|---|
| `js/app.min.js` | 8.9 MB |
| `js/stencils.min.js` | 6.6 MB |
| `js/extensions.min.js` | 4.1 MB |
| `js/shapes-14-6-5.min.js` | 1.4 MB |
| `styles/grapheditor.css` | 55 KB |

合計約 21MB，是 `/` 本身的 1600 多倍，只測 `/` 等於完全沒測到這一大塊。
`EXTRA_ASSET_PATHS` 就是讓每一輪「頁面載入」把這些真正的資源也一併打進
去，量出來的 CPU/Memory 才反映得出「真的有人在用」的負載：

```bash
EXTRA_ASSET_PATHS="js/app.min.js,js/extensions.min.js,js/shapes-14-6-5.min.js,js/stencils.min.js,styles/grapheditor.css" \
THINK_TIME_SEC=5 START_VUS=2 STEP_VUS=2 \
./run-load-test.sh drawio drawio drawio drawio.nexai.org.com
```

（每個 VU 每輪要多傳輸約 21MB，`STEP_VUS` 建議比純測 `/` 時抓小一點，
不然很快就會把頻寬用滿）。判斷「有沒有撞到邊界」的 p95 門檻只看 `/`
本身的延遲（k6 腳本內部用 `tags: { name: 'root' }` 標記、`thresholds`
只設在 `http_req_duration{name:root}` 上），不會被大檔案的下載時間污染
——下載慢是頻寬/檔案大小決定的，不是伺服器過載的訊號，混在一起判斷
容易誤判。

其他產品的靜態資源路徑不會跟 draw.io 一樣，要嘛照抄同樣方法自己從
瀏覽器開發者工具或 `curl` 該產品的首頁找出真正的 JS/CSS 路徑，要嘛不帶
`EXTRA_ASSET_PATHS`（維持只測 `/`）——兩種測法都有效，差別只在測出來的
數字代表「最輕的一種請求」還是「完整頁面載入」，解讀建議值時要記得這個
前提，不要把測 `/` 測出來的數字直接當成完整需求的答案。

### 輸出範例（節錄）

```text
########## [2/4] 容量邊界（單一 Pod，replicas 已暫時縮到 1）##########
峰值併發 45 VU、輸出量 44.80 req/s、p95 812.3ms、平均 210.5ms、錯誤率 6.20%
→ 已觸及邊界（原因：http_req_duration(p(95)<800)）。單一 Pod 大約能扛住 45 個併發使用者。

########## [4/4] requests/limits/HPA 建議值 + 加一個 replica 要改什麼 ##########
requests.cpu    ≈ 96m   （測試前段、負載還輕時的平均用量）
limits.cpu      ≈ 211m  （峰值 162m x1.3，CPU 可壓縮，緩衝抓小一點即可）
requests.memory ≈ 224Mi （測試前段、負載還輕時的平均用量）
limits.memory   ≈ 377Mi （峰值 251Mi x1.5，Memory 不可壓縮，緩衝抓大一點避免 OOMKilled）

---- HPA 建議 ----
minReplicas ≈ 2（至少 2，確保單一 Pod 重啟/被驅逐時還有另一個在撐著；原本設定是 2）
targetCPUUtilizationPercentage ≈ 70（...）
maxReplicas 公式 ≈ ceil(預期尖峰同時在線人數 ÷ 單 Pod 容量邊界)
  範例：若預期尖峰同時在線 100 人，單 Pod 邊界 45 人 → maxReplicas ≈ ceil(100 / 45) = 3

---- 之後想把 maxReplicas 調高，需要改動的地方 ----
1. ResourceQuota：...
...
即時檢查：目前 drawio 的 ResourceQuota.hard.requests.cpu = 1（= 1000m），
  若 maxReplicas 開到範例算出的 3，需要 3 x 96m = 288m。
  → 目前配額夠用，不需要調整 ResourceQuota 就能擴到 3 個 replica。
```

### 加一個 replica，到底要改什麼？

`maxReplicas` 調高只是「允許」HPA 多開 Pod，實際上還要確認：

1. **ResourceQuota**：`Σ(replicas × requests)` 必須 ≤ quota，新 Pod 才
   排得進去，否則卡在 `Pending`（`FailedCreate: exceeded quota`）。
2. **LimitRange**：單一容器的 `min`/`max` 不受 replicas 數影響，不用跟
   著調，但若 requests/limits 本身有變，仍要落在範圍內。
3. **HPA 本身**：`maxReplicas` 就是新的天花板，設太低等於白測；也要注意
   `behavior`/`stabilizationWindow`，避免 replicas 數上下震盪。
4. **節點容量**：本叢集 `k8s01~03` 記憶體長期在 81-91% 使用率，加
   replica 前務必先 `kubectl top nodes` 確認還有空間，不然新 Pod 一樣
   卡 `Pending`，但原因是節點滿了、不是 quota 不夠，兩者要分開排查。
5. **NetworkPolicy**：本教材多數規則用 `podSelector`/`from: []`，不受
   replica 數影響，通常不用改；若之後改成 IP 白名單或連線數限制邏輯，
   要另外檢查。
6. **儲存（若目標是 StatefulSet）**：`volumeClaimTemplates` 型的每個
   replica 各自一份 PVC，多一個 replica 就多一份儲存用量，要確認
   StorageClass 容量夠，不是只看 CPU/Memory。

`run-load-test.sh` 的第 4 段報告會把第 1 點對照目前的 `ResourceQuota`
即時算給你看，其他幾點目前需要人工檢查（本教材規模還沒到需要自動化
這些的程度）。

### 使用前務必注意

- **這個腳本會暫時改動叢集上的真實狀態**（暫停 HPA、把 replicas 縮到
  1），結束後會自動還原，但**不要在有學員正在使用這個產品、或正式上
  課中的時段執行**。
- **需要 metrics-server**（本叢集已確認可用），否則 `kubectl top pod`
  沒有資料，第 3 段報告會是空的。
- **測試會對叢集帶來額外負載**，避免在上課尖峰時段對本來就吃重的產品
  （例如已經 pin 在 `gpu01` 的 onlyoffice、peertube）加測，或先跟其他
  同時在用叢集的人協調一下時間。
- 建議值只是「這次測試流量模式」下量出來的參考，不是絕對答案；改變
  `START_VUS`/`STEP_VUS`/`STEP_DURATION` 會量到不同的曲線，最終數字仍
  要回頭跟「方法一：理論估算」互相驗證，兩者對得上才放心寫進正式
  manifest。
