# Helm Chart 教學文件

這份文件教「Helm 是什麼、為什麼要學、本教材的 chart 怎麼寫」，搭配各
產品目錄下的 `chart/`（例如 [`../../draw.io/chart/`](../../draw.io/chart/)）
一起看效果最好——這裡講通用概念，各產品 `chart/values.yaml` 裡的逐欄位
註解負責講「這個產品自己的細節」，兩者互補。

## 目錄

1. [Helm 在這個課程裡的定位](#1-helm-在這個課程裡的定位)
2. [Chart 的目錄結構](#2-chart-的目錄結構)
3. [Template 語法基礎](#3-template-語法基礎)
4. [常用指令](#4-常用指令)
5. [本教材所有 chart 的共通慣例](#5-本教材所有-chart-的共通慣例)
6. [各產品 chart 的特殊設計對照表](#6-各產品-chart-的特殊設計對照表)
7. [手把手練習：把 draw.io 從 yaml 改成用 Helm 管理](#7-手把手練習把-drawio-從-yaml-改成用-helm-管理)
8. [常見錯誤與除錯](#8-常見錯誤與除錯)

---

## 1. Helm 在這個課程裡的定位

每個產品目錄都提供三種形式（見各產品自己的 `README.md`，例如
[`../../draw.io/README.md`](../../draw.io/README.md)）：

| 形式 | 用途 |
|---|---|
| `manifest/` | 拆成多支編號 yaml，一支一支 apply，講解每個資源的作用 |
| `<product>-all-in-one.yaml` | 內容跟 `manifest/` 完全一致的合併版，快速重建環境用 |
| `chart/` | **本文件的主題**：Helm Chart 版本 |

前兩種形式教完「K8s 資源本身」之後，`chart/` 要教的是**另一個層次的
問題**：當同一組 yaml 要在多個環境（開發/測試/正式）、或用不同參數
（replica 數、hostname、image tag...）重複部署時，純手改 yaml 會遇到
什麼麻煩？Helm 解決的正是這個問題——把「會變動的值」抽成一份
`values.yaml`，「不變的資源骨架」寫成模板，兩者在 `helm install`/
`helm upgrade` 時合併渲染成真正的 K8s yaml 再送進 API Server。

**Helm 不是取代 kubectl**，`helm template` 渲染出來的東西本質上還是
給 `kubectl apply` 用的 yaml；Helm 多做的事情是：幫你記住「這次裝的是
哪個版本、用了什麼參數」（`helm history`/`helm get values`），並提供
`helm rollback` 一鍵回到上一個版本。

## 2. Chart 的目錄結構

以最簡單的 [`draw.io/chart/`](../../draw.io/chart/) 為例：

```text
chart/
├── Chart.yaml              # Chart 的「身分證」：名稱、版本
├── README.md               # 這個產品 chart 的說明文件（Values 參數表、安裝方式）
├── values.yaml              # 預設參數值
└── templates/
    ├── _helpers.tpl         # 共用的模板片段（命名、標準 label）
    ├── deployment.yaml
    ├── service.yaml
    ├── httproute.yaml
    ├── hpa.yaml
    ├── networkpolicy.yaml
    └── resourcequota.yaml   # 同時定義 ResourceQuota + LimitRange 兩個物件
```

### `Chart.yaml`

```yaml
apiVersion: v2
name: drawio
description: draw.io (diagrams.net) — K8s 教育訓練用 Helm Chart
type: application
version: 0.1.0        # Chart 本身的版本（改了 templates/values 的結構就該升這個）
appVersion: "24.7.17" # 這個 chart 目前部署的應用程式版本（對應 image.tag）
```

`version` 跟 `appVersion`是兩個不同的概念：`version` 是這份 Helm
Chart（模板+預設值的組合）本身的版本，`appVersion` 只是標註「這個
chart 目前預設部署的是哪個應用版本」，純資訊用途，不影響渲染結果。

### `values.yaml` / `README.md`

`values.yaml` 存放所有「可能會變動」的參數；每個產品 chart 目錄下的
`README.md`（例如 [`../../draw.io/chart/README.md`](../../draw.io/chart/README.md)）
才是**逐參數說明的主要位置**——列出每個欄位的意義、預設值、對應
哪個 template、以及該產品特有的注意事項，教學上請直接打開對應產品的
`chart/README.md` 查參數表，這裡不重複抄一份，只講共通的設計慣例
（見第 5 節）。

### `templates/_helpers.tpl`

定義可以在其他 template 裡重複呼叫的「模板函式」，本教材每個產品都用
同一組最小慣例：

```yaml
{{- define "drawio.name" -}}
drawio
{{- end -}}

{{- define "drawio.labels" -}}
app.kubernetes.io/name: {{ include "drawio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: drawio
{{- end -}}
```

- `<product>.name`：回傳這個產品的固定名稱，之後改名只要改這一處。
- `<product>.labels`：回傳一組標準 label，包含 Helm 官方建議的
  `app.kubernetes.io/*` 系列，以及本教材沿用純 yaml 版本、給
  `Service`/`NetworkPolicy` 用來 `selector` 比對的 `app: <product>` 這個
  簡單 label——**兩者並存**，前者是 Helm 慣例，後者是跟純 yaml 版本
  保持相容，方便學員對照兩種形式其實是同一件事。

## 3. Template 語法基礎

Helm 的模板語法是 Go 的 `text/template`，以下是本教材 templates/ 底下
唯一會用到的幾個語法，看過一輪即可讀懂所有產品的 chart：

| 語法 | 範例 | 意義 |
|---|---|---|
| `{{ .Values.xxx }}` | `{{ .Values.replicaCount }}` | 讀 `values.yaml` 裡的值 |
| `{{ .Values.a.b.c }}` | `{{ .Values.persistence.srv.size }}` | 讀巢狀結構裡的值 |
| `{{ .Release.Namespace }}` | — | Helm 內建變數：`helm install -n <ns>` 指定的 namespace |
| `{{- if cond }} ... {{- end }}` | `{{- if .Values.hpa.enabled }}` | 條件渲染，`enabled: false` 時整段（含前後的 `---` 分隔線）都不會出現在結果裡 |
| `{{- range list }} ... {{- end }}` | `{{- range .Values.hostnames }}` | 迴圈渲染，用在「值是一個陣列」的欄位，例如多個 hostname |
| `{{ include "x.y" . }}` | `{{ include "drawio.labels" . }}` | 呼叫 `_helpers.tpl` 裡定義的模板片段，`.` 是把目前的整包上下文（Release/Values/Chart...）傳進去 |
| `\| quote` | `{{ .Values.image.tag \| quote }}` | 把值強制加上雙引號（避免數字/布林值被誤判成非字串型別） |
| `\| nindent N` | `{{- toYaml .Values.resources \| nindent 12 }}` | 把多行內容整段縮排 N 個空白後插入，`toYaml` 是把一個 map/list 直接轉成 yaml 片段 |
| `{{- with .Values.x }} ... {{- end }}` | `{{- with .Values.nodePlacement.nodeSelector }}` | 只有值存在（非空）才渲染這一段，並把 `.` 換成該值本身，省一層 `.Values.nodePlacement.nodeSelector.xxx` |

`{{-` 開頭跟 `-}}` 結尾的 `-` 是「去除這一行前後的空白/換行」，純粹是
排版用，不影響邏輯——渲染結果縮排不整齊時，通常就是漏加或多加了這個
`-`。

## 4. 常用指令

```bash
# 前置：namespace 不由任何一個產品的 chart 建立（見第 5 節），先手動建立
kubectl apply -f <product>/manifest/00-namespace.yaml

# 安裝（相當於「這次是全新建立」）
helm install <release-name> ./chart -n <namespace>

# 只想看渲染結果，不真的送進叢集——寫 chart 時最常用的一條指令
helm template <release-name> ./chart -n <namespace>

# 靜態檢查 chart 語法/慣例（本文件所有產品的 chart 都應該 0 錯誤通過）
helm lint ./chart

# 調整參數重新部署（相當於「這次是修改既有部署」）
helm upgrade <release-name> ./chart -n <namespace>

# 命令列覆寫單個值，不用真的改 values.yaml（適合臨時測試）
helm upgrade <release-name> ./chart -n <namespace> --set replicaCount=3

# 用另一份檔案整批覆寫（適合「同一個 chart，不同環境用不同參數」的情境）
helm upgrade <release-name> ./chart -n <namespace> -f values-prod.yaml

# 查看這個 release 目前實際生效的參數（預設值 + 所有覆寫合併後的結果）
helm get values <release-name> -n <namespace>

# 查看這個 release 的部署歷史（每次 install/upgrade 都會留一筆版本紀錄）
helm history <release-name> -n <namespace>

# 版本出問題，回滾到上一版（純 yaml/all-in-one 形式沒有這個能力，是 Helm 的加值功能）
helm rollback <release-name> -n <namespace>

# 移除（不會刪 namespace，也不會刪 chart 沒有建立的資源，例如 Namespace 本身）
helm uninstall <release-name> -n <namespace>
```

**`--set` 跟 `-f` 的覆寫優先順序**：命令列 `--set` > 額外用 `-f` 指定的
檔案（多個 `-f` 依下命令的順序疊加，後面蓋前面）> chart 自帶的
`values.yaml`。教學上建議先用 `--set` 示範單個值覆寫，再進階示範
`-f values-override.yaml` 的整批覆寫用法。

## 5. 本教材所有 chart 的共通慣例

讀任何一個產品的 `values.yaml` 之前，先知道這些跨產品都一致的設計，
就不會被個別產品的差異搞混：

- **Namespace 不由 chart 建立**。每個產品的 `chart/` 都沒有
  `namespace.yaml` 模板，統一在安裝前手動
  `kubectl apply -f manifest/00-namespace.yaml`（或
  `--create-namespace`）。原因是 Helm 對 `Namespace` 這種「可能被多個
  release 共用」的資源，`helm uninstall` 時的 ownership 判定容易出
  意外（例如誤刪其他人還在用的 namespace），教學上刻意讓 namespace
  的生命週期跟 chart 分開管理。
- **`resourceQuota`/`limitRange` 幾乎逐產品同構**：都有
  `enabled: true/false` 開關、`requestsCpu`/`requestsMemory`/
  `limitsCpu`/`limitsMemory`/`pods` 幾個欄位，資源治理的判斷方法（怎麼
  抓 requests/limits 的倍數、`min`/`max`/`default`/`defaultRequest`
  之間的大小關係）統一寫在
  [`../resources/README.md`](../resources/README.md)，不在這裡重複。
- **`gateway`/`hostnames` 對外曝露一律走 Gateway API**：本叢集用
  Cilium 的 Gateway API 取代傳統 Ingress，所有產品的 `HTTPRoute` 都
  `parentRefs` 到同一個教學專用的 `dev-gateway`（定義在
  [`../../shared-infra/`](../../shared-infra/)），不是正式環境的
  `app-gateway`/`admin-gateway`。
- **`networkPolicy.enabled` 開關**：每個產品都先 default-deny 擋掉
  namespace 內所有進出流量，再逐條開白名單（allow ingress from
  gateway、allow egress DNS、跟該產品需要的內部/跨 namespace 連線）。
  關掉這個開關方便對照「有/沒有 NetworkPolicy」的行為差異；正式上課前
  務必先用 `enabled: true` 實測連線是否正常。
- **`resources.requests`/`resources.limits` 是每個 workload 各自一組，
  不是全域一組**：多元件產品（flarum 的 mysql、planka/peertube 的
  postgres）會看到 `mysql.resources`/`postgres.resources` 這種巢狀
  寫法，每個 workload 的資源獨立設定，但都要一起算進同一份
  `resourceQuota`（見第 6 節的「多元件」欄）。
- **密碼/密鑰欄位教學用明文，正式環境不要照搬**：`values.yaml` 裡看到
  `adminPassword`/`secretKey`/`rootPassword` 這類欄位直接寫明文字串，
  是為了教學方便直接看到「這個值最後會變成哪個 Secret 的哪個
  key」，正式環境應該改用 `--set-file`、外部密鑰管理工具（Vault、
  Sealed Secrets...）或至少搭配 `.gitignore` 排除的私有
  values 檔案。

## 6. 各產品 chart 的特殊設計對照表

完整參數表請點進各產品的 `chart/README.md`；這裡只列「這個產品跟別人
不一樣的地方」。

| 產品 | Workload 數 | 特殊設計 | 參數說明 |
|---|---|---|---|
| draw.io | 1 | 唯一有 `hpa.*`；全教材最單純的範本，適合當第一個教學範例 | [`draw.io/chart/README.md`](../../draw.io/chart/README.md) |
| filebrowser | 1 | `replicaCount` 固定 1；兩個 PVC（RWX 檔案 + RWO db）示範 StorageClass 取捨；`onlyoffice.*` 跨產品整合設定 | [`filebrowser/chart/README.md`](../../filebrowser/chart/README.md) |
| flarum | 2（app + mysql） | `mysql.*` 整組併在同一個 chart 裡；`db.host` 用同 namespace 短名稱；`forum.adminPassword` 明文但 mysql 密碼靠 `secretKeyRef` 互相引用不重複填 | [`flarum/chart/README.md`](../../flarum/chart/README.md) |
| planka | 2（app + postgres） | 跟 flarum 對稱但相反的容器安全模型：app 映像非 root，可以 `capabilities.drop: [ALL]`，不需要 initContainer | [`planka/chart/README.md`](../../planka/chart/README.md) |
| onlyoffice | 1（bundled-everything） | `nodePlacement.*` 釘死 GPU 節點；`pluginsEnabled: false` 避開背景行程在受限網路下無限重試的坑 | [`onlyoffice/chart/README.md`](../../onlyoffice/chart/README.md) |
| peertube | 3（app + postgres + redis） | 全教材整合度最高；`redis` 刻意用 emptyDir 不用 PVC，跟 `postgres` 的 PVC 做持久化策略對照；三個元件都 `nodePlacement` 到同一個 GPU 節點 | [`peertube/chart/README.md`](../../peertube/chart/README.md) |
| cloudbeaver | 1（跨 namespace 用戶端） | 唯一用 `networkPolicy.databaseTargets` 陣列 `range` 展開多筆跨 namespace 規則，示範「資料驅動」的模板寫法 | [`cloudbeaver/chart/README.md`](../../cloudbeaver/chart/README.md) |

**教學建議順序**：draw.io（最單純）→ filebrowser（第一個 PVC）→
flarum（多元件+Secret互相引用）→ cloudbeaver（跨 namespace，收尾），
跟純 yaml 版本的教學順序（見
[`../../training.md`](../../training.md)）一致，因為 chart 只是換一種
管理方式，資源本身的難度遞進沒有變。

## 7. 手把手練習：把 draw.io 從 yaml 改成用 Helm 管理

這個練習假設學員已經走完 draw.io 的 `manifest/` 教學主線，目標是體會
「同一組資源，用 Helm 管理之後改參數有多方便」。

```bash
# 0. 前置：namespace 沿用純 yaml 版本已經建立好的（chart 不會重建它）
kubectl get namespace drawio

# 1. 先看 chart 會渲染出什麼，跟 manifest/ 裡手寫的 yaml 比對是否一致
cd draw.io
helm template drawio ./chart -n drawio | less

# 2. 靜態檢查
helm lint ./chart

# 3. 正式安裝（如果 manifest/ 版本還在跑，記得先 kubectl delete 對應資源，
#    或改用一個新的 namespace 做這個練習，避免資源名稱衝突）
helm install drawio ./chart -n drawio

# 4. 體會「改參數」的差異：純 yaml 版本要手改 02-deployment.yaml 再 apply，
#    Helm 版本只需要一條指令
helm upgrade drawio ./chart -n drawio --set replicaCount=3
kubectl get deploy drawio -n drawio -w

# 5. 體會「版本回滾」：純 yaml 版本沒有這個能力
helm history drawio -n drawio
helm rollback drawio -n drawio 1

# 6. 清除
helm uninstall drawio -n drawio
kubectl delete namespace drawio
```

延伸練習：把 `values.yaml` 裡的 `hpa.maxReplicas` 從 5 改成 8，先
`helm template` 確認渲染結果的 `HorizontalPodAutoscaler.spec.maxReplicas`
真的變成 8，再 `helm upgrade` 套用，最後用
[`../resources/README.md`](../resources/README.md) 的 k6 壓測工具驗證
「加開 replica」真的需要調整 `ResourceQuota`（第 4 節提到的「maxReplicas
調高要改什麼」清單）。

## 8. 常見錯誤與除錯

| 現象 | 常見原因 | 排查方式 |
|---|---|---|
| `helm install` 報 `namespaces "xxx" not found` | 忘記先 `kubectl apply -f manifest/00-namespace.yaml`（本教材所有 chart 都不建立 Namespace，見第 5 節） | 先建立 namespace，或改用 `helm install ... --create-namespace` |
| `helm install` 報 Namespace 相關的 ownership/annotation 衝突 | 這個 namespace 是用 `kubectl apply` 建立的（沒有 Helm 的 `meta.helm.sh/release-name` annotation），又想讓另一個 chart 去管理它 | 本教材的設計就是刻意讓 namespace 生命週期跟 chart 分開，不需要修，只要不要讓 chart 嘗試建立 Namespace 資源即可 |
| `helm template`/`helm install` 報 `nil pointer evaluating interface {}.xxx` | `values.yaml` 少填了某個巢狀欄位，或欄位名稱打錯（例如 `persistence.srv.size` 打成 `persistence.size`） | 對照該產品 `values.yaml` 裡的完整結構，或 `grep -rn "Values\." chart/templates/` 找出這個 template 實際期待的路徑 |
| `helm upgrade` 之後 Pod 沒有任何變化 | 改的是不會反映到 Pod spec 的欄位（例如只改了 `resourceQuota` 但沒動 `deployment.yaml` 相關的值），或改到的是「首次初始化才生效」的資料庫密碼類欄位 | 先 `helm template` 比對渲染結果差異，確認改動真的影響到目標資源；資料庫密碼類問題見各產品 `values.yaml` 裡「只在 PVC 第一次 initdb 生效」的註解 |
| Pod 一直 `Pending`，`kubectl describe pod` 顯示 `exceeded quota` | `resources.requests` 改大之後，`replicas x requests` 加總超過 `resourceQuota` | 同步調整 `resourceQuota`，判斷方法見 [`../resources/README.md`](../resources/README.md) |
| Pod 建立不起來，`kubectl describe pod` 顯示 `minimum cpu/memory usage per Container is ...` | 新加的容器 `resources.requests` 低於 `limitRange.min`（本教材真的在 cloudbeaver 加 Adminer 時踩過這個坑） | 檢查目標 namespace 的 `limitRange.min`，或把這個容器的 `requests` 提高到門檻以上 |
| `helm lint` 過了，但實際 apply 後行為跟預期不同 | `helm lint` 只檢查模板語法跟少數內建規則，不驗證「渲染出來的 K8s 資源語意是否正確」 | 一律先 `helm template` 讀渲染結果，跟純 yaml 版本（`manifest/`）逐欄位比對，兩者除了本來就該不同的地方（例如 `metadata.name` 是否套用 Release 前綴）以外應該完全一致 |
| 改了 `values.yaml` 卻沒有生效 | 忘記真的執行 `helm upgrade`——改 `values.yaml` 本身不會自動觸發任何叢集變化 | `helm upgrade <release> ./chart -n <namespace>`，或先 `helm get values <release> -n <namespace>` 確認目前 release 實際套用的值 |
