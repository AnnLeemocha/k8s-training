`weed mini` 命令整合了 SeaweedFS 的所有主要組件（Master、Volume Server、Filer、S3 Gateway、WebDAV Gateway 與 Admin UI）。

---

### 1. Admin UI 管理介面與安全設定 (`-admin.*`)

| 參數名 | 說明 | 預設值 |
| --- | --- | --- |
| **`-admin.ui`** | 是否啟用 Admin UI 管理介面。 | `true` |
| **`-admin.user`** | 管理員 UI 的登入帳號名稱。 | `"admin"` |
| **`-admin.password`** | 管理員 UI 的登入密碼。**若留空則代表關閉身份驗證功能**。 | `""` |
| **`-admin.readOnlyUser`** | 唯讀使用者的帳號名稱（僅供檢視，無法變更設定）。 | `""` |
| **`-admin.readOnlyPassword`** | 唯讀使用者的密碼（必須同時設定 `-admin.password` 才有效）。 | `""` |
| **`-admin.port`** | Admin UI 服務的 HTTP 監聽埠。 | `23646` |
| **`-admin.port.grpc`** | Admin UI 服務的 gRPC 監聽埠（預設為 HTTP 埠 + 10000）。 | `33646` |
| **`-admin.dataDir`** | 存放 Admin 管理介面設定檔與數據資料的目錄路徑。 | `""` |
| **`-admin.master`** | Master 服務節點位址（在 `mini` 模式下系統會自動設定）。 | `""` |
| **`-admin.urlPrefix`** | 當 Admin UI 部署在反向代理（如 Nginx）的子目錄時所使用的 URL 前綴（例 `/seaweedfs`）。 | `""` |

---

### 2. S3 兼容服務設定 (`-s3.*`, `-bucket`, `-tableBucket`)

| 參數名 | 說明 | 預設值 |
| --- | --- | --- |
| **`-s3`** | 是否啟用 S3 相容 API 服務。 | `true` |
| **`-s3.port`** | S3 API 服務的 HTTP 監聽埠。 | `8333` |
| **`-s3.port.grpc`** | S3 服務的 gRPC 監聽埠。 | `""` |
| **`-s3.port.https`** | S3 服務的 HTTPS 監聽埠。 | `0` |
| **`-bucket`** | 啟動時自動建立的 S3 Bucket 名稱，多個可用逗號分隔（亦可吃 `S3_BUCKET` 環境變數）。 | `""` |
| **`-s3.autoCreateBucket`** | 上傳檔案時若 Bucket 不存在，是否自動建立（僅限管理員權限）。 | `true` |
| **`-s3.allowDeleteBucketNotEmpty`** | 是否允許刪除尚有內容的 Bucket（連同內部所有物件一併刪除）。 | `true` |
| **`-s3.allowedOrigins`** | 允許跨域請求（CORS）的來源網址清單，以逗號分隔。 | `"*"` |
| **`-s3.config`** | S3 用戶與權限設定檔（JSON/配置文件）的路徑。 | `""` |
| **`-s3.iam`** | 是否在相同 Port 上啟用內建的 IAM 權限管理 API。 | `true` |
| **`-s3.iam.config`** | 高級 S3 IAM 權限設定檔的路徑。 | `""` |
| **`-s3.iam.readOnly`** | 是否關閉此服務上的 IAM 寫入/修改操作。 | `true` |
| **`-s3.domainName`** | 支援 Bucket 名稱作為子網域（例 `{bucket}.{domainName}`）的字尾清單。 | `""` |
| **`-s3.externalUrl`** | 客戶端連接的外部 URL（如反向代理後的網址），用於 S3 簽名驗證。 | `""` |
| **`-s3.cert.file`** | HTTPS 傳輸層安全的憑證檔案路徑。 | `""` |
| **`-s3.key.file`** | HTTPS 傳輸層安全的私鑰檔案路徑。 | `""` |
| **`-s3.cacert.file`** | CA 根憑證檔案路徑。 | `""` |
| **`-s3.tlsVerifyClientCert`** | 是否驗證 S3 客戶端傳送的 TLS 憑證。 | `false` |
| **`-s3.dataCenter`** | 指定 S3 偏好讀寫的資料中心 (Data Center) 名稱。 | `""` |
| **`-s3.defaultFileMode`** | S3 上傳物件的預設檔案權限模式（例 `0644`）。 | `""` |
| **`-s3.encryptVolumeData`** | 上傳至 Volume Server 的 S3 資料是否啟用磁碟加密。 | `false` |
| **`-s3.cacheCapacityMB`** | S3 GET 請求的記憶體區塊快取容量（MB），`0` 為禁用。 | `0` |
| **`-s3.concurrentFileUploadLimit`** | S3 限制的最大同時上傳檔案數量限制。 | `0` |
| **`-s3.concurrentUploadLimitMB`** | S3 限制的最大總並發上傳數據量（MB）。 | `0` |
| **`-s3.idleTimeout`** | S3 連線閒置逾時秒數。 | `120` |
| **`-s3.auditLogConfig`** | S3 審計日誌 (Audit log) 設定檔路徑。 | `""` |
| **`-s3.localSocket`** | 本地 IPC 連線 Unix Socket 路徑。 | `/tmp/seaweedfs-s3-<port>.sock` |
| **`-s3.localFilerSocket`** | 連接本地 Filer 的 Unix Socket 路徑。 | `""` |
| **`-s3.metricsIp`** | Prometheus 監控指標監聽 IP。 | `""` |
| **`-s3.metricsPort`** | Prometheus 監控指標監聽 Port。 | `0` |
| **`-s3.debug.port`** | 除錯 HTTP 埠（mini 模式下未啟用）。 | `6060` |
| **`-tableBucket`** | 自動建立的 S3 表格 Bucket，格式為 `名稱[:FORMAT]`（格式支援 `ICEBERG` 或 `LANCE`）。 | `""` |
| **`-s3.port.iceberg`** | Iceberg REST Catalog 服務監聽埠（`0` 為禁用）。 | `8181` |
| **`-s3.iceberg.credentialDurationSeconds`** | Iceberg Catalog 核發的憑證有效時限（秒）。 | `3600` |
| **`-s3.iceberg.credentialRole`** | Iceberg Catalog 假設的 IAM Role ARN（留空則停用）。 | `""` |
| **`-s3.port.lance`** | Lance Namespace 服務監聽埠（`0` 為禁用）。 | `9101` |

