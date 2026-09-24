#!/usr/bin/env bash
# =============================================================================
# write-postgres.sh — 在 dr-demo 的 PostgreSQL 寫入「災難驗證資料」。
#
# 備份前先寫一筆「只存在 PVC 裡」的資料，還原後查得到它，
# 才能證明「資料」救回來了，而不只是 Pod 又 Running 了。
# 可重複執行：table 已存在不會報錯，同一個 test_key 不會重複插入。
#
# 用法：./script/write-postgres.sh [namespace，預設 dr-demo] [test_key，預設 DR-TEST-DB-001]
# =============================================================================
set -euo pipefail
NS="${1:-dr-demo}"
KEY="${2:-DR-TEST-DB-001}"

kubectl -n "$NS" exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1 -U drtest -d drdemo <<SQL
CREATE TABLE IF NOT EXISTS disaster_test (
    id SERIAL PRIMARY KEY,
    test_key VARCHAR(100) NOT NULL,
    test_value VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO disaster_test(test_key, test_value)
SELECT '${KEY}', 'Kubernetes Disaster Recovery Test'
WHERE NOT EXISTS (SELECT 1 FROM disaster_test WHERE test_key = '${KEY}');
SELECT * FROM disaster_test ORDER BY id;
SQL
