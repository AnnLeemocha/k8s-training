# Filebrowser（FileBrowser Quantum）

輕量級的網頁版檔案管理器，提供安全的檔案上傳、下載、預覽與權限管理介面，
並整合 [onlyoffice](../onlyoffice/) 提供線上編輯 Word / Excel / PPT 的能力。

## ⚠️ 專案現況：已從 filebrowser/filebrowser 遷移到 FileBrowser Quantum

官方 `filebrowser/filebrowser` repo 已於 **2026-09-01 封存（archived）**：
最後一版 `v2.63.23` 已釋出，之後不會再有新版本、bug fix 或資安修補。官方
repo 本身沒有在文件中指定後繼專案，但目前社群最活躍、持續開發、且作者
貢獻程式碼量已超過原專案其他所有貢獻者總和的 fork 是 **FileBrowser
Quantum**，本產品已改用它：

- 專案介紹：<https://filebrowserquantum.com/en/docs/help/about/>
- 原始碼與 README：<https://github.com/gtsteffaniak/filebrowser/blob/main/README.md>

**版本選擇：v1.5.x 穩定線（`gtstef/filebrowser:1.5.6-stable`），不是
v2.0.0 beta。** 兩條版本線都支援 OnlyOffice 整合（設定寫法略有差異：
v1.5.x 用 `http.trustedHeaders`，v2.0.0 用 `http.trustProxyHeaders`），
但 v2.0.0 官方自己標示為 beta、資料庫格式還在變動，v1.5.x 才是正式的
穩定線，沒有必要為了追新冒不必要的風險。

Quantum **不是 drop-in replacement**：設定方式從環境變數（`FB_ROOT` /
`FB_DATABASE`）改成一份宣告式的 `config.yaml`（見 `manifest/03-configmap.yaml`），
這是換代後最直接的差異。PVC 有沿用（`filebrowser-srv` 檔案本體路徑
`/srv` 不變），但 `filebrowser-db` 裡舊版留下的 sqlite 檔案跟新版不
相容——**實測發現**兩者剛好用同一個檔名（`filebrowser.db`），新版第一次
啟動會偵測到舊格式、自動建立 `.bak` 備份後產生全新資料庫，不會導致
啟動失敗，但也代表舊版累積的使用者/設定資料不會被沿用（測試環境內
`/srv` 本來就是空的，沒有實際檔案遺失的問題）。

## 已實測驗證（2026-09-18，直接對線上訓練叢集操作）

- `kubectl apply` 三種形式（manifest 逐檔／all-in-one／Helm chart）皆
  `--dry-run=client` 通過，且已實際套用到 `filebrowser` namespace。
- Pod 正常 Running/Ready，containerPort 80、`drop: [ALL]` capabilities
  的安全性設定沿用舊版慣例，**沒有**遇到非 root 使用者無法綁定
  port 80 的問題。
- `admin` / `admin` 登入 API 驗證成功（注意：Quantum 的登入 API 是
  `POST /api/auth/login?username=<user>` + `X-Password` header，
  不是 JSON body——串接自動化腳本時要留意）。
- **端對端驗證 OnlyOffice 整合真的能用**：上傳一個真正的 `.docx`、呼叫
  `GET /api/office/config` 拿到 `document.url`，再模擬 Document Server
  的角色去下載那個網址，實測收到 HTTP 200、拿到完整檔案內容——不只是
  「設定串起來了」，是真的驗證了 Document Server 抓得到檔案。
- **待關注**：`filebrowser-db` PVC 只有 1Gi，啟動 log 出現
  `cacheDir only has 0.93 GB of free space, this is less than the
  20 GB minimum recommended` 的警告（非致命，只是建議值）。教學用途
  資料量小可以不理會，但長期使用或要示範大量檔案快取時，建議把
  `02-pvc.yaml` 的 `filebrowser-db` 容量調大。

### 實測踩到的三個坑（都已修正在 manifest 裡，可以直接當課堂案例）

1. **entrypoint 不轉發 `-c` 參數**：一開始用 `args: ["-c", "/config/config.yaml"]`
   指定設定檔路徑，結果 container 直接 FATAL 找不到設定檔——這個 image
   的 entrypoint 不會把 `-c` 轉發給底層執行檔，一律回頭找
   `/home/filebrowser/data/config.yaml`（官方「推薦掛法」的預設路徑）。
   解法：不跟 entrypoint 對抗，改用 `subPath` 把 ConfigMap 的
   `config.yaml` 直接疊到這個預設路徑上（見 `manifest/04-deployment.yaml`）。

