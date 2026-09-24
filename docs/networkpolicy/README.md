# NetworkPolicy 教學文件：零信任網路怎麼寫、怎麼驗證

這份文件教「NetworkPolicy 是什麼、為什麼要學、本教材的零信任寫法怎麼設計」，
搭配各產品目錄下 `manifest/*-networkpolicy.yaml` 的逐行教學註解一起看效果
最好——這裡講通用概念跟跨產品的對照，各產品自己的檔案負責講「這個產品
自己的細節」。所有本文件引用的「實測結果」都是 2026-09-23 在真實叢集上
現場執行擷取的輸出，不是紙上談兵。

## 目錄

1. [NetworkPolicy 在這門課的定位](#1-networkpolicy-在這門課的定位)
2. [核心概念](#2-核心概念)
3. [本教材共通的三層寫法慣例](#3-本教材共通的三層寫法慣例)
4. [各產品 NetworkPolicy 對照表](#4-各產品-networkpolicy-對照表)
5. [這座叢集的 Cilium 特有眉角](#5-這座叢集的-cilium-特有眉角)
6. [實測驗證：真的擋下來了嗎？](#6-實測驗證真的擋下來了嗎)
7. [常見錯誤與除錯](#7-常見錯誤與除錯)

---

## 1. NetworkPolicy 在這門課的定位

跟 [docs/rbac](../rbac/) 放在一起學效果最好，因為兩者剛好是**相反的預設
行為**，也管著完全不同的層面：

| | NetworkPolicy | RBAC |
|---|---|---|
| 管的是什麼 | Pod 之間、Pod 對外的**網路流量**能不能通 | 「誰」能對 **Kubernetes API** 做什麼操作 |
| 沒有任何規則時的預設行為 | **全通**（K8s 原生網路模型就是任兩個 Pod 互通） | **全拒絕**（見 [docs/rbac 第 6 節](../rbac/README.md)） |
| 本教材的因應方式 | 每個產品自己手動 `default-deny-all` 再逐條補洞 | 什麼都不用做，天生就是最小權限 |
| 生效的層面 | Cilium（CNI）在封包層面攔截 | kube-apiserver 在 API 請求層面攔截 |

換句話說：就算 NetworkPolicy 全部設對了，一個沒有 RBAC 授權的 Pod 還是能
呼叫 Kubernetes API（如果它連得到 kube-apiserver 的話）；反過來 RBAC 全部
鎖好，Pod 之間的 TCP 連線預設還是暢通無阻。**企業場景兩者都要做，缺一個
都不是真正的零信任。**

## 2. 核心概念

### `podSelector`：這條規則對「哪些 Pod」生效

```yaml
spec:
  podSelector:
    matchLabels:
      app: drawio
```

寫在 `spec.podSelector` 的是這份 NetworkPolicy**保護的對象**——只有符合
這個 label 的 Pod 才會被下面的 `ingress`/`egress` 規則影響。`{}`（空的）
代表「這個 namespace 裡的所有 Pod」，本教材每個產品的 `default-deny-all`
都是用這個寫法，確保沒有 Pod 漏網。

### `policyTypes`：管進站還是出站，還是兩者

```yaml
spec:
  policyTypes:
    - Ingress
    - Egress
```

Ingress（進站）跟 Egress（出站）是**分開管制**的兩件事，這是最常見的
理解誤區：放行了 A→B 的 ingress（B 這邊「允許 A 連進來」），不代表 A
那邊就有 egress 權限「連得出去」——A 自己也要有一條允許連到 B 的 egress
規則，兩邊都要開，缺一邊還是連不通（本教材 flarum 的
`allow-ingress-to-mysql-from-flarum` + `allow-egress-flarum-to-mysql`
就是示範這一組「一體兩面」的規則）。

### `from`/`to` 底下的兩種選擇器

| 選擇器 | 意義 | 本教材範例 |
|---|---|---|
| `podSelector` | 同一個 namespace 裡，符合 label 的 Pod | flarum 用它管制「只有 `app: flarum` 能連 `app: mysql`」 |
| `namespaceSelector` | 符合 label 的整個 namespace（該 namespace 裡所有 Pod 都算） | cloudbeaver 用它跨 namespace 連 flarum/planka/peertube 的資料庫 |

`namespaceSelector` 最常用 K8s **自動加在每個 namespace 上的內建標籤**
`kubernetes.io/metadata.name`（值就是 namespace 名稱本身）比對，不需要
額外手動打標籤——本教材所有跨 namespace 規則都是這樣寫的，比自訂標籤
更不容易忘記維護。

`namespaceSelector: {}`（空的）代表「不限 namespace」，本教材唯一這樣用
的地方是 `allow-egress-dns`：允許連到**任何** namespace，但 `ports`
只開 53（DNS），刻意留一個「範圍很寬但動作很窄」的例外。

### 為什麼每個產品都要單獨開一條 `allow-egress-dns`

`default-deny-all` 同時擋住 Ingress 跟 Egress 後，Pod 連 Service 的 DNS
名稱都解析不出來（DNS 查詢本身也是一種 egress 流量）——這是最容易忘記、
最容易讓學員以為「NetworkPolicy 套用後全部東西都壞掉」的地方，本教材
每個產品的第二、三條規則永遠是「先開放進站給 Gateway，再開放 DNS」，
確保拆解版一步步 apply 時，Pod 不會在還沒補齊業務規則前就連 DNS 都不通。

## 3. 本教材共通的三層寫法慣例

每個產品的 `*-networkpolicy.yaml` 都遵循同樣的骨架，差別只在「補洞」
的規則多寡：

```text
1) default-deny-all              全部擋下（podSelector: {}，Ingress + Egress）
2) allow-ingress-*-from-gateway  放行 Gateway 進來的流量到應用程式本身
3) allow-egress-dns              放行 DNS 查詢（見上一節）
4) （視產品而定）同 namespace 內部服務隔離，或跨 namespace 白名單
```

前三層每個產品幾乎一模一樣（只有 port 號跟 `app` label 值不同），第 4
層才是真正因產品而異、值得對照著看的部分——見下一節的對照表。

## 4. 各產品 NetworkPolicy 對照表

依 2026-09-23 `kubectl get networkpolicy -n <ns>` 現場查詢結果（draw.io
目前尚未套用，其餘 6 個都已上線）：

| 產品 | 規則數 | 第 4 層模式 | 這個產品獨有的教學重點 |
|---|---|---|---|
| draw.io | 3（**尚未套用**） | 無 | 唯一沒有第 4 層的產品——無狀態、無跨服務依賴，示範最簡骨架；`06-networkpolicy.yaml` 的檔頭明寫「上課前務必先實測」，見第 6 節 |
| filebrowser | 4 | 跨 namespace `namespaceSelector`（雙向） | **唯一雙向依賴**：filebrowser egress 連 onlyoffice:80，onlyoffice 也 egress 連 filebrowser:80（線上編輯文件時互相回呼），兩個產品的 NetworkPolicy 檔案裡各有一條對方的規則 |
| flarum | 6 | 同 namespace `podSelector`（app→mysql） | mysql 併入同一個 namespace 後的教材，示範「同 namespace 服務隔離」該用 `podSelector` 而非 `namespaceSelector`；另外加了給 cloudbeaver 的跨 namespace 例外 |
| planka | 6 | 同 namespace `podSelector`（app→postgres） | 跟 flarum 同一種模式的第二個範例，podSelector-to-podSelector 對照組；同樣額外放行 cloudbeaver |
| onlyoffice | 4 | 跨 namespace `namespaceSelector`（單向，見 filebrowser 那列） | 唯一因為 NetworkPolicy 擋到「應用程式自己要打的背景工作」而抓出真實 bug 的產品（`PLUGINS_ENABLED` CPU-loop，見 [[k8s_training_cluster_env]] 記憶） |
| peertube | 7 | 同 namespace `podSelector` ×2（app→postgres、app→redis） | 規則數最多，同時示範「一個 app Pod 對兩個不同同 namespace 後端各自單獨授權」 |
| cloudbeaver | 4 | 跨 namespace `namespaceSelector` ×3（egress 出去） | 唯一「主動連出去找三個不同 namespace」的產品，跟其他產品「被動被連進來」的方向相反，見第 6 節的實測 |

**跨產品共通的教學點**：全部產品的 `allow-ingress-*-from-gateway` 都用
`from: []`（不限來源）而不是限制特定來源——這是刻意的：Cilium 把
Gateway 送進 Pod 的流量視為叢集內部流量，來源 IP 是 Gateway Pod 自己
（不是外部使用者的真實來源 IP），沒有簡單的方式用 `podSelector`/
`namespaceSelector` 精準指到「只允許從 Gateway 來的流量」而不誤擋其他
合法內部流量，所以本教材選擇「Ingress 只限制 port，不限制來源」，把
真正的存取控制留給應用層（例如 flarum/planka 自己的帳號系統）。

## 5. 這座叢集的 Cilium 特有眉角

**Pod 身分是在建立當下決定的，之後幫 namespace 加 label 不會回溯生效。**
Cilium 是用 Pod 的 label（包含它所屬 namespace 的 label）計算出一個
「安全身分（security identity）」，這個身分是在 **Pod 建立時**算好的；
如果先有 Pod 在跑，之後才幫它的 namespace 加一個新 label（例如某個
`namespaceSelector` 規則要比對的自訂 label），這個已存在的 Pod 不會自動
拿到新身分，NetworkPolicy 的允許規則也不會生效，必須重建該 Pod
（`kubectl delete pod` 或 rollout restart）才會套用。本教材目前所有跨
namespace 規則都刻意改用 K8s 內建的 `kubernetes.io/metadata.name`
label（namespace 建立時就自動有，不是後補的自訂 label），從源頭迴避了
這個問題——但如果之後要示範自訂 namespace label 的寫法，這個順序陷阱
一定要提。

## 6. 實測驗證：真的擋下來了嗎？

以下全部是 2026-09-23 在真實叢集上現場執行、原汁原味擷取的指令與輸出，
用來證明「規則寫了不代表真的生效」——教學時務必帶學員實際做一次，而不
是只講 yaml。

### 6.1 已授權的跨 namespace 連線：cloudbeaver → flarum/planka 的資料庫

cloudbeaver 的 `allow-egress-cloudbeaver-to-databases` 允許它連到 flarum
的 mysql:3306 跟 planka 的 postgres:5432（`namespaceSelector` 比對
`kubernetes.io/metadata.name`）：

```bash
$ kubectl exec cloudbeaver-67cc4655c5-5q24n -n cloudbeaver -- \
    timeout 3 bash -c 'echo > /dev/tcp/mysql.flarum.svc.cluster.local/3306 && echo "TCP 連線成功 (allowed)"'
TCP 連線成功 (allowed)

$ kubectl exec cloudbeaver-67cc4655c5-5q24n -n cloudbeaver -- \
    timeout 3 bash -c 'echo > /dev/tcp/postgres.planka.svc.cluster.local/5432 && echo "TCP 連線成功 (allowed)"'
TCP 連線成功 (allowed)
```

### 6.2 同一個來源，換一個沒授權的 port：立刻被擋

同一個 cloudbeaver Pod，這次改打 flarum 應用程式本身的 8888 port（
`allow-egress-cloudbeaver-to-databases` 只開了 3306，沒開 8888）：

```bash
$ kubectl exec cloudbeaver-67cc4655c5-5q24n -n cloudbeaver -- \
    timeout 3 bash -c 'echo > /dev/tcp/flarum.flarum.svc.cluster.local/8888 && echo "TCP 連線成功"'
command terminated with exit code 124
```

`exit code 124` 是 `timeout` 指令本身的逾時代碼——連線被 Cilium 在封包
層面**直接丟棄**、完全沒有回應（不是收到 TCP RST 主動拒絕），這是
NetworkPolicy 被擋下時的典型現象，跟「port 沒人聽」的 `Connection
refused`（會立刻回應）是兩種不同的失敗訊號，除錯時要能分辨。

### 6.3 換一個完全沒被列入白名單的 namespace：一樣被擋

用 [docs/rbac](../rbac/) 那份文件建立的 `rbac-demo` namespace 當第三方
（它沒有出現在 flarum 的任何 NetworkPolicy 規則裡）：

```bash
$ kubectl exec debug-ns-pod-viewer -n rbac-demo -- nc -zv -w3 mysql.flarum.svc.cluster.local 3306
nc: mysql.flarum.svc.cluster.local (172.30.1.3:3306): Operation timed out
command terminated with exit code 1
```

同一個目的地（flarum 的 mysql:3306），cloudbeaver 連得到、`rbac-demo`
連不到——差別純粹是 NetworkPolicy 的 `namespaceSelector` 白名單有沒有
列到這個 namespace，不是目的地本身的問題。

### 6.4 DNS 沒有被一起擋下來

`default-deny-all` 理論上也擋住 DNS 查詢（egress），但每個產品都補了
`allow-egress-dns`，實測 flarum 自己的 Pod（default-deny-all 已生效中）
DNS 依然正常：

```bash
$ kubectl exec flarum-85b546f699-zfn4n -n flarum -- getent hosts mysql.flarum.svc.cluster.local
172.30.1.3      mysql.flarum.svc.cluster.local  mysql.flarum.svc.cluster.local
```

### 6.5 draw.io：這個產品的 NetworkPolicy 還沒套用過

對照組——draw.io 是全教材唯一 `06-networkpolicy.yaml` 存在但尚未
`kubectl apply` 的產品，檔頭特別註明「上課前請務必先實測」。原因是
Cilium 對 Gateway API 流量的身分判斷細節（見第 4 節最後一段）過去沒有
在這個產品上實際跑過，屬於已知風險而非疏漏。**上課前的待辦**：找一個
沒有學員在用 draw.io 的時段，`kubectl apply -f
apps/01-draw.io/manifest/06-networkpolicy.yaml` 之後，立刻用瀏覽器/
`curl` 走 `dev-gateway`（`drawio.nexai.org.com`）確認頁面還能正常打開，
再視結果決定要不要把這個檔案正式收進「已驗證」的產品清單。

## 7. 常見錯誤與除錯

| 現象 | 常見原因 | 排查方式 |
|---|---|---|
| 套用 `default-deny-all` 後整個 Pod 連 DNS 都解不出來 | 忘記加 `allow-egress-dns`，或漏了 `Egress` 的 `policyTypes` | `kubectl exec <pod> -- getent hosts <svc>.<ns>.svc.cluster.local` |
| A 說「我已經放行 B 連進來了」，B 還是連不到 A | 只補了 A 這邊的 ingress，B 自己沒有對應的 egress 規則（見第 2 節） | 檢查 B 的 NetworkPolicy 有沒有一條 egress 指向 A |
| 幫 namespace 加了新 label 給 `namespaceSelector` 用，規則卻沒生效 | Cilium Pod 身分在 Pod 建立時就固定了，新 label 不會回溯（見第 5 節） | 重建受影響的 Pod（`kubectl delete pod` 或 rollout restart） |
| 連線是 `Connection refused`，不是逾時 | 通常不是 NetworkPolicy 問題——是目的地 port 本身沒有服務在監聽 | 先確認 Service/Deployment 本身正常（`kubectl get endpoints`），NetworkPolicy 被擋通常是逾時，不是 refused |
| `kubectl apply` NetworkPolicy 後現有連線瞬間全部中斷 | Cilium 是即時生效的，套用當下就會重新評估所有連線，不會等到下一次連線才生效 | 正式上課前務必照第 6.5 節的方式先驗證過，不要邊上課邊套第一次 |