---

### 3. Filer 檔案系統介面與 UI 設定 (`-filer.*`)

| 參數名 | 說明 | 預設值 |
| --- | --- | --- |
| **`-filer.port`** | Filer 服務的 HTTP 監聽埠。 | `8888` |
| **`-filer.port.grpc`** | Filer 服務的 gRPC 監聽埠。 | `""` |
| **`-filer.port.public`** | Filer 服務對外公開的 HTTP 監聽埠。 | `0` |
| **`-filer.ui.deleteDir`** | 是否在 Filer UI 上顯示「刪除目錄」按鈕。 | `true` |
| **`-filer.exposeDirectoryData`** | 是否在 Filer UI 中顯示目錄的元數據與內容。 | `true` |
| **`-filer.disableDirListing`** | 是否關閉目錄清單預覽功能（禁止條列資料夾內容）。 | `false` |
| **`-filer.dirListLimit`** | 單次列出子目錄數量的最大上限。 | `1000` |
| **`-filer.allowedOrigins`** | 允許 CORS 跨域的來源網址清單。 | `"*"` |
| **`-filer.collection`** | 所有 Filer 資料預設歸類的集合 (Collection) 名稱。 | `""` |
| **`-filer.disk`** | 指定儲存媒體類別，如 `hdd`、`ssd` 或自訂標籤。 | `""` |
| **`-filer.defaultReplicaPlacement`** | 預設副本複製模式（若未指定則繼承 Master 設定）。 | `""` |
| **`-filer.encryptVolumeData`** | 是否加密 Volume Server 上的數據。 | `false` |
| **`-filer.filerGroup`** | 與其他 Filer 共享元數據的群組名稱。 | `""` |
| **`-filer.localSocket`** | 本地 Socket 路徑。 | `/tmp/seaweedfs-filer-<port>.sock` |
| **`-filer.maxMB`** | 大檔案分割閥值（MB），超過此大小的檔案會被分塊儲存。 | `4` |
| **`-filer.saveToFilerLimit`** | 小於此限制（位元組）的極小檔案直接存在 FilerStore 內部以提高存取速度。 | `0` |
| **`-filer.downloadMaxMBps`** | 單一下載請求的最大限速（MB/s）。 | `0` |
| **`-filer.concurrentFileUploadLimit`** | Filer 限制同時上傳的檔案數。 | `0` |
| **`-filer.concurrentUploadLimitMB`** | Filer 限制總並發上傳容量（MB）。 | `0` |
| **`-filer.tusBasePath`** | TUS 可續傳上傳特性的端點路徑。 | `"/.tus"` |
| **`-filer.tusMaxSizeMB`** | TUS 可續傳上傳的單檔最大限制（MB）。 | `5120` |
| **`-filer.tusSessionExpiry`** | 未完成的 TUS 上傳階段過期清除時間。 | `24h0m0s` |