2. **`document.url` 指到瀏覽器網址，Document Server 抓不到檔案**：不設定
   `server.internalUrl` 的話，filebrowser 會拿使用者瀏覽器連進來的網址
   （`filebrowser.nexai.org.com`）組出下載連結給 Document Server 用，
   但 onlyoffice pod 連不到叢集外部的 dev-gateway 網域，**編輯器畫面會
   顯示「目前無法存取該檔案」**。而且這是雙向的坑：對應地，onlyoffice
   那邊的 NetworkPolicy 原本也只放行了「filebrowser → onlyoffice」，
   沒放行「onlyoffice → filebrowser」這個回頭抓檔案的方向。兩邊都要修：
   - filebrowser：`server.internalUrl` 設成
     `http://filebrowser.filebrowser.svc.cluster.local`（見
     `manifest/03-configmap.yaml`）
   - onlyoffice：新增 `allow-egress-onlyoffice-to-filebrowser` 規則
     （見 `../onlyoffice/manifest/07-networkpolicy.yaml`）

   這是很好的教學案例：**OnlyOffice 整合是雙向網路流量，不是只有
   filebrowser 連 onlyoffice 單方向**——課堂上可以先只加一個方向的
   NetworkPolicy，讓學員實際看到「目前無法存取該檔案」錯誤，再帶著
   一起抓出來要補第二條規則。

3. **開機卡 31 秒，跟 onlyoffice 的 `PLUGINS_ENABLED` 是同一類問題**：
   Quantum 預設啟動時會「同步、阻塞式」呼叫
   `https://api.github.com/repos/.../tags` 檢查新版本，NetworkPolicy
   沒開放對外網際網路，連線被悄悄丟棄，實測每次開機都卡在 TCP connect
   timeout 整整 31 秒才繼續，差點被 readiness/liveness probe 的預設
   延遲值誤判成啟動失敗而不斷重啟。解法：`server.disableUpdateCheck: true`
   （見 `manifest/03-configmap.yaml`），開機時間降到 2 秒內。零信任
   網路下「預設會打外網的背景工作要嘛開白名單、要嘛乾脆關掉」，可以
   跟 onlyoffice 那個坑前後呼應，當成同一個教學主題的兩個案例。

## K8s 教育訓練用途

課程第二個範例，第一個「有狀態」應用：在 draw.io（無狀態）之後，
用來介紹 PersistentVolumeClaim，特別是 **RWO vs RWX 該怎麼選**——
不是看應用種類，而是看「這份資料能不能被多個 Pod 同時寫入」：

- `filebrowser-srv`（實際檔案）：`ReadWriteMany` + `rook-cephfs`
- `filebrowser-db`（sqlite 資料庫 + 快取）：`ReadWriteOnce` + `rook-ceph-block`

也因為 sqlite 不支援多寫入者，這個產品刻意把 `replicas` 固定為 1、
`strategy.type` 用 `Recreate`（不是 `RollingUpdate`），可以藉此講解
「不是所有應用都能無腦水平擴展」，跟 draw.io 的 HPA 範例形成對比——
這點從舊版換到 Quantum 都沒有變。

換版後多了兩個額外的教學點：

1. **宣告式設定檔 vs 環境變數**：舊版只靠 `FB_ROOT`/`FB_DATABASE` 兩個
   環境變數決定行為；Quantum 改用結構完整的 `config.yaml`（掛成
   ConfigMap），可以帶到「功能變多，設定複雜度也跟著上升」的取捨，
   以及 `subPath` 掛載單一檔案覆蓋到 PVC 目錄裡特定路徑的技巧。
2. **跨 namespace 的零信任存取**：filebrowser 要主動呼叫 onlyoffice
   namespace 的 Document Server 才能做線上編輯，`07-networkpolicy.yaml`
   多了一條用 `namespaceSelector` 比對 `kubernetes.io/metadata.name`
   的 egress 規則，寫法跟 [cloudbeaver](../cloudbeaver/) 連到
   flarum/planka/peertube 資料庫的模式一致，可以前後呼應。

提供三種形式，跟 [draw.io](../draw.io/) 的教學走法一致：

| 目錄/檔案 | 用途 |
|---|---|
| [manifest/](manifest/) | 教學主線：8 支編號檔案，一支一支 apply |
| [filebrowser-all-in-one.yaml](filebrowser-all-in-one.yaml) | 合併版單檔 |
| [chart/](chart/) | Helm Chart 版本 |
| [exercises/](exercises/) | **學員練習**：半成品 YAML 填空 + 埋錯除錯兩種題型，含架構圖、提示與驗收標準，`manifest/` 就是這些題目的正解 |

**前置條件**：

```bash
# 共用的教學 Gateway（跟 draw.io 共用同一個，已套用過就不用重複）
kubectl apply -f ../shared-infra/00-dev-gateway.yaml

# onlyoffice 產品要先部署好，本產品的 OnlyOffice 整合設定會呼叫它
# 詳見 ../onlyoffice/README.md
```

### 方式一：教學主線

