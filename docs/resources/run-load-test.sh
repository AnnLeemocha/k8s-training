#!/usr/bin/env bash
# 一次執行找出「單一 Pod」的容量邊界，並給出 requests/limits/HPA 建議值，
# 最後列出「之後想再加一個 replica，需要改動哪些地方」的檢查清單。
#
# 用法：
#   ./run-load-test.sh <namespace> <deployment-name> <app-label-value> <host-header>
#
# 範例（draw.io）：
#   ./run-load-test.sh drawio drawio drawio drawio.nexai.org.com
#
# 可用環境變數調整壓測的階梯（有預設值，通常不用改）：
#   START_VUS=5 STEP_VUS=5 STEP_DURATION=30s MAX_STEPS=30 \
#   P95_THRESHOLD_MS=800 ERROR_RATE_THRESHOLD=0.05 SAMPLE_INTERVAL=5 \
#   ./run-load-test.sh drawio drawio drawio drawio.nexai.org.com
#
# 預設只打 `/`，這對純前端 SPA（例如 draw.io）會嚴重低估真實負載——`/`
# 常常只是幾 KB 的靜態 HTML 外殼，真實使用者打開頁面時瀏覽器還會接著
# 下載 JS/CSS 等應用程式本體。想測「完整頁面載入」的真實負載，用
# EXTRA_ASSET_PATHS 帶上這些資源的相對路徑（逗號分隔），並視情況調高
# THINK_TIME_SEC（模擬使用者看到頁面後的思考時間，避免每秒重複下載整包
# 資源）。以 draw.io 為例（資源路徑是從它的 index.html 裡實際量出來的）：
#   EXTRA_ASSET_PATHS="js/app.min.js,js/extensions.min.js,js/shapes-14-6-5.min.js,js/stencils.min.js,styles/grapheditor.css" \
#   THINK_TIME_SEC=5 START_VUS=2 STEP_VUS=2 \
#   ./run-load-test.sh drawio drawio drawio drawio.nexai.org.com
# （每個 VU 每輪要多傳輸約 21MB，STEP_VUS 建議比純測 `/` 時抓小一點）
#
# !!! 這個腳本會暫時改動叢集上的真實狀態 !!!
#   1) 記錄並暫停目標 Deployment 對應的 HPA（如果有的話）
#   2) 把目標 Deployment 暫時縮到 replicas=1
#      （這樣量到的容量邊界才是「一個 Pod」的真實邊界，不會被 HPA 中途
#        加開新 Pod、或本來就有多個 replica 分攤流量而稀釋掉）
#   3) 測試結束後一定會還原（成功/失敗/Ctrl-C 中斷都會，靠 trap 保證）
# 不要在有學員正在使用這個產品、或正式上課中的時段執行。
#
# 前提：
#   - kubectl 已連上目標叢集，且有權限在 default namespace 建立 Job/ConfigMap，
#     以及在目標 namespace 縮放 Deployment / 刪除+重建 HPA
#   - metrics-server 已啟用，否則 kubectl top pod 會沒有資料
#   - 需要 jq（用來讀寫 HPA/ResourceQuota 的 JSON）

set -euo pipefail

NAMESPACE="${1:?用法: $0 <namespace> <deployment-name> <app-label-value> <host-header>}"
DEPLOYMENT="${2:?缺少 Deployment 名稱}"
APP_LABEL="${3:?缺少 app label 值（Deployment 的 template.metadata.labels.app）}"
HOST_HEADER="${4:?缺少 Host header（HTTPRoute 的 hostnames[0]）}"