---

### 4. Master 核心控制服務設定 (`-master.*`)

| 參數名 | 說明 | 預設值 |
| --- | --- | --- |
| **`-master.port`** | Master 服務 HTTP 監聽埠。 | `9333` |
| **`-master.port.grpc`** | Master 服務 gRPC 監聽埠。 | `""` |
| **`-master.dir`** | Master 儲存元數據的目錄（預設同主參數 `-dir`）。 | `""` |
| **`-master.peers`** | 所有 Master 節點的 `IP:Port` 清單，用逗號分隔（單一主機留空即可）。 | `""` |
| **`-master.defaultReplication`** | 預設的資料副本複製策略（例如 `000` 表示不複製，`001` 表示不同 rack 複製）。 | `""` |
| **`-master.volumeSizeLimitMB`** | 單一 Volume 磁碟區的大小上限（mini 模式預設為 `128` MB）。 | `128` |
| **`-master.volumePreallocate`** | 是否預先分配 Volume 檔案的硬碟空間。 | `false` |
| **`-master.garbageThreshold`** | 觸發垃圾回收 (Vacuum) 與收回空間的無效資料比例門檻。 | `0.3` (30%) |
| **`-master.maxParallelVacuumPerServer`** | 單一 Volume Server 上允許同時進行清理 (Vacuum) 的最大 Volume 數。 | `1` |
| **`-master.resumeState`** | 重啟 Master 時是否恢復之前的狀態。 | `true` |
| **`-master.electionTimeout`** | Master 高可用模式下 Leader 選舉逾時時間。 | `10s` |
| **`-master.heartbeatInterval`** | Master 節點間的心跳偵測間隔。 | `300ms` |
| **`-master.raftBootstrap`** | 是否自動初始化 Raft 共識叢集。 | `false` |
| **`-master.raftHashicorp`** | 是否使用 Hashicorp Raft 引擎。 | `false` |
| **`-master.metrics.address`** | 推送監控數據至 Prometheus Gateway 的位址。 | `""` |
| **`-master.metrics.intervalSeconds`** | 推送 Prometheus 指標的時間間隔（秒）。 | `15` |
| **`-master.telemetry`** | 是否傳送匿名統計數據至官方服務。 | `true` |
| **`-master.telemetry.url`** | 匿名統計數據的接收端點。 | `[https://telemetry.seaweedfs.com/api/collect](https://telemetry.seaweedfs.com/api/collect)` |

---

### 5. Volume 數據儲存服務設定 (`-volume.*`)

| 參數名 | 說明 | 預設值 |
| --- | --- | --- |
| **`-volume.port`** | Volume 服務 HTTP 監聽埠。 | `9340` |
| **`-volume.port.grpc`** | Volume 服務 gRPC 監聽埠。 | `""` |
| **`-volume.port.public`** | Volume 對外公開的 HTTP 監聽埠。 | `0` |
| **`-volume.publicUrl`** | 公開訪問的外部位址（適用於 NAT / 外部 DNS）。 | `""` |
| **`-volume.id`** | Volume Server 的唯一識別碼（預設自動設為 `IP:Port`）。 | `""` |
| **`-volume.dir.idx`** | 專門存放 `.idx` 索引檔案的目錄。 | `""` |
| **`-volume.disk`** | 設定磁碟類型，如 `hdd`、`ssd` 或標籤。 | `""` |
| **`-volume.index`** | 記憶體與效能平衡模式：`memory` / `leveldb` / `leveldbMedium` / `leveldbLarge`。 | `"memory"` |
| **`-volume.index.leveldbTimeout`** | LevelDB 索引模式下的保鮮存活時間。 | `0` |
| **`-volume.fileSizeLimitMB`** | 上傳單檔上限，防止記憶體溢出 (OOM)。 | `256` |
| **`-volume.readMode`** | 存取非本地 Volume 時的處理機制：`local` (僅本地)、`proxy` (代理轉發)、`redirect` (重定向)。 | `"proxy"` |
| **`-volume.readBufferSizeMB`** | 讀取快取緩衝區大小 (MB)。 | `4` |
| **`-volume.hasSlowRead`** | 開啟此項可防止慢速讀取阻塞其他請求。 | `true` |
| **`-volume.compactionMBps`** | 限制數據壓縮整理 (Compaction) 的磁碟 IO 速度 (MB/s)。 | `0` |
| **`-volume.maintenanceMBps`** | 限制日常維護操作的磁碟 IO 速度 (MB/s)。 | `0` |
| **`-volume.concurrentDownloadLimitMB`** | Volume 限制的最大總並發下載大小。 | `0` |
| **`-volume.concurrentUploadLimitMB`** | Volume 限制的最大總並發上傳大小。 | `0` |
| **`-volume.inflightDownloadDataTimeout`** | 進行中下載傳輸的等待逾時時間。 | `1m0s` |
| **`-volume.inflightUploadDataTimeout`** | 進行中上傳傳輸的等待逾時時間。 | `1m0s` |
| **`-volume.preStopSeconds`** | 關閉服務前停止傳送 Heartbeat 到完全停止前的等待時間（mini 模式為 `1` 秒）。 | `1` |
| **`-volume.images.fix.orientation`** | 上傳 JPG 圖片時是否自動校正 Exif 旋轉方向。 | `false` |
| **`-volume.tags`** | 為各資料目錄設定標籤（例 `fast:ssd,archive`）。 | `""` |
| **`-volume.allowUntrustedRemoteEndpoints`** | 是否允許從非信任的遠端 S3 端點（含 Loopback / 本地網絡）抓取數據。 | `false` |
| **`-volume.pprof`** | 是否開啟 Volume Server 的 pprof 分析 handler。 | `false` |

