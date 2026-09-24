# OTWLD Velero UI（Velero 第三方開源介面）

本課程單元 3 / 4 用它建立 Backup 與 Restore。專案：
[otwld/velero-ui](https://github.com/otwld/velero-ui)，文件：
[velero-ui.docs.otwld.com](https://velero-ui.docs.otwld.com)。

| 項目 | 線上現況（2026-09-23） |
|---|---|
| Helm chart / App 版本 | `velero-ui-0.15.0` / `otwld/velero-ui:0.10.2` |
| namespace | `velero-ui` |
| 網址 | `https://velero.nexai.org.com`（HTTPRoute 掛在 `admin-gateway`） |
| 登入 | 內建帳密（`BASIC_AUTH_ENABLED`），另支援 OAuth/OIDC、LDAP、RBAC policy |
| 權限 | ServiceAccount `velero-ui` 綁定 **cluster-admin** |

## 安裝

```bash
helm repo add otwld https://helm.otwld.com/
helm repo update

helm install velero-ui otwld/velero-ui \
  --namespace velero-ui \
  --create-namespace

# 記得修改 hostname (DNS name)
kubectl apply -f velero-ui.yaml

# 確認
kubectl -n velero-ui get pods,svc
kubectl -n velero-ui get httproute velero-ui \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}'   # Accepted=True、ResolvedRefs=True
```

## UI 與 Velero 的關係

UI 不會「自己備份」——它只是幫你建立 Velero 的 CR：

```text
UI 精靈送出 ──▶ velero namespace 裡建立 Backup / Restore / Schedule 物件 ──▶ Velero server 執行
```

所以：

- UI 做的每一件事，都能用 `kubectl -n velero get backup <name> -o yaml` 看到實際內容。
- UI 掛了，備份照常執行；Velero server 掛了，UI 按什麼都沒用。
- 判斷備份 / 還原是否成功，以 CR 的 `status` 與實際資料為準（見單元 3 第 8 節、單元 4 第 9 節）。

## 安全提醒

- ServiceAccount 是 **cluster-admin**：能登入 UI 的人，等同能在叢集中建立 / 還原
  任何資源（包括還原舊的 Secret、覆蓋其他 namespace）。
- 建議：開啟 OIDC 或至少強密碼、HTTPRoute 只掛在管理用 Gateway、
  用 UI 內建的 RBAC policy 限制一般使用者只能看不能刪。
- 叢集中另有一套 `vui`（seriohub Velero UI，`velero.nexai.org.com`），本課程不使用。