START_VUS="${START_VUS:-5}"
STEP_VUS="${STEP_VUS:-5}"
STEP_DURATION="${STEP_DURATION:-30s}"
MAX_STEPS="${MAX_STEPS:-30}"
EXTRA_ASSET_PATHS="${EXTRA_ASSET_PATHS:-}"
THINK_TIME_SEC="${THINK_TIME_SEC:-1}"
P95_THRESHOLD_MS="${P95_THRESHOLD_MS:-800}"
ERROR_RATE_THRESHOLD="${ERROR_RATE_THRESHOLD:-0.05}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"
# 秒數（純數字，不要帶單位）。輪詢 Job 狀態的總預算；改用輪詢而不是
# `kubectl wait --for=condition=complete`，是因為那個指令只認 Complete
# 這個條件，如果 Job 其實是 Failed（例如 k6 腳本本身噴錯），它不會提早
# 返回，會傻等到整個 timeout 用完，等到那時候 Job 早就被
# ttlSecondsAfterFinished 回收、log 也抓不到了。
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-1800}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-5}"
# 上線後預期同時在線的尖峰人數，只用來在 HPA 建議裡示範 maxReplicas 怎麼算，
# 不影響壓測本身；請依實際情況覆寫，例如 EXPECTED_PEAK_USERS=200。
EXPECTED_PEAK_USERS="${EXPECTED_PEAK_USERS:-100}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="k6-resource-test-$(date +%s)"
GATEWAY_SVC="cilium-gateway-dev-gateway.default.svc.cluster.local"
SAMPLE_FILE="$(mktemp)"
HPA_BACKUP_FILE="$(mktemp)"
ORIG_REPLICAS=""
HPA_NAME=""
SAMPLER_PID=""

cleanup() {
  echo "== 還原叢集狀態（Job/ConfigMap/Deployment replicas/HPA）==" >&2
  [ -n "${SAMPLER_PID}" ] && kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
  kubectl delete job "${RUN_ID}" -n default --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap "${RUN_ID}-script" -n default --ignore-not-found >/dev/null 2>&1 || true
  if [ -n "${ORIG_REPLICAS}" ]; then
    echo "還原 ${DEPLOYMENT} 的 replicas 為 ${ORIG_REPLICAS}" >&2
    kubectl scale "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --replicas="${ORIG_REPLICAS}" >/dev/null || true
  fi
  if [ -s "${HPA_BACKUP_FILE}" ]; then
    echo "還原 HPA ${HPA_NAME}" >&2
    kubectl apply -f "${HPA_BACKUP_FILE}" >/dev/null || true
  fi
  rm -f "${SAMPLE_FILE}" "${HPA_BACKUP_FILE}"
}
trap cleanup EXIT

echo "== 0/5 記錄現況、暫停 HPA、把 ${DEPLOYMENT} 縮到 1 個 replica ==" >&2
ORIG_REPLICAS="$(kubectl get "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}')"
HPA_NAME="$(kubectl get hpa -n "${NAMESPACE}" -o json 2>/dev/null \
  | jq -r --arg d "${DEPLOYMENT}" '.items[] | select(.spec.scaleTargetRef.name==$d) | .metadata.name' \
  | head -n1)"
if [ -n "${HPA_NAME}" ]; then
  echo "找到 HPA ${HPA_NAME}，測試期間先暫停（避免它跟我們同時搶著改 replicas）" >&2
  kubectl get hpa "${HPA_NAME}" -n "${NAMESPACE}" -o yaml > "${HPA_BACKUP_FILE}"
  kubectl delete hpa "${HPA_NAME}" -n "${NAMESPACE}" >/dev/null
else
  echo "沒有找到對應的 HPA，跳過暫停步驟" >&2
fi
kubectl scale "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --replicas=1 >/dev/null
kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=120s >/dev/null

echo "== 1/5 建立 k6 階梯式壓測腳本 ConfigMap ==" >&2
kubectl create configmap "${RUN_ID}-script" -n default \
  --from-file=load-test.js="${SCRIPT_DIR}/k6-script.js" >/dev/null