```bash
kubectl apply -f manifest/00-namespace.yaml
kubectl apply -f manifest/01-resourcequota-limitrange.yaml
kubectl apply -f manifest/02-pvc.yaml
kubectl apply -f manifest/03-configmap.yaml
kubectl apply -f manifest/04-deployment.yaml
kubectl apply -f manifest/05-service.yaml
kubectl apply -f manifest/06-httproute.yaml
kubectl apply -f manifest/07-networkpolicy.yaml   # 進階、選用，上課前請先自行實測
```

### 方式二：合併版一次套用

```bash
kubectl apply -f filebrowser-all-in-one.yaml
```

### 方式三：Helm Chart

```bash
kubectl apply -f manifest/00-namespace.yaml
helm install filebrowser ./chart -n filebrowser
# 調整 OnlyOffice 串接位址/密鑰：--set onlyoffice.secret=xxx
# 移除：helm uninstall filebrowser -n filebrowser
```

### 上課前請先確認 / 調整

- `hostnames` 目前填 `filebrowser.nexai.org.com`，請依實際網域調整，
  並確認 DNS/hosts 指向 `dev-gateway` 的 EXTERNAL-IP。
- 預設帳密是 `admin` / `admin`（`manifest/03-configmap.yaml` 的
  `auth.adminUsername`/`adminPassword`），上課示範完請務必請學員修改，
  不要留著預設密碼。
- `integrations.office.secret` 必須跟
  [onlyoffice/manifest/02-secret.yaml](../onlyoffice/manifest/02-secret.yaml)
  的 `JWT_SECRET` **逐字一致**，兩邊任何一邊改了密鑰，另一邊也要跟著改，
  否則簽章對不上、編輯器打不開。
- `07-networkpolicy.yaml`（或 chart 的 NetworkPolicy 樣板）上課前請先
  實測，確認 filebrowser 真的能連到 onlyoffice，**而且 onlyoffice 那邊
  的 `allow-egress-onlyoffice-to-filebrowser` 規則也要一起套用**——這是
  雙向流量，兩邊都要開。
- `filebrowser-db` PVC 目前 1Gi，實測啟動時會有快取空間偏小的警告
  （不影響運作），有需要可調大。

### 驗證與教學觀察點

```bash
kubectl get pvc -n filebrowser                       # 兩顆 PVC 都要是 Bound
kubectl get pod -n filebrowser -o wide
kubectl exec -n filebrowser deploy/filebrowser -- df -h /srv /home/filebrowser/data   # 觀察掛載點
kubectl logs -n filebrowser deploy/filebrowser       # 確認 config.yaml / database 路徑讀取正確
kubectl exec -n filebrowser deploy/filebrowser -- wget -qO- http://onlyoffice.onlyoffice.svc.cluster.local/healthcheck
                                                      # 驗證 filebrowser -> onlyoffice 這個方向
kubectl exec -n onlyoffice deploy/onlyoffice -- curl -s http://filebrowser.filebrowser.svc.cluster.local/health
                                                      # 驗證 onlyoffice -> filebrowser 這個反方向（容易漏掉）
```

登入/整合功能驗證（Quantum 的登入 API 跟舊版不一樣，見上面「已實測
驗證」）：

```bash
kubectl port-forward -n filebrowser svc/filebrowser 18080:80

# 登入拿 token（注意是 query string + header，不是 JSON body）
TOKEN=$(curl -s -X POST "http://127.0.0.1:18080/api/auth/login?username=admin" -H "X-Password: admin")

# 上傳一個真正的 .docx 測試檔（不能是假內容，OnlyOffice 打不開）
curl -s -X POST "http://127.0.0.1:18080/api/resources?source=files&path=/test.docx&override=true" \
  -H "Authorization: Bearer $TOKEN" --data-binary "@/path/to/real.docx"

# 拿 OnlyOffice 編輯器設定，document.url 應該是
# http://filebrowser.filebrowser.svc.cluster.local/... 而不是外部網域
curl -s "http://127.0.0.1:18080/api/office/config?source=files&path=/test.docx" \
  -H "Authorization: Bearer $TOKEN"

# 測完記得清掉測試檔
curl -s -X DELETE "http://127.0.0.1:18080/api/resources?source=files&path=/test.docx" \
  -H "Authorization: Bearer $TOKEN"
```

最終還是建議實際用瀏覽器打開 `filebrowser.nexai.org.com`、上傳真正的
`.docx`、點開確認能進到 OnlyOffice 編輯畫面、打字、存檔、回列表看
「修改時間」有更新——前面的 API 驗證只能確認「設定串起來、檔案抓得到」，
JWT secret 兩邊是否真的一致，要等瀏覽器真的觸發 Document Server 驗證
token 才會知道。

### 清除環境

```bash
kubectl delete namespace filebrowser
```
