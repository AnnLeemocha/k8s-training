// 通用 k6「階梯式壓測」腳本，給 run-load-test.sh 呼叫。
// 目的不是模擬真實流量曲線，是自動找出「這一個 Pod 撐得住的容量邊界」：
// 併發使用者數（VU）每隔 STEP_DURATION 就往上加一階 STEP_VUS，
// 一路爬到 p95 延遲或錯誤率觸發 thresholds 為止（abortOnFail 會讓整個測試
// 立刻停止），一次執行就能量到邊界在哪，不用自己反覆猜 max_vus 重跑。
//
// 透過 dev-gateway 打進去（跟真實使用者路徑一致），用 BASE_URL 指向 Gateway 的
// ClusterIP Service，用 HOST_HEADER 指定要測哪個產品的 HTTPRoute host。
//
// 注意：run-load-test.sh 呼叫這支腳本之前，會先把目標 Deployment 縮到
// replicas=1 並暫停 HPA——這樣量到的邊界才是「單一 Pod」的真實容量，
// 不會被 HPA 中途加開新 Pod 稀釋掉。
//
// 預設只打 `/`，這是最輕量、最通用的測法（適用任何產品，先求測得動）。
// 但對 draw.io 這種純前端 SPA 來說，`/` 只是一個幾 KB 的靜態 HTML 外殼，
// 真實使用者打開頁面時瀏覽器還會接著下載 JS/CSS 等應用程式本體（draw.io
// 的 js/app.min.js 等 bundle 合計約 21MB），只測 `/` 會嚴重低估真實負載。
// 用 EXTRA_ASSET_PATHS（逗號分隔的相對路徑）讓每次「頁面載入」也一併平行
// 抓這些真正的靜態資源，模擬瀏覽器實際會做的事，各產品依自己實際的資源
// 路徑覆寫即可。
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://cilium-gateway-dev-gateway.default.svc.cluster.local';
const HOST_HEADER = __ENV.HOST_HEADER || 'drawio.nexai.org.com';
const EXTRA_ASSET_PATHS = (__ENV.EXTRA_ASSET_PATHS || '')
  .split(',')
  .map((p) => p.trim())
  .filter(Boolean);
// "js/app.min.js,js/extensions.min.js,js/shapes-14-6-5.min.js,js/stencils.min.js,styles/grapheditor.css"

// 模擬使用者看到頁面後的「思考時間」才會下一次重整/開新分頁，預設跟舊版
// 行為一致（1 秒緊接著打下一輪）；測「完整頁面載入」情境時建議調高
// （例如 5），避免每秒都重複下載整包 JS/CSS，變成不合理的洗頁測試。
const THINK_TIME_SEC = parseFloat(__ENV.THINK_TIME_SEC || '1');

const START_VUS = parseInt(__ENV.START_VUS || '5', 10);
const STEP_VUS = parseInt(__ENV.STEP_VUS || '5', 10);
const STEP_DURATION = __ENV.STEP_DURATION || '30s';
const MAX_STEPS = parseInt(__ENV.MAX_STEPS || '30', 10);
// 判斷「壞掉」的兩個訊號：入口頁（root，見下面 tags）p95 延遲超過門檻，
// 或整體錯誤率超過門檻。兩者都設 abortOnFail，先撞到哪個就先停，停下來
// 的那一刻就是容量邊界。門檻刻意只看 root 的延遲、不看 asset 的延遲，
// 因為大檔案下載時間主要取決於檔案大小跟頻寬，不是伺服器過載的訊號，
// 混進去會讓 p95 被「檔案很大」污染，誤判成「服務變慢」。
const P95_THRESHOLD_MS = parseInt(__ENV.P95_THRESHOLD_MS || '800', 10);
const ERROR_RATE_THRESHOLD = parseFloat(__ENV.ERROR_RATE_THRESHOLD || '0.05');