echo "== 2/5 啟動 k6 Job（namespace: default，走 dev-gateway 進去）==" >&2
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${RUN_ID}
  namespace: default
  labels:
    training/tool: k6-resource-test
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:latest
          args: ["run", "/scripts/load-test.js"]
          env:
            - name: BASE_URL
              value: "http://${GATEWAY_SVC}"
            - name: HOST_HEADER
              value: "${HOST_HEADER}"
            - name: START_VUS
              value: "${START_VUS}"
            - name: STEP_VUS
              value: "${STEP_VUS}"
            - name: STEP_DURATION
              value: "${STEP_DURATION}"
            - name: MAX_STEPS
              value: "${MAX_STEPS}"
            - name: P95_THRESHOLD_MS
              value: "${P95_THRESHOLD_MS}"
            - name: ERROR_RATE_THRESHOLD
              value: "${ERROR_RATE_THRESHOLD}"
            - name: EXTRA_ASSET_PATHS
              value: "${EXTRA_ASSET_PATHS}"
            - name: THINK_TIME_SEC
              value: "${THINK_TIME_SEC}"
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: ${RUN_ID}-script
EOF

echo "== 3/5 每 ${SAMPLE_INTERVAL} 秒取樣 kubectl top pod -n ${NAMESPACE} -l app=${APP_LABEL} ==" >&2
echo "timestamp,pod,cpu,memory" > "${SAMPLE_FILE}"
(
  while true; do
    ts="$(date +%H:%M:%S)"
    kubectl top pod -n "${NAMESPACE}" -l "app=${APP_LABEL}" --no-headers 2>/dev/null \
      | awk -v ts="$ts" '{print ts","$1","$2","$3}' >> "${SAMPLE_FILE}" || true
    sleep "${SAMPLE_INTERVAL}"
  done
) &
SAMPLER_PID=$!

echo "== 4/5 等待 k6 Job 結束（正常跑完 MAX_STEPS=${MAX_STEPS}，或提早觸及邊界就會中止；上限 ${WAIT_TIMEOUT_SEC}s）==" >&2
JOB_STATUS=""
ELAPSED_SEC=0
while [ "${ELAPSED_SEC}" -lt "${WAIT_TIMEOUT_SEC}" ]; do
  COND_COMPLETE="$(kubectl get "job/${RUN_ID}" -n default -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)"
  if [ "${COND_COMPLETE}" = "True" ]; then JOB_STATUS="complete"; break; fi
  COND_FAILED="$(kubectl get "job/${RUN_ID}" -n default -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)"
  if [ "${COND_FAILED}" = "True" ]; then JOB_STATUS="failed"; break; fi
  sleep "${POLL_INTERVAL_SEC}"
  ELAPSED_SEC=$((ELAPSED_SEC + POLL_INTERVAL_SEC))
done
if [ -z "${JOB_STATUS}" ]; then
  echo "等了 ${WAIT_TIMEOUT_SEC}s 還沒有 Complete/Failed 條件，Job 可能卡住了，直接嘗試抓目前的 log" >&2
elif [ "${JOB_STATUS}" = "failed" ]; then
  # k6 的 abortOnFail 撞到門檻時，k6 process 會用非 0 exit code 結束，
  # 搭配 backoffLimit: 0 這在 Kubernetes 眼中就是「Job 失敗」——但這其實是
  # 這個工具「成功找到容量邊界」的正常結果，不是腳本壞掉，先不要嚇人，
  # 等抓到 log、確認有沒有 K6_BOUNDARY_REPORT 之後再決定要不要真的示警。
  echo "k6 Job 狀態是 Failed，先抓 log 確認是「正常撞到邊界」還是「真的出錯」..." >&2
fi

kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
wait "${SAMPLER_PID}" 2>/dev/null || true
SAMPLER_PID=""

LOG="$(kubectl logs "job/${RUN_ID}" -n default 2>/dev/null || true)"
PEAK_VUS="$(echo "${LOG}" | sed -n 's/^peak_vus=//p' | tail -n1)"
THROUGHPUT="$(echo "${LOG}" | sed -n 's/^throughput_rps=//p' | tail -n1)"
P95="$(echo "${LOG}" | sed -n 's/^p95_ms=//p' | tail -n1)"
AVG="$(echo "${LOG}" | sed -n 's/^avg_ms=//p' | tail -n1)"
ERR="$(echo "${LOG}" | sed -n 's/^error_rate_pct=//p' | tail -n1)"
BREACHED="$(echo "${LOG}" | sed -n 's/^breached=//p' | tail -n1)"
REASON="$(echo "${LOG}" | sed -n 's/^breach_reason=//p' | tail -n1)"

