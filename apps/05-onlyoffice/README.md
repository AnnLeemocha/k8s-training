# ONLYOFFICE

強大的線上 Office 辦公套件，支援 Word、Excel、PPT 的線上即時共同編輯，可與 Nextcloud 或 Filebrowser 整合。

## K8s 教育訓練用途

課程第六個範例，也是目前資源需求最重的一個（官方建議至少 2 CPU /
4GB RAM，內建自己的 PostgreSQL/Redis/RabbitMQ，全部包在同一個
container 裡）。重點不在應用邏輯，而在「資源緊繃的共用叢集，該怎麼
安排一個吃重的工作負載」：

- ⚠️ **上課前務必先確認叢集資源**：這座叢集 `k8s01~k8s03` 三台
  Node 目前實際記憶體使用率已經 81~85%（`kubectl top nodes`），
  硬把這個 4GB 建議規格的產品排上去，有拖垮整個 Node、波及其他
  共用工作負載（這座叢集還跑著 Rancher/Ceph/Velero）的風險。
- **nodeSelector + toleration**：`gpu01` 目前記憶體使用率最低
  （~24%），但它有 `nvidia.com/gpu=true:NoSchedule` 的 taint（保留給
  真正需要 GPU 的工作負載）。這裡用 `nodeSelector` 指定排到
  `gpu01`，並加上對應 `toleration`，讓一個完全不需要 GPU 的 Pod
  也能排過去——藉此講「taint/toleration 不是只服務 GPU 排程，
  任何『這個節點保留給特定用途』的情境都適用」。
- **實測發現：官方文件的 4GB 是保守值**，穩定狀態下實測記憶體用量
  約 400~500Mi，遠低於官方建議；但第一次啟動時的字型/主題產生
  作業會短暫吃滿 CPU limit，這是一次性行為，不是穩定負載。
- ⚠️ **實測踩到的坑：`PLUGINS_ENABLED=false`**——預設會在背景嘗試連
  `github.com` 下載外掛清單，這座叢集的 NetworkPolicy 只放行 DNS 跟
  Gateway 進來的流量，沒開對外網際網路，這個背景行程會不斷重試、
  卡在近乎吃滿 1 核心 CPU 的迴圈裡。已經關閉，可以藉此講「零信任
  網路下，這種預設會打外網的背景工作要嘛開白名單、要嘛乾脆關掉」。
- **持久化刻意簡化**：只掛 `/var/www/onlyoffice/Data`
  這一個路徑用 PVC，log/cache 用 `emptyDir`。內建的 PostgreSQL/
  RabbitMQ 資料路徑跟安裝的套件版本強綁定，要正確持久化需要更多
  細節，這裡教學上刻意不展開（也呼應叢集資源吃緊、不適合再多開
  外部 PostgreSQL/Redis/RabbitMQ 服務的現實）。重開 Pod 會重置內部
  資料庫/訊息佇列狀態，但不影響「重新提供服務」這件事。正式環境
  建議接外部 DB/Redis/RabbitMQ，可以當進階討論題目。

提供三種形式，跟其他產品的教學走法一致：

| 目錄/檔案 | 用途 |
|---|---|
| [manifest/](manifest/) | 教學主線：8 支編號檔案，一支一支 apply |
| [onlyoffice-all-in-one.yaml](onlyoffice-all-in-one.yaml) | 合併版單檔 |
| [chart/](chart/) | Helm Chart 版本 |
| [exercises/](exercises/) | **學員練習**：半成品 YAML 填空 + 埋錯除錯兩種題型，含架構圖、提示與驗收標準，`manifest/` 就是這些題目的正解 |

**前置條件**：

```bash
kubectl top nodes                                   # 上課前先確認節點資源狀況
kubectl apply -f ../shared-infra/00-dev-gateway.yaml
```

### 方式一：教學主線

```bash
kubectl apply -f manifest/00-namespace.yaml
kubectl apply -f manifest/01-resourcequota-limitrange.yaml
kubectl apply -f manifest/02-secret.yaml
kubectl apply -f manifest/03-pvc.yaml
kubectl apply -f manifest/04-deployment.yaml
kubectl apply -f manifest/05-service.yaml
kubectl apply -f manifest/06-httproute.yaml
kubectl apply -f manifest/07-networkpolicy.yaml   # 進階、選用
```

### 方式二：合併版一次套用

```bash
kubectl apply -f onlyoffice-all-in-one.yaml
```

### 方式三：Helm Chart

```bash
kubectl apply -f manifest/00-namespace.yaml
helm install onlyoffice ./chart -n onlyoffice
# 移除：helm uninstall onlyoffice -n onlyoffice
```

### 上課前請先確認 / 調整

- 第一次啟動要等內部好幾個服務（postgres/redis/rabbitmq/docservice/
  字型產生）都跑完，實測約 1~2 分鐘才會 Ready，屬正常現象。
- 如果 `gpu01` 之後真的要跑 GPU 工作負載、資源被排擠，記得把這個
  namespace 刪掉或調整 `nodeSelector` 到其他有空間的 Node。
- `JWT_SECRET` 僅供教學使用，若要跟 filebrowser 等其他系統整合，
  對方也要用同一把金鑰簽 token。
- 若要跟 [filebrowser](../filebrowser/)（FileBrowser Quantum）整合：
  `07-networkpolicy.yaml` 的 `allow-egress-onlyoffice-to-filebrowser`
  規則要記得套用——**OnlyOffice 整合是雙向網路流量**，Document Server
  收到編輯請求後會自己主動回頭連 filebrowser 抓檔案／回報存檔結果，
  只開 filebrowser → onlyoffice 那個方向會導致編輯器顯示「目前無法
  存取該檔案」，詳見 [filebrowser/README.md](../filebrowser/README.md)
  的「實測踩到的三個坑」。

### 驗證與教學觀察點

```bash
kubectl get pod -n onlyoffice -o wide
kubectl top pod -n onlyoffice                 # 觀察實際資源用量 vs. quota/limit
curl -k -H "Host: onlyoffice.nexai.org.com" http://<dev-gateway-IP>/healthcheck
```

### 清除環境

```bash
kubectl delete namespace onlyoffice
```
