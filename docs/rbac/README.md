# RBAC 教學文件：ServiceAccount / Role / ClusterRole 怎麼寫、怎麼驗證

課程原本的 7 個產品全部用 default ServiceAccount，沒有自訂 RBAC（見根目錄
`README.md` 的產品對照表），這是刻意的教材缺口——RBAC 是「誰能對
Kubernetes API 做什麼」的權限管控，跟任何一個產品本身要不要示範沒有關係，
獨立拉出來當一份延伸文件更適合完整地教。這裡新建了一個 `rbac-demo`
namespace，搭配 [`manifest/`](manifest/) 底下的真實物件，**已在真實叢集
上部署並實測驗證**（2026-09-23），不是紙上談兵的範例。

`rbac-demo` **不是課程原本 7 個產品之一**：它沒有 Service/HTTPRoute，
不對外服務，純粹是給這份文件搭配的教學資源，會長期留在叢集上（跟其他
產品一樣，不是測完就砍）。

## 目錄

1. [這個 namespace 放了什麼](#1-這個-namespace-放了什麼)
2. [核心概念](#2-核心概念)
3. [三組對照範例逐一拆解](#3-三組對照範例逐一拆解)
4. [實測驗證：真的擋下來了嗎？](#4-實測驗證真的擋下來了嗎)
5. [兩種模擬工具：`kubectl auth can-i` vs. 真的 exec 進 Pod](#5-兩種模擬工具kubectl-auth-can-i-vs-真的-exec-進-pod)
6. [常見錯誤與除錯](#6-常見錯誤與除錯)
7. [練習題](#7-練習題)

---

## 1. 這個 namespace 放了什麼

```text
manifest/
├── 00-namespace.yaml                     rbac-demo 這個 namespace
├── 01-resourcequota-limitrange.yaml       跟其他產品一樣的資源治理慣例（數字刻意抓很小）
├── 02-serviceaccount-no-permissions.yaml  對照組 1：沒有任何 RoleBinding 的 SA
├── 03-role-namespace-scoped.yaml          對照組 2：Role + RoleBinding（namespace 範圍）
├── 04-clusterrole-cluster-scoped.yaml     對照組 3：ClusterRole + ClusterRoleBinding（叢集範圍）
└── 05-debug-pods.yaml                     三支 debug Pod，各自掛一個上面的 ServiceAccount
```

`rbac-demo-all-in-one.yaml` 是內容跟 `manifest/` 完全一致的合併版，快速
重建環境用（沿用其他產品的慣例，見 `docs/manifest-conventions` 這類根目錄
說明）：

```bash
kubectl apply -f rbac-demo-all-in-one.yaml
```

## 2. 核心概念

### ServiceAccount：Pod 用來對 API Server 表明身分的憑證

每個 Pod 都會（不管有沒有明講）掛一個 ServiceAccount，K8s 自動把它的
token 掛進容器（預設路徑
`/var/run/secrets/kubernetes.io/serviceaccount/token`）。容器裡的
`kubectl`/任何 K8s client library 會自動讀這個 token 當作呼叫 API 時的
身分驗證，完全不需要另外設定 kubeconfig——這是「Pod 本身可以主動呼叫
Kubernetes API」這件事的根本機制。

### RBAC 的預設行為是「零權限」，跟 NetworkPolicy 完全相反

一個全新的 ServiceAccount，只要沒有任何 RoleBinding/ClusterRoleBinding
指到它，**連查自己 namespace 裡的 Pod 清單都做不到**。這跟
[docs/networkpolicy](../networkpolicy/) 教的「K8s 網路預設全通，要自己
`default-deny-all`」正好相反——RBAC 天生就是最小權限，不用額外設定什麼
就已經是「拒絕」，這也是第 4 節第一個實測案例要證明的事。

### Role vs. ClusterRole：差別在「能授權的資源範圍」，不是「綁在哪裡」

| | `Role` | `ClusterRole` |
|---|---|---|
| `rules` 能寫的資源 | 只能是 namespace 範圍的資源（Pod、ConfigMap、Deployment…） | namespace 範圍 + **叢集範圍**的資源（Node、Namespace、PersistentVolume…） |
| 物件本身有沒有 `namespace` 欄位 | 有，只在該 namespace 內有意義 | 沒有，它本身是叢集範圍的物件 |
| 常見誤解 | 以為「換更大的 RoleBinding」就能跨 namespace——**不行**，Role 天生就跨不出自己的 namespace | 以為 ClusterRole 一定代表「全叢集權限」——**不一定**，要看綁的是 RoleBinding 還是 ClusterRoleBinding（見下面） |

### RoleBinding vs. ClusterRoleBinding：差別在「授權生效的範圍」

這是最容易搞混的地方，因為 `roleRef` 兩種都能指 `Role` 或 `ClusterRole`
（但 `RoleBinding` 不能指到別的 namespace 的 `Role`），實際上有效組合是：

| 綁定 | `roleRef` 指到 | 生效範圍 |
|---|---|---|
| `RoleBinding` | `Role`（同 namespace） | 只在這個 namespace |
| `RoleBinding` | `ClusterRole` | 只在 `RoleBinding` 所在的 namespace（**借用**叢集預先定義好的權限樣板，但範圍仍被鎖在這個 namespace）——本教材沒有示範這組，但企業場景很常見（例如叢集內建的 `view`/`edit`/`admin` 這幾個 ClusterRole，常常用 RoleBinding 分別授權給不同 namespace） |
| `ClusterRoleBinding` | `ClusterRole` | **整個叢集**——本教材 `cluster-node-viewer-binding` 用的就是這組 |

被授權的 ServiceAccount 本身永遠屬於某個 namespace（這裡是
`rbac-demo`），跟它拿到的權限範圍是兩件事——`cluster-node-viewer` 這個
SA 活在 `rbac-demo` 裡，但透過 `ClusterRoleBinding` 拿到的是整個叢集的
Node/Namespace 讀取權，這正是第 3 節第三組對照要示範的重點。

## 3. 三組對照範例逐一拆解

### 對照組 1：`no-permissions`（[`02-serviceaccount-no-permissions.yaml`](manifest/02-serviceaccount-no-permissions.yaml)）

只建立 ServiceAccount，刻意不綁任何 Role/ClusterRole——這是 RBAC
「預設零權限」的基準線，第 4 節會證明它連自己 namespace 的 Pod 清單都
查不到。

### 對照組 2：`ns-pod-viewer`（[`03-role-namespace-scoped.yaml`](manifest/03-role-namespace-scoped.yaml)）

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "configmaps"]
    verbs: ["get", "list", "watch"]
```

namespace 範圍的最小權限：只能**讀** `rbac-demo` 這個 namespace 裡的
Pod/Pod 日誌/ConfigMap，`verbs` 完全沒有 `create`/`update`/`delete`。
第 4 節會證明：這個 SA 連刪除同 namespace 裡的 Pod 都做不到（verb 不在
清單裡），也讀不到別的 namespace（Role 跨不出自己的 namespace），更讀不
到 Node 這種叢集範圍資源。

### 對照組 3：`cluster-node-viewer`（[`04-clusterrole-cluster-scoped.yaml`](manifest/04-clusterrole-cluster-scoped.yaml)）

```yaml
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "watch"]
```

Node/Namespace 是叢集範圍資源，只有 `ClusterRole` 才能寫規則授權；用
`ClusterRoleBinding` 綁定後，這個活在 `rbac-demo` 裡的 SA 可以讀**整個
叢集**的 Node 跟 Namespace 清單——但也僅止於此，它一樣讀不到任何
namespace 裡的 Pod（`rules` 完全沒有 `pods` 這個資源）。

## 4. 實測驗證：真的擋下來了嗎？

以下是 2026-09-23 現場對三支 debug Pod（各自掛上面三個 SA）逐一
`kubectl exec` 進去下指令的真實輸出，**用的是 Pod 裡掛載的 SA token**，
不是模擬。

```bash
# 1) no-permissions：連自己 namespace 的 Pod 清單都查不到
$ kubectl exec debug-no-permissions -n rbac-demo -- kubectl get pods -n rbac-demo
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:rbac-demo:no-permissions"
cannot list resource "pods" in API group "" in the namespace "rbac-demo"

# 2) ns-pod-viewer：讀自己 namespace 的 Pod 沒問題
$ kubectl exec debug-ns-pod-viewer -n rbac-demo -- kubectl get pods -n rbac-demo
NAME                        READY   STATUS    RESTARTS   AGE
debug-cluster-node-viewer   1/1     Running   0          8m9s
debug-no-permissions        1/1     Running   0          8m9s
debug-ns-pod-viewer         1/1     Running   0          8m9s

# 3) ns-pod-viewer：但刪不掉（verb 沒有 delete）
$ kubectl exec debug-ns-pod-viewer -n rbac-demo -- kubectl delete pod debug-no-permissions -n rbac-demo
Error from server (Forbidden): pods "debug-no-permissions" is forbidden: User
"system:serviceaccount:rbac-demo:ns-pod-viewer" cannot delete resource "pods" in API group "" in the namespace "rbac-demo"

# 4) ns-pod-viewer：讀不到別的 namespace（Role 跨不出自己的 namespace）
$ kubectl exec debug-ns-pod-viewer -n rbac-demo -- kubectl get pods -n drawio
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:rbac-demo:ns-pod-viewer"
cannot list resource "pods" in API group "" in the namespace "drawio"

# 5) ns-pod-viewer：讀不到叢集範圍資源（Role 天生管不到 Node）
$ kubectl exec debug-ns-pod-viewer -n rbac-demo -- kubectl get nodes
Error from server (Forbidden): nodes is forbidden: User "system:serviceaccount:rbac-demo:ns-pod-viewer"
cannot list resource "nodes" in API group "" at the cluster scope

# 6) cluster-node-viewer：讀得到 Node（ClusterRole + ClusterRoleBinding 生效）
$ kubectl exec debug-cluster-node-viewer -n rbac-demo -- kubectl get nodes
NAME    STATUS   ROLES           AGE   VERSION
gpu01   Ready    <none>          46d   v1.35.7
k8s01   Ready    control-plane   46d   v1.35.7
k8s02   Ready    control-plane   46d   v1.35.7
k8s03   Ready    control-plane   46d   v1.35.7

# 7) cluster-node-viewer：讀得到全叢集的 Namespace（不是只有 rbac-demo）
$ kubectl exec debug-cluster-node-viewer -n rbac-demo -- kubectl get namespaces
NAME        STATUS   AGE
drawio      Active   5d1h
filebrowser Active   5d1h
flarum      Active   5d
...（省略，共列出叢集上全部 namespace，包含其他租戶的）

# 8) cluster-node-viewer：但一樣讀不到 Pod（ClusterRole 的 rules 沒有 pods 這個資源）
$ kubectl exec debug-cluster-node-viewer -n rbac-demo -- kubectl get pods -n rbac-demo
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:rbac-demo:cluster-node-viewer"
cannot list resource "pods" in API group "" in the namespace "rbac-demo"
```

8 種情境，全部符合預期——**RBAC 的授權是精確到「這個身分」×「這個動詞」
×「這個資源」×「這個範圍」的四維交集**，任何一維沒對上就是 Forbidden，
沒有「大概授權」這種模糊地帶。

## 5. 兩種模擬工具：`kubectl auth can-i` vs. 真的 exec 進 Pod

上一節是「真的用 Pod 裡的 token 打 API」，比較貼近真實情境，但每次都要
`exec` 進 Pod 比較慢；日常開發/教學快速確認時，更常用
`kubectl auth can-i --as=<身分>` 直接從自己的終端機模擬：

```bash
$ kubectl auth can-i list pods -n rbac-demo --as=system:serviceaccount:rbac-demo:no-permissions
no
$ kubectl auth can-i list pods -n rbac-demo --as=system:serviceaccount:rbac-demo:ns-pod-viewer
yes
$ kubectl auth can-i delete pods -n rbac-demo --as=system:serviceaccount:rbac-demo:ns-pod-viewer
no
$ kubectl auth can-i list nodes --as=system:serviceaccount:rbac-demo:cluster-node-viewer
yes
$ kubectl auth can-i list pods -n rbac-demo --as=system:serviceaccount:rbac-demo:cluster-node-viewer
no
```

結果跟第 4 節完全一致——這是因為 `--as` 是請 kube-apiserver **用同一套
授權邏輯**去模擬「如果這個身分發出這個請求會不會通過」，不是另一套獨立
規則，可以放心當成正式驗證的等效捷徑，只是它不會實際執行這個動作
（適合拿來在 apply 一個新 Role 之前，先確認寫得對不對）。

還可以用 `--list` 一次列出某個身分完整的權限清單，教學上很適合拿來
「總結這個 SA 到底能做什麼」：

```bash
$ kubectl auth can-i --list --as=system:serviceaccount:rbac-demo:ns-pod-viewer -n rbac-demo
Resources                                       ...   Verbs
configmaps                                      ...   [get list watch]
pods/log                                        ...   [get list watch]
pods                                            ...   [get list watch]
...（其餘是每個身分都有的內建自我檢查權限，例如 selfsubjectaccessreviews）
```

`kubectl describe role`/`kubectl describe clusterrole` 則是反過來，從
「這個角色」查它的規則本身（不綁定特定身分）：

```bash
$ kubectl describe role pod-viewer -n rbac-demo
PolicyRule:
  Resources   Verbs
  ---------   -----
  configmaps  [get list watch]
  pods/log    [get list watch]
  pods        [get list watch]

$ kubectl describe clusterrole node-viewer
PolicyRule:
  Resources   Verbs
  ---------   -----
  namespaces  [get list watch]
  nodes       [get list watch]
```

## 6. 常見錯誤與除錯

| 現象 | 常見原因 | 排查方式 |
|---|---|---|
| 明明寫了 Role，SA 還是什麼都不能做 | 忘記寫 RoleBinding，或 RoleBinding 的 `subjects`/`roleRef` 名稱打錯字 | `kubectl describe rolebinding <name> -n <ns>`，確認 `Subjects`/`Role` 兩邊名稱都對得上 |
| 授權了 Role，但另一個 namespace 還是讀不到 | Role 天生就是 namespace 範圍，跨不出去（見第 2 節） | 需要跨 namespace 就要改用 ClusterRole + ClusterRoleBinding，或在目標 namespace 也建一份 RoleBinding |
| ClusterRole 建好了，SA 卻還是 Forbidden | 只建了 ClusterRole 物件本身，沒有對應的 ClusterRoleBinding（或 RoleBinding）把它綁給這個 SA | 確認有一個 Binding 物件的 `subjects` 指到這個 SA，`roleRef` 指到這個 ClusterRole |
| `kubectl auth can-i` 回答的結果，跟 Pod 裡實際 exec 測出來的不一樣 | 通常是 `--as` 打錯了完整身分字串（漏了 `system:serviceaccount:` 前綴，或 namespace/名稱打錯） | 完整格式是 `system:serviceaccount:<namespace>:<serviceaccount 名稱>`，一個字都不能少 |
| 改了 Role 的 `rules`，Pod 裡的行為卻沒有立刻反映 | 這其實**不是**常見問題——RBAC 規則是即時生效的（不像 Cilium Pod 身分那樣需要重建 Pod，見 [docs/networkpolicy 第 5 節](../networkpolicy/README.md#5-這座叢集的-cilium-特有眉角)），多半是看錯了測試用的是哪個身分 | 用 `kubectl auth can-i --list --as=<身分>` 重新確認目前生效的完整規則 |

## 7. 練習題

1. 幫 `ns-pod-viewer` 的 Role 加一條規則，讓它可以 `create`
   `pods/exec`（等於能對 Pod 下 `kubectl exec`），套用後用第 4/5 節的
   兩種方法驗證是否真的生效。
2. 修改 `cluster-node-viewer-binding`，把 `roleRef.kind` 從
   `ClusterRole` 改成 `Role`（先在 `rbac-demo` 裡建一個同名的空
   `Role`）觀察會發生什麼事——這是為了印證第 2 節「roleRef 指到
   ClusterRole 不代表一定是全叢集範圍，要看 Binding 種類」這句話。
3. 用 `kubectl create rolebinding` 直接在指令列（不寫 yaml）建一個
   RoleBinding，把叢集內建的 `view` ClusterRole 綁給
   `no-permissions` 這個 SA（只在 `rbac-demo` 這個 namespace 生效），
   驗證它現在能讀哪些資源、還是讀不到哪些（`view` 這個內建角色本身
   也刻意不給 Secret 的讀取權，是另一個值得對照的「內建最小權限
   設計」範例）。
