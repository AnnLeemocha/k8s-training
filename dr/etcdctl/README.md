# etcdctl / etcdutl

單元 6 / 7 使用。版本必須與叢集 etcd 相同：本叢集是 **etcd 3.6.6**
（`registry.k8s.io/etcd:3.6.6-0`）。

| 工具 | 用途 | 需要連線到 etcd？ |
|---|---|---|
| `etcdctl` | `snapshot save`、`member list`、`endpoint status/health`、`get` | 是（mTLS） |
| `etcdutl` | `snapshot status`、`snapshot restore`、`defrag`（離線） | 否，直接操作檔案 |

> etcd 3.6 已移除 `etcdctl snapshot restore` / `snapshot status`，一律改用 `etcdutl`。
> 網路上舊教材的指令要注意。

## 安裝（在 control-plane 節點或管理機上）

```bash
ETCD_VER=v3.6.6
curl -fsSL https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz \
  -o /tmp/etcd-${ETCD_VER}.tar.gz
tar xzf /tmp/etcd-${ETCD_VER}.tar.gz -C /tmp
sudo install /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
sudo install /tmp/etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin/
etcdctl version && etcdutl version
```

不想在節點上裝東西時，也可以直接用 etcd Pod 內建的 `etcdctl`：

```bash
kubectl -n kube-system exec etcd-k8s01 -- etcdctl version
```

## 常用參數（kubeadm 預設憑證路徑）

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://10.90.1.81:2379,https://10.90.1.82:2379,https://10.90.1.83:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key
# 讀取這些憑證需要 root：sudo -E etcdctl ...

etcdctl member list -w table
etcdctl endpoint status -w table          # leader、DB SIZE、RAFT INDEX
etcdctl endpoint health -w table

# 備份（只連一個 endpoint）
etcdctl --endpoints=https://127.0.0.1:2379 snapshot save /tmp/snap.db
etcdutl snapshot status /tmp/snap.db -w table
```

⚠️ etcd 裡有叢集所有 Secret（本叢集有靜態加密，但仍屬高度敏感），
snapshot 檔案與上述憑證都要當成最高機密處理。
