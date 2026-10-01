#!/usr/bin/env bash
# =============================================================================
# check-data.sh — 用「實際資料」判斷還原是否成功，而不是看 Pod 狀態。
#
# 檢查三件事：
#   1. K8s 資源：Pod / Service / PVC 都在、PVC 是 Bound
#   2. 資料庫：disaster_test 表裡有 DR-TEST-DB-001
#   3. CephFS：/shared/dr-test.txt 內容含 DR-TEST-FS-001
# CephFS 用一個「只讀」的臨時 Pod 檢查，不依賴 cephfs-test-1/2 是否存在，
# 也避免 cephfs-test-1 重新啟動時重寫檔案、讓人誤以為資料有回來。
#
# 用法：./script/check-data.sh [namespace，預設 dr-demo]
#   還原到新 namespace 時：./script/check-data.sh dr-demo-restore
# 結束碼：全部通過 0，任一失敗 1（可放進自動化 Restore Test）
# =============================================================================
set -uo pipefail
NS="${1:-dr-demo}"
FAIL=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; FAIL=1; }

echo "== 1. Kubernetes 資源（namespace: $NS）"
kubectl -n "$NS" get pods,svc,pvc 2>&1 | sed 's/^/     /'
for pvc in postgres-data shared-data; do
  phase=$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = "Bound" ] && pass "PVC $pvc Bound" || fail "PVC $pvc 狀態=${phase:-不存在}"
done

echo "== 2. PostgreSQL 資料"
out=$(kubectl -n "$NS" exec deploy/postgres -- psql -U drtest -d drdemo -tAc \
      "SELECT test_key FROM disaster_test WHERE test_key='DR-TEST-DB-001';" 2>&1)
if [ "$out" = "DR-TEST-DB-001" ]; then pass "disaster_test 查得到 DR-TEST-DB-001"
else fail "查不到 DR-TEST-DB-001（輸出：$out）"; fi

echo "== 3. CephFS 資料"
POD="cephfs-verify-$$"
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: verify
      image: busybox:1.36
      command: ["cat", "/shared/dr-test.txt"]
      volumeMounts:
        - { name: shared, mountPath: /shared, readOnly: true }
  volumes:
    - name: shared
      persistentVolumeClaim: { claimName: shared-data, readOnly: true }
YAML
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=180s >/dev/null 2>&1
content=$(kubectl -n "$NS" logs "$POD" 2>&1)
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1
if echo "$content" | grep -q "DR-TEST-FS-001"; then pass "dr-test.txt 含 DR-TEST-FS-001"
else fail "dr-test.txt 內容不符（輸出：$content）"; fi

echo
[ $FAIL = 0 ] && echo "結果：還原驗證通過 ✅" || echo "結果：還原驗證失敗 ❌"
exit $FAIL