echo "== 5/5 產出報告 ==" >&2
echo
if [ "${JOB_STATUS}" = "failed" ] && [ -z "${PEAK_VUS}" ]; then
  # Job 狀態是 Failed，而且 log 裡完全沒有 K6_BOUNDARY_REPORT——這才是真的出錯
  # （不是正常撞到邊界的 abortOnFail），印出全部 log 讓人排查。
  echo "!! k6 Job 真的出錯了（不是正常撞到邊界），下面是完整 log !!"
  echo "########## [1/4] k6 完整輸出 ##########"
  echo "${LOG}"
  if [ -z "${LOG}" ]; then
    echo "（log 是空的——Job 可能還沒真的開始跑就掛了，或已經被 ttlSecondsAfterFinished 回收，可以縮短 WAIT_TIMEOUT_SEC/POLL_INTERVAL_SEC 或加快重跑一次觀察）"
  fi
else
  if [ "${JOB_STATUS}" = "failed" ]; then
    echo "（k6 Job 狀態是 Failed，但下面有抓到 K6_BOUNDARY_REPORT——這是 abortOnFail 撞到邊界的正常結果，不是腳本出錯）"
    echo
  fi
  echo "########## [1/4] k6 完整輸出（最後 40 行）##########"
  echo "${LOG}" | tail -n 40
fi

echo
echo "########## [2/4] 容量邊界（單一 Pod，replicas 已暫時縮到 1）##########"
if [ -z "${PEAK_VUS}" ]; then
  echo "沒有解析到摘要區塊，請直接看上面的完整輸出（可能是 k6 版本輸出格式不同）"
else
  echo "峰值併發 ${PEAK_VUS} VU、輸出量 ${THROUGHPUT} req/s、p95 ${P95}ms、平均 ${AVG}ms、錯誤率 ${ERR}%"
  if [ "${BREACHED}" = "yes" ]; then
    echo "→ 已觸及邊界（原因：${REASON}）。單一 Pod 大約能扛住 ${PEAK_VUS} 個併發使用者，超過就會開始違反 SLA。"
  else
    echo "→ 跑完 MAX_STEPS=${MAX_STEPS} 都沒有壞，還沒找到真正的邊界。"
    echo "  想找到極限可以拉大階梯再測一次，例如："
    echo "  MAX_STEPS=$((MAX_STEPS * 2)) $0 ${NAMESPACE} ${DEPLOYMENT} ${APP_LABEL} ${HOST_HEADER}"
  fi
fi

echo
echo "########## [3/4] kubectl top pod 資源取樣 ##########"
SAMPLE_ROWS="$(($(wc -l < "${SAMPLE_FILE}") - 1))"
if [ "${SAMPLE_ROWS}" -le 0 ]; then
  echo "（沒有取到任何樣本，檢查 metrics-server 是否可用，或 app label / namespace 是否正確）"
else
  column -t -s, "${SAMPLE_FILE}"
fi

echo
echo "########## [4/4] requests/limits/HPA 建議值 + 加一個 replica 要改什麼 ##########"
echo "（假設本叢集慣例：CPU 用 m 為單位、Memory 用 Mi 為單位，其他單位會被忽略）"