function buildStaircase() {
  const stages = [];
  for (let i = 0; i < MAX_STEPS; i++) {
    stages.push({ duration: STEP_DURATION, target: START_VUS + i * STEP_VUS });
  }
  return stages;
}

export const options = {
  stages: buildStaircase(),
  thresholds: {
    http_req_failed: [
      { threshold: `rate<${ERROR_RATE_THRESHOLD}`, abortOnFail: true, delayAbortEval: '10s' },
    ],
    'http_req_duration{name:root}': [
      { threshold: `p(95)<${P95_THRESHOLD_MS}`, abortOnFail: true, delayAbortEval: '10s' },
    ],
  },
};

export default function () {
  const headers = { Host: HOST_HEADER };

  // 入口頁：所有產品都適用的最小測法。
  const rootRes = http.get(`${BASE_URL}/`, { headers, tags: { name: 'root' } });
  check(rootRes, { 'root status is 200': (r) => r.status === 200 });

  // 額外的真實靜態資源：用 http.batch 一次平行抓，模擬瀏覽器載入頁面時
  // 同時發出多個請求的行為（而不是一個一個序列抓，那樣會低估併發壓力）。
  if (EXTRA_ASSET_PATHS.length > 0) {
    const requests = EXTRA_ASSET_PATHS.map((p) => ({
      method: 'GET',
      url: `${BASE_URL}/${p}`,
      params: { headers, tags: { name: 'asset' } },
    }));
    const responses = http.batch(requests);
    responses.forEach((r) => check(r, { 'asset status is 200': (res) => res.status === 200 }));
  }

  sleep(THINK_TIME_SEC);
}

// 測試結束時一定會呼叫（正常跑完 MAX_STEPS，或被上面的 threshold 提前中止都算），
// 印出一段固定格式、好用 shell 解析的摘要區塊，讓 run-load-test.sh 直接抓到
// 「容量邊界在哪個 VU 數、有沒有撞到邊界、為什麼撞到」。
export function handleSummary(data) {
  const m = data.metrics || {};
  const get = (name, field, fallback) => {
    if (m[name] && m[name].values && typeof m[name].values[field] !== 'undefined') {
      return m[name].values[field];
    }
    return fallback;
  };

  const failedThresholds = [];
  Object.keys(m).forEach((name) => {
    const thresholds = m[name].thresholds;
    if (thresholds) {
      Object.keys(thresholds).forEach((expr) => {
        if (!thresholds[expr].ok) failedThresholds.push(`${name}(${expr})`);
      });
    }
  });

  const peakVus = get('vus', 'max', 0);
  const throughput = get('http_reqs', 'rate', 0);
  // 優先用 root 這條 submetric（跟 thresholds 用的是同一條，不受大檔案下載時間污染）；
  // 沒有 EXTRA_ASSET_PATHS 時 root ≈ 全部流量，退回用整體 http_req_duration 也一樣。
  const p95 = get('http_req_duration{name:root}', 'p(95)', get('http_req_duration', 'p(95)', 0));
  const avg = get('http_req_duration{name:root}', 'avg', get('http_req_duration', 'avg', 0));
  const errorRate = get('http_req_failed', 'rate', 0);

  const lines = [
    '===K6_BOUNDARY_REPORT_START===',
    `peak_vus=${Math.round(peakVus)}`,
    `throughput_rps=${throughput.toFixed(2)}`,
    `p95_ms=${p95.toFixed(1)}`,
    `avg_ms=${avg.toFixed(1)}`,
    `error_rate_pct=${(errorRate * 100).toFixed(2)}`,
    `breached=${failedThresholds.length > 0 ? 'yes' : 'no'}`,
    `breach_reason=${failedThresholds.length > 0
      ? failedThresholds.join(';')
      : 'none(尚未觸及邊界，可提高 MAX_STEPS 或 STEP_VUS 再測一次)'
    }`,
    '===K6_BOUNDARY_REPORT_END===',
  ];

  return {
    stdout: lines.join('\n') + '\n',
  };
}