---

### 6. WebDAV 網頁資料夾服務設定 (`-webdav.*`)

| 參數名 | 說明 | 預設值 |
| --- | --- | --- |
| **`-webdav`** | 是否啟用 WebDAV 服務。 | `true` |
| **`-webdav.port`** | WebDAV 服務的 HTTP 監聽埠。 | `7333` |
| **`-webdav.collection`** | WebDAV 建立檔案時歸屬的集合名稱。 | `""` |
| **`-webdav.replication`** | WebDAV 建立檔案時採用的複製模式。 | `""` |
| **`-webdav.disk`** | 指定 WebDAV 儲存硬碟標籤（`hdd`/`ssd`）。 | `""` |
| **`-webdav.filer.path`** | 對應至 Filer 內部的根目錄路徑。 | `"/"` |
| **`-webdav.maxMB`** | 超過此大小的檔案將進行切塊。 | `4` |
| **`-webdav.cacheDir`** | 本地檔案切塊快取目錄。 | `"/tmp"` |
| **`-webdav.cacheCapacityMB`** | 本地快取空間容量上限 (MB)。 | `0` |
| **`-webdav.cert.file`** | WebDAV TLS 憑證路徑。 | `""` |
| **`-webdav.key.file`** | WebDAV TLS 私鑰路徑。 | `""` |

---

### 7. 通用與系統網路設定

| 參數名 | 說明 | 預設值 |
| --- | --- | --- |
| **`-dir`** | 全域資料與索引檔案存放的總根目錄。 | `"."` (當前目錄) |
| **`-ip`** | 節點使用的 IP 位址或主機名稱（用於內部服務節點互聯與識別）。 | 自動偵測主機 IP |
| **`-ip.bind`** | 服務綁定的網路卡 IP（`0.0.0.0` 表示監聽所有網卡）。 | `"0.0.0.0"` |
| **`-whiteList`** | 允許寫入權限的白名單 IP 清單（逗號分隔）；若留空則不限制寫入來源。 | `""` |
| **`-idleTimeout`** | 網路連線閒置逾時時間（秒）。 | `30` |
| **`-disableHttp`** | 停用 HTTP 請求，強制僅允許 gRPC 通訊。 | `false` |
| **`-dataCenter`** | 指定當前 Volume Server 所屬的資料中心名稱。 | `""` |
| **`-rack`** | 指定當前 Volume Server 所屬的機架 (Rack) 名稱。 | `""` |
| **`-options`** | 指定包含配置參數的 `.conf` 檔案路徑（如上一問解答）。 | `""` |
| **`-debug`** | 開啟性能分析 debug 介面（如 `http://localhost:6060/debug/pprof/`）。 | `false` |
| **`-debug.port`** | Debug 效能分析 HTTP 監聽 Port。 | `6060` |
| **`-cpuprofile`** | 輸出 CPU 分析數據到指定檔案。 | `""` |
| **`-memprofile`** | 輸出記憶體分析數據到指定檔案。 | `""` |
| **`-metricsIp`** | 監控指標綁定的 IP 位址。 | `""` |
| **`-metricsPort`** | Prometheus 監控指標監聽 Port。 | `0` |