SUGGEST="$(awk -F, '
  NR>1 && $3 ~ /^[0-9]+m$/ && $4 ~ /^[0-9]+Mi$/ {
    n++; cpu[n]=$3+0; mem[n]=$4+0
  }
  END {
    if (n==0) { exit }
    cutoff = int(n*0.4); if (cutoff<1) cutoff=1
    scs=0; sms=0
    for (i=1;i<=cutoff;i++) { scs+=cpu[i]; sms+=mem[i] }
    pc=0; pm=0
    for (i=1;i<=n;i++) { if (cpu[i]>pc) pc=cpu[i]; if (mem[i]>pm) pm=mem[i] }
    printf "STEADY_CPU=%.0f\n", scs/cutoff
    printf "PEAK_CPU=%.0f\n", pc
    printf "STEADY_MEM=%.0f\n", sms/cutoff
    printf "PEAK_MEM=%.0f\n", pm
  }
' "${SAMPLE_FILE}")"

if [ -z "${SUGGEST}" ]; then
  echo "（資源樣本不足，無法計算建議值——可以拉長 STEP_DURATION 或 MAX_STEPS 讓取樣點更多再測一次）"
else
  STEADY_CPU="$(echo "${SUGGEST}" | sed -n 's/^STEADY_CPU=//p')"
  PEAK_CPU="$(echo "${SUGGEST}" | sed -n 's/^PEAK_CPU=//p')"
  STEADY_MEM="$(echo "${SUGGEST}" | sed -n 's/^STEADY_MEM=//p')"
  PEAK_MEM="$(echo "${SUGGEST}" | sed -n 's/^PEAK_MEM=//p')"
  LIMITS_CPU=$((PEAK_CPU * 13 / 10))
  LIMITS_MEM=$((PEAK_MEM * 3 / 2))

  echo "requests.cpu    ≈ ${STEADY_CPU}m   （測試前段、負載還輕時的平均用量）"
  echo "limits.cpu      ≈ ${LIMITS_CPU}m   （峰值 ${PEAK_CPU}m x1.3，CPU 可壓縮，緩衝抓小一點即可）"
  echo "requests.memory ≈ ${STEADY_MEM}Mi  （測試前段、負載還輕時的平均用量）"
  echo "limits.memory   ≈ ${LIMITS_MEM}Mi  （峰值 ${PEAK_MEM}Mi x1.5，Memory 不可壓縮，緩衝抓大一點避免 OOMKilled）"

  echo
  echo "---- HPA 建議 ----"
  MIN_REPLICAS=2
  if [ "${ORIG_REPLICAS}" -gt "${MIN_REPLICAS}" ]; then MIN_REPLICAS="${ORIG_REPLICAS}"; fi
  echo "minReplicas ≈ ${MIN_REPLICAS}（至少 2，確保單一 Pod 重啟/被驅逐時還有另一個在撐著；原本設定是 ${ORIG_REPLICAS}）"
  echo "targetCPUUtilizationPercentage ≈ 70（業界慣例：讓 HPA 在用量到 requests 的 70% 就提早加開新 Pod，"
  echo "  留 30% 緩衝給「決定要擴容→新 Pod Ready」這段延遲，不要等到真的頂到邊界才擴容）"
  if [ -n "${PEAK_VUS}" ] && [ "${PEAK_VUS}" -gt 0 ] 2>/dev/null; then
    MAX_REPLICAS_EXAMPLE=$(((EXPECTED_PEAK_USERS + PEAK_VUS - 1) / PEAK_VUS))
    echo "maxReplicas 公式 ≈ ceil(預期尖峰同時在線人數 ÷ 單 Pod 容量邊界)"
    echo "  範例：若預期尖峰同時在線 ${EXPECTED_PEAK_USERS} 人（EXPECTED_PEAK_USERS 可覆寫），"
    echo "  單 Pod 邊界 ${PEAK_VUS} 人 → maxReplicas ≈ ceil(${EXPECTED_PEAK_USERS} / ${PEAK_VUS}) = ${MAX_REPLICAS_EXAMPLE}"
  else
    echo "maxReplicas：沒有量到 peak_vus，無法算範例，公式是 ceil(預期尖峰同時在線人數 ÷ 單 Pod 容量邊界)"
    MAX_REPLICAS_EXAMPLE=""
  fi

  echo
  echo "---- 之後想把 maxReplicas 調高，需要改動的地方 ----"
  echo "1. ResourceQuota：Σ(replicas × requests) 必須 ≤ quota，maxReplicas 調高後配額也要跟著調高，"
  echo "   否則新 Pod 會卡在 Pending（跟下面即時檢查的結果一起看）。"
  echo "2. LimitRange：單一容器的 min/max 天花板/地板不受 replicas 數影響，不用跟著調，"
  echo "   但如果上面建議的 requests/limits 本身有變，仍要落在 LimitRange 的 min/max 之間。"
  echo "3. HPA 本身：maxReplicas 就是新的天花板，設太低等於白測；也要留意 behavior/"
  echo "   stabilizationWindow，避免 replicas 數上上下下震盪（flapping）。"
  echo "4. 節點容量：更多 replica 需要有節點排得下去，這個叢集 k8s01~03 記憶體長期在"
  echo "   81-91% 使用率，加 replica 前務必先 kubectl top nodes 確認還有空間，不然新 Pod"
  echo "   一樣會卡 Pending，但原因是節點滿了、不是 quota 不夠，兩者要分開排查。"
  echo "5. NetworkPolicy：本教材多數規則用 podSelector/'from: []'，不受 replica 數影響，"
  echo "   通常不用改；但若之後改成有 IP 白名單或連線數限制邏輯，要另外檢查。"
  echo "6. 若目標是 StatefulSet（有 volumeClaimTemplates）：每多一個 replica 就多一份"
  echo "   PVC/儲存用量，要確認 StorageClass 容量夠、不是只看 CPU/Memory。"

  QUOTA_JSON="$(kubectl get resourcequota -n "${NAMESPACE}" -o json 2>/dev/null || true)"
  if [ -n "${QUOTA_JSON}" ] && [ -n "${MAX_REPLICAS_EXAMPLE}" ]; then
    QUOTA_REQ_CPU_RAW="$(echo "${QUOTA_JSON}" | jq -r '.items[0].spec.hard["requests.cpu"] // ""')"
    if [ -n "${QUOTA_REQ_CPU_RAW}" ]; then
      if [[ "${QUOTA_REQ_CPU_RAW}" == *m ]]; then
        QUOTA_REQ_CPU_MILLI="${QUOTA_REQ_CPU_RAW%m}"
      else
        QUOTA_REQ_CPU_MILLI=$((QUOTA_REQ_CPU_RAW * 1000))
      fi
      NEEDED_REQ_CPU_MILLI=$((MAX_REPLICAS_EXAMPLE * STEADY_CPU))
      echo
      echo "即時檢查：目前 ${NAMESPACE} 的 ResourceQuota.hard.requests.cpu = ${QUOTA_REQ_CPU_RAW}"
      echo "  （= ${QUOTA_REQ_CPU_MILLI}m），若 maxReplicas 開到範例算出的 ${MAX_REPLICAS_EXAMPLE}，"
      echo "  需要 ${MAX_REPLICAS_EXAMPLE} x ${STEADY_CPU}m = ${NEEDED_REQ_CPU_MILLI}m。"
      if [ "${NEEDED_REQ_CPU_MILLI}" -gt "${QUOTA_REQ_CPU_MILLI}" ]; then
        echo "  → 目前配額不夠，需要把 requests.cpu 調高到至少 ${NEEDED_REQ_CPU_MILLI}m 才能真正擴到 ${MAX_REPLICAS_EXAMPLE} 個 replica。"
      else
        echo "  → 目前配額夠用，不需要調整 ResourceQuota 就能擴到 ${MAX_REPLICAS_EXAMPLE} 個 replica。"
      fi
    fi
  fi
fi

echo
echo "提醒：以上都是「這次測試流量模式」量到的參考值，不是絕對答案；"
echo "改變 START_VUS/STEP_VUS/STEP_DURATION 會量到不同的曲線，最終數字仍要回頭跟"
echo "docs/resources/README.md 的理論估算法互相驗證。"
