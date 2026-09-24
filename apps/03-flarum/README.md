# Flarum

極簡、輕量且現代化的開源討論區/論壇軟體，前端體驗極佳。

## K8s 教育訓練用途

課程第四個範例，也是目前踩坑最多、最值得講給學員聽的一個。mysql 直接
併在這個產品的 namespace 裡（`02~04` 號檔案）——盤點下來 mysql 從頭到尾
只有 flarum 一個消費者，比照 planka 把 postgres 併進自己 namespace 的
做法，不需要獨立成一個共用的 mysql 產品：

- **initContainer**：本課程第一次出現。兩顆 PVC（`flarum-storage`、
  `flarum-assets`）一開始是空的，但 Flarum 期待這些路徑底下已經有
  特定子目錄結構，所以用 initContainer 在主容器啟動前先建好目錄、
  調整好權限。
- **image 把整個 app 烘進去、只掛「資料類」子目錄，不掛整個 app 目錄**：
  很多 docker-compose 範例會把整個 `/flarum/app` 掛成一個 volume——
  這招在 Kubernetes 行不通（PVC 會直接蓋掉 image 裡的程式碼），
  只掛 `storage/`、`public/assets/` 這種真正屬於「資料」的子目錄才對。
- **`enableServiceLinks: false`（實測踩到的真坑）**：Kubernetes 預設會
  幫每個 Pod 依「namespace 裡看得到的 Service」自動注入
  `<SVC名稱>_PORT` 這類環境變數。這個 Service 叫 `flarum`，
  Flarum 應用程式自己剛好也有一個叫 `FLARUM_PORT` 的設定變數——
  兩者撞名，K8s 自動注入的值把應用程式原本的設定蓋掉，
  導致 nginx 設定套用到錯誤的埠號、直接啟動失敗。這是能拿來跟學員講
  「Kubernetes 幫你做的『貼心』事，有時候反而是坑」的活教材，
  解法是在 Pod spec 關掉這個機制（我們本來就用 DNS 做服務發現，
  根本不需要這組舊式 env 注入）。
- **Secret 同 namespace 可以互相引用**：`mysql-secret`（02 號檔案）跟
  `flarum-secret`（05 號檔案）是兩個獨立的 Secret 物件，但 flarum 的
  Deployment 直接用 `secretKeyRef` 讀 `mysql-secret` 的 `MYSQL_PASSWORD`
  當作 `DB_PASS`——這是 mysql 還是獨立產品、Secret 跨 namespace 不能
  互相引用時做不到的事；併進同一個 namespace 之後，不用再手動複製
  一份密碼。
- **NetworkPolicy 改成同 namespace 版本的零信任隔離**：跟 mysql 還是
  獨立產品時「跨 namespace namespaceSelector + 標籤白名單」的寫法不同，
  現在用 podSelector 示範「同一個 namespace 內部的服務隔離」——只有
  `app=flarum` 的 Pod 可以連到 `app=mysql` 的 3306，其他 Pod（就算在
  同一個 namespace）一樣連不到，跟 planka 的 postgres 是同一種寫法。

提供三種形式，跟其他產品的教學走法一致：

| 目錄/檔案 | 用途 |
|---|---|
| [manifest/](manifest/) | 教學主線：11 支編號檔案，一支一支 apply |
| [flarum-all-in-one.yaml](flarum-all-in-one.yaml) | 合併版單檔 |
| [chart/](chart/) | Helm Chart 版本 |
| [exercises/](exercises/) | **學員練習**：半成品 YAML 填空 + 埋錯除錯兩種題型，含架構圖、提示與驗收標準，`manifest/` 就是這些題目的正解 |

**前置條件**：先套用共用的教學 Gateway（跟其他產品共用同一個）：
```bash
kubectl apply -f ../shared-infra/00-dev-gateway.yaml
```

### 方式一：教學主線

```bash
kubectl apply -f manifest/00-namespace.yaml
kubectl apply -f manifest/01-resourcequota-limitrange.yaml
kubectl apply -f manifest/02-mysql-secret.yaml
kubectl apply -f manifest/03-mysql-service.yaml
kubectl apply -f manifest/04-mysql-statefulset.yaml
kubectl apply -f manifest/05-flarum-secret.yaml
kubectl apply -f manifest/06-flarum-pvc.yaml
kubectl apply -f manifest/07-flarum-deployment.yaml
kubectl apply -f manifest/08-flarum-service.yaml
kubectl apply -f manifest/09-httproute.yaml
kubectl apply -f manifest/10-networkpolicy.yaml   # 進階、選用
```

### 方式二：合併版一次套用

```bash
kubectl apply -f flarum-all-in-one.yaml
```

### 方式三：Helm Chart

```bash
kubectl apply -f manifest/00-namespace.yaml
helm install flarum ./chart -n flarum
# 移除：helm uninstall flarum -n flarum
```

### 上課前請先確認 / 調整

- `07-flarum-deployment.yaml`（或 chart 的 `forum.url`）裡的 `FORUM_URL`
  要跟 `09-httproute.yaml` 的 `hostnames` 一致，並確認 DNS/hosts 指向
  `dev-gateway` 的 EXTERNAL-IP。
- `02-mysql-secret.yaml`/`05-flarum-secret.yaml`（或 `values.yaml`）裡的
  密碼僅供教學使用。
- 預設管理員帳號密碼是 `admin` / `TrainingAdmin123!`（見
  `FLARUM_ADMIN_USER`/`FLARUM_ADMIN_PASS`），上課示範完請提醒學員修改。
- 第一次啟動會實際跑 Flarum 的安裝流程（連線 MySQL、建表），
  `readinessProbe` 的 `initialDelaySeconds`/`failureThreshold` 給得比較
  寬鬆，正常約 30～60 秒內會就緒。

### 驗證與教學觀察點

```bash
kubectl get pod,statefulset -n flarum -o wide
kubectl logs -n flarum deploy/flarum -c init-storage-dirs   # initContainer 做了什麼
kubectl logs -n flarum deploy/flarum -c flarum --tail=30    # 應用程式本身的啟動過程
kubectl get pvc -n flarum
kubectl exec -n flarum mysql-0 -- mysql -uroot -p"$(kubectl get secret mysql-secret -n flarum -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)" -e "SHOW DATABASES;"
```

### 清除環境

```bash
kubectl delete namespace flarum
```
