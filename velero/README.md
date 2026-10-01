# Velero

## 範例資料


範例
* [backup](./01-backup/backup-dr-demo.yaml)
* [restore-new-ns](./02-restore/restore-to-new-namespace.yaml)
* [restore-same-ns](./02-restore/restore-dr-demo.yaml)
* [schedule](./04-schedule/schedule-daily-full.yaml)

檢查內容:

```bash
# rook-ceph-block（RWO）
kubectl -n dr-demo exec deploy/postgres -- \
  psql -U drtest -d drdemo \
  -c "SELECT * FROM disaster_test;"

# rook-cephfs（RWX）。
kubectl -n dr-demo exec cephfs-test-1 -- cat /shared/dr-test.txt

kubectl -n dr-demo exec cephfs-test-2 -- cat /shared/dr-test.txt



# rook-ceph-block（RWO）
kubectl -n dr-demo-restore exec deploy/postgres -- \
  psql -U drtest -d drdemo \
  -c "SELECT * FROM disaster_test;"

# rook-cephfs（RWX）。
kubectl -n dr-demo-restore exec cephfs-test-1 -- cat /shared/dr-test.txt

kubectl -n dr-demo-restore exec cephfs-test-2 -- cat /shared/dr-test.txt
```