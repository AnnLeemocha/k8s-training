# SeaweedFS 

## 建立備份機

Ubuntu 26.04

### 硬碟處理
1. 先確認 "目標硬碟" 是你預期的容量
    ```bash
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
    # NAME                       SIZE FSTYPE      TYPE MOUNTPOINTS
    # sda                        200G             disk 
    # ├─sda1                       1M             part 
    # ├─sda2                       2G ext4        part /boot
    # └─sda3                     198G LVM2_member part 
    #   └─ubuntu--vg-ubuntu--lv  198G ext4        lvm  /
    # sdb                        200G             disk 
    # sr0                        2.7G iso9660     rom 
    ```
2. 建立 partition (/dev/sdb1)
    ```bash
    sudo fdisk /dev/sdb
    # 後依序輸入
    # n
    # p
    # 1
    # Enter
    # Enter
    # w
    # 確認出現 /dev/sdb1
    lsblk -f /dev/sdb
    # NAME FSTYPE FSVER LABEL UUID FSAVAIL FSUSE% MOUNTPOINTS
    # sdb
    # └─sdb1
    ```

3. 格式化成 ext4
    ```bash
    # 這會清除 /dev/sdb1 上的所有資料
    sudo mkfs.ext4 -L BACKUP /dev/sdb1
    lsblk -f /dev/sdb
    # NAME   FSTYPE FSVER LABEL  UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
    # sdb
    # └─sdb1 ext4   1.0  BACKUP  xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ```

4. 建立 /backup
    ```bash
    sudo mkdir -p /backup
    # 掛載
    sudo mount /dev/sdb1 /backup
    # 確認
    df -h /backup
    # Filesystem      Size  Used Avail Use% Mounted on
    # /dev/sdb1       xxxG  ...  ...   ...  /backup
    ```

5. 用 UUID 設定永久掛載
    ```bash
    sudo blkid /dev/sdb1
    # /dev/sdb1: LABEL="BACKUP" UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" TYPE="ext4"
    ls -al /dev/disk/by-uuid/
    # lrwxrwxrwx 1 root root  10 Aug 26 05:05 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -> ../../sdb1
    # 編輯
    sudo vi /etc/fstab
    # /dev/disk/by-uuid/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx /backup ext4 defaults,nofail 0 2
    sudo systemctl daemon-reload
    ```

6. 測試 fstab
    ```bash
    sudo umount /backup
    sudo mount -a
    findmnt /backup
    df -h /backup
    # 如果正常，就代表已經設定完成。
    ```

7. 測試磁碟寫入
    ```bash
    sudo touch /backup/test.txt
    sudo sh -c 'echo "Backup disk OK" > /backup/test.txt'
    cat /backup/test.txt
    # Backup disk OK
    sudo rm /backup/test.txt
    ```

### 安裝 SeaweedFS 

1. 建立 SeaweedFS 使用者

```bash
sudo groupadd --system seaweedfs

sudo useradd --system \
  --gid seaweedfs \
  --home-dir /var/lib/seaweedfs \
  --shell /usr/sbin/nologin \
  seaweedfs

id seaweedfs
# uid=999(seaweedfs) gid=983(seaweedfs) groups=983(seaweedfs)
```


2. 建立 SeaweedFS 目錄

我們把程式、設定、資料分開：
```
/usr/local/bin/weed       ← SeaweedFS 程式
/etc/seaweedfs/           ← 設定
/var/lib/seaweedfs/       ← service 狀態
/backup/seaweedfs/        ← 真正 Backup Storage
```
```bash
# 建立
sudo mkdir -p /etc/seaweedfs
sudo mkdir -p /var/lib/seaweedfs
sudo mkdir -p /backup/seaweedfs

# 權限
sudo chown -R seaweedfs:seaweedfs /etc/seaweedfs
sudo chown -R seaweedfs:seaweedfs /var/lib/seaweedfs
sudo chown -R seaweedfs:seaweedfs /backup/seaweedfs

# 確認
ls -ld /etc/seaweedfs
# drwxr-xr-x 2 seaweedfs seaweedfs 4096 Aug 26 06:25 /etc/seaweedfs
ls -ld /var/lib/seaweedfs
# drwxr-xr-x 2 seaweedfs seaweedfs 4096 Aug 26 06:25 /var/lib/seaweedfs
ls -ld /backup/seaweedfs
# drwxr-xr-x 2 seaweedfs seaweedfs 4096 Aug 26 06:25 /backup/seaweedfs
```

3. 安裝 SeaweedFS

    官方目前提供 install.sh，可以自動偵測平台並下載最新 release；預設安裝的是 weed binary 到 /usr/local/bin。

```bash
curl -fsSL https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/install.sh | sudo bash

which weed
# /usr/local/bin/weed

weed version
# 此範例為 4.44 版
```

### 測試 SeaweedFS

1. 先做第一次啟動測試

    先不要建立 systemd，這裡我們先做一個非常重要的 Smoke Test。

    官方目前的 weed mini 可以一次建立：
    ```
    Master       :9333
    Volume       :9340
    Filer        :8888
    S3           :8333
    ```
    而且可以指定資料目錄：
    ```bash
    sudo -u seaweedfs \
        AWS_ACCESS_KEY_ID=admin \
        AWS_SECRET_ACCESS_KEY=secret \
        S3_BUCKET=velero \
        weed mini -dir=/backup/seaweedfs
    # Starting SeaweedFS Mini ...
    # Master       ready     0.2s
    # Volume       ready     0.2s
    # Filer        ready     0.2s
    # WebDAV       ready     0.2s
    # S3           ready     0.2s
    # Iceberg      ready     0.0s
    # Lance        ready     0.0s
    # Admin        ready     0.5s
    # ╔══════════════════════════════════════════════════════════╗
    # ║           SeaweedFS Mini - All-in-One # Mode             ║
    # ╚══════════════════════════════════════════════════════════╝
    # 
    # All enabled components are running and ready to use:
    # 
    #     Master UI:       http://10.90.1.125:9333
    #     Volume Server:   http://10.90.1.125:9340
    #     Filer UI:        http://10.90.1.125:8888
    #     WebDAV:          http://10.90.1.125:7333
    #     S3 Endpoint:     http://10.90.1.125:8333
    #     Iceberg Catalog: http://10.90.1.125:8181
    #     Lance Namespace: http://10.90.1.125:9101
    #     Admin UI:        http://10.90.1.125:23646
    # 
    # Data Directory:   /backup/seaweedfs
    # Free Space:       185.78 GiB
    # Volume Size:      1.00 GiB
    # Volume Count:     185
    # Free Volumes:     185
    # 
    # Press Ctrl+C to stop all components

    # /backup/seaweedfs
    #     │
    #     ▼
    # SeaweedFS
    #     │
    #     ├── Master
    #     ├── Volume
    #     ├── Filer
    #     └── S3
    #          │
    #          └── velero bucket
    ```
    先不要 Ctrl+C，讓它持續跑著

2. 開另一個 SSH Session
    ```bash
    # 先確認 process
    ps aux | grep '[w]eed mini'
    # root        3891  0.0  0.1  12452  6820 pts/0    S+   06:27   0:00 sudo -u seaweedfs AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=secret S3_BUCKET=velero weed mini -dir=/backup/seaweedfs
    # root        3893  0.0  0.0  12452  2236 pts/1    Ss   06:27   0:00 sudo -u seaweedfs AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=secret S3_BUCKET=velero weed mini -dir=/backup/seaweedfs
    # seaweed+    3894  0.1  4.3 1664092 152320 pts/1  Sl+  06:27   0:00 weed mini -dir=/backup/seaweedfs

    # 測 S3
    curl -I http://127.0.0.1:8333
    # HTTP/1.1 405 Method Not Allowed
    # Date: Wed, 26 Aug 2026 06:30:40 GMT

    # 測 Master
    curl -I http://127.0.0.1:9333
    # HTTP/1.1 200 OK
    # X-Amz-Request-Id: 18CF472FE7CE5563414F478A
    # Date: Wed, 26 Aug 2026 06:30:48 GMT
    # Content-Type: text/html; charset=utf-8

    # 測 Filer
    curl -I http://127.0.0.1:8888
    # HTTP/1.1 200 OK
    # Server: SeaweedFS 30GB 4.44
    # X-Amz-Request-Id: 18CF47312E6DAE28A64CE612
    # Date: Wed, 26 Aug 2026 06:30:53 GMT
    # Content-Type: text/html; charset=utf-8
    ```

3. 確認資料真的寫到 Backup Disk

    確認沒有不小心把資料寫到 /dev/sda
    ```
    /dev/sdb1
        │
        ▼
    /backup
        │
        ▼
    /backup/seaweedfs
        │
        ▼
    SeaweedFS data
    ```
    ```bash
    df -h /backup
    # Filesystem      Size  Used Avail Use% Mounted on
    # /dev/sdb1       196G  2.5M  186G   1% /backup

    sudo du -sh /backup/seaweedfs
    # 484K	/backup/seaweedfs

    sudo ls -al /backup/seaweedfs
    # total 52
    # drwxr-xr-x  6 seaweedfs seaweedfs 4096 Aug 26 06:28 .
    # drwxr-xr-x  4 root      root      4096 Aug 26 06:25 ..
    # -rw-------  1 seaweedfs seaweedfs   64 Aug 26 06:27 .mini_kek_passphrase
    # -rw-------  1 seaweedfs seaweedfs   64 Aug 26 06:27 .mini_sse_kek
    # -rw-r--r--  1 seaweedfs seaweedfs  840 Aug 26 06:28 1.dat
    # -rw-r--r--  1 seaweedfs seaweedfs   16 Aug 26 06:28 1.idx
    # -rw-r--r--  1 seaweedfs seaweedfs  194 Aug 26 06:28 1.vif
    # drwxr-xr-x  3 seaweedfs seaweedfs 4096 Aug 26 06:27 admin
    # drwxr-xr-x 10 seaweedfs seaweedfs 4096 Aug 26 06:27 filerldb2
    # drwxr-xr-x  3 seaweedfs seaweedfs 4096 Aug 26 06:27 m9333
    # -rw-r--r--  1 seaweedfs seaweedfs  276 Aug 26 06:27 mini.options
    # -rw-r--r--  1 seaweedfs seaweedfs   36 Aug 26 06:27 vol_dir.uuid
    # drwxr-xr-x  6 seaweedfs seaweedfs 4096 Aug 26 06:27 worker
    ```

4. 停止手動執行的 SeaweedFS
    ```bash
    # Ctrl+C
    ps aux | grep '[w]eed'
    sudo ss -lntp | grep -E ':8333|:9333|:9340|:8888'
    ```

### S3 API 測試

AWS CLI 是 AWS 的命令列工具，但這裡把它當成一個 S3 API 測試工具。

安裝 AWS CLI
```bash
sudo apt update
sudo apt install -y awscli

aws --version
```
設定測試用 S3 credentials
```bash
# 目前 systemd 是：
#   Access Key: admin
#   Secret Key: secret

export AWS_ACCESS_KEY_ID=admin
export AWS_SECRET_ACCESS_KEY=secret
export AWS_DEFAULT_REGION=us-east-1

# 查看 Bucket 清單
aws s3 ls --endpoint-url http://127.0.0.1:8333
# 2026-08-26 06:27:03 velero

# 成功
# 1. 可能會看到 bucket：
#    2026-08-26 06:27:03 velero
# 2. 沒有任何輸出 
```
如果 Bucket 裡有測試檔案，先刪除
```bash
# 刪除 Bucket 中的測試檔案
aws s3 rm s3://velero/ \
  --recursive \
  --endpoint-url http://127.0.0.1:8333

#  刪除 Bucket
aws s3 rb s3://velero \
  --endpoint-url http://127.0.0.1:8333
# remove_bucket: velero

aws s3 ls \
  --endpoint-url http://127.0.0.1:8333
# (空)
```
建立 Velero Backup Bucket
```bash
# 建立 Bucket
aws s3 mb s3://velero \
  --endpoint-url http://127.0.0.1:8333
# make_bucket: velero

aws s3 ls \
  --endpoint-url http://127.0.0.1:8333
# 2026-08-26 07:43:32 velero
```
測試真正的讀寫
```bash
echo "Velero SeaweedFS test $(date)" > /tmp/velero-test.txt

# 上傳檔案
aws s3 cp /tmp/velero-test.txt \
  s3://velero/velero-test.txt \
  --endpoint-url http://127.0.0.1:8333
# upload: ../../tmp/velero-test.txt to s3://velero/velero-test.txt

# 查看 velero 這個 Bucket 裡面有哪些 Object
aws s3 ls s3://velero/ \
  --endpoint-url http://127.0.0.1:8333
# 2026-08-26 07:44:01         54 velero-test.txt
```
再測下載
```bash
rm /tmp/velero-test.txt

# 下載檔案
aws s3 cp \
  s3://velero/velero-test.txt \
  /tmp/velero-test.txt \
  --endpoint-url http://127.0.0.1:8333
# download: s3://velero/velero-test.txt to ../../tmp/velero-test.txt

cat /tmp/velero-test.txt
# Velero SeaweedFS test ...

# 刪除檔案
aws s3 rm \
  s3://velero/velero-test.txt \
  --endpoint-url http://127.0.0.1:8333
# delete: s3://velero/velero-test.txt
```
最後確認實體磁碟
```bash
sudo du -sh /backup/seaweedfs
df -h /backup
```

### 建立正式服務

建立 Admin 與 Velero 專用 S3 credentials
```bash
# Admin
openssl rand -hex 32
# 4dcf58f4f75e8d8bd5c040f27cacb1f87e5712a0efaf13d5016b9ad8e53a7e77

# Velero
openssl rand -hex 32
# 3aa2336d1628c410ba41ca226148e53193be055fad4d17ea0ca74981311e6940

sudo vi /etc/seaweedfs/s3-config.json
```
```json
{
  "identities": [
    {
      "name": "seaweed-admin",
      "credentials": [
        {
          "accessKey": "seaweed-admin",
          "secretKey": "請換成你剛剛產生的隨機字串"
        }
      ],
      "actions": [
        "Admin",
        "Read",
        "List",
        "Tagging",
        "Write"
      ]
    },
    {
      "name": "velero",
      "credentials": [
        {
          "accessKey": "velero-backup",
          "secretKey": "請換成你剛剛產生的隨機字串"
        }
      ],
      "actions": [
        "Read:velero",
        "Write:velero",
        "List:velero",
        "Tagging:velero"
      ]
    }
  ]
}
```
> SeaweedFS 支援將 actions 限制到特定 bucket，例如 Read:bucket1、Write:bucket1 等。
> 
> velero 不適合負責建立 bucket。基於安全設計考量，Bucket 可以先由管理者建立。
```bash
# 保護設定檔
sudo chown seaweedfs:seaweedfs /etc/seaweedfs/s3-config.json
sudo chmod 600 /etc/seaweedfs/s3-config.json
ls -l /etc/seaweedfs/s3-config.json
# -rw------- 1 seaweedfs seaweedfs 367 Aug 26 07:57 /etc/seaweedfs/s3-config.json
```


建立 systemd Service
```bash
sudo vi /etc/systemd/system/seaweedfs.service
```
```ini
[Unit]
Description=SeaweedFS Mini
Documentation=https://github.com/seaweedfs/seaweedfs
After=local-fs.target network-online.target
Wants=network-online.target
RequiresMountsFor=/backup/seaweedfs

[Service]
Type=simple
User=seaweedfs
Group=seaweedfs

# Environment="AWS_ACCESS_KEY_ID=admin"
# Environment="AWS_SECRET_ACCESS_KEY=secret"
# Environment="S3_BUCKET=velero"

# ExecStart=/usr/local/bin/weed mini -dir=/backup/seaweedfs

ExecStart=/usr/local/bin/weed mini \
    -dir=/backup/seaweedfs \
    -s3.config=/etc/seaweedfs/s3-config.json

Restart=on-failure
RestartSec=5

LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload

systemctl cat seaweedfs
# 同 /etc/systemd/system/seaweedfs.service 內容

sudo systemctl start seaweedfs

sudo systemctl status seaweedfs --no-pager
# ● seaweedfs.service - SeaweedFS Mini
#      Loaded: loaded (/etc/systemd/system/seaweedfs.service; disabled; preset: enabled)
#      Active: active (running) since Wed 2026-08-26 06:53:22 UTC; 3s ago

# 查看 Log
sudo journalctl -u seaweedfs -n 100 --no-pager
sudo journalctl -u seaweedfs -f
# Master, Volume, Filer, S3 ready

# 確認 Port
sudo ss -lntp | grep -E ':8333|:9333|:9340|:8888'
# LISTEN 0    4096    *:8888    *:*    users:(("weed",pid=4179,fd=59))                       
# LISTEN 0    4096    *:8333    *:*    users:(("weed",pid=4179,fd=117))                      
# LISTEN 0    4096    *:9340    *:*    users:(("weed",pid=4179,fd=19))                       
# LISTEN 0    4096    *:9333    *:*    users:(("weed",pid=4179,fd=8))                        

# 設定開機自動啟動
sudo systemctl enable seaweedfs
# Created symlink '/etc/systemd/system/multi-user.target.wants/seaweedfs.service' → '/etc/systemd/system/seaweedfs.service'.

systemctl is-enabled seaweedfs
# enabled
```
做一次完整 Restart 測試
```bash
sudo systemctl restart seaweedfs
sudo systemctl status seaweedfs --no-pager
curl -I http://127.0.0.1:9333
curl -I http://127.0.0.1:8888

# 確認資料還是在 /backup
df -h /backup
sudo du -sh /backup/seaweedfs

# 最後做 Reboot Test
sudo reboot
findmnt /backup
# TARGET  SOURCE    FSTYPE OPTIONS
# /backup /dev/sdb1 ext4   rw,relatime
systemctl is-active seaweedfs
# active
sudo ss -lntp | grep -E ':8333|:9333|:9340|:8888'
# LISTEN 0    4096    *:9333    *:*    users:(("weed",pid=1026,fd=8))   
# LISTEN 0    4096    *:9340    *:*    users:(("weed",pid=1026,fd=19))                       
# LISTEN 0    4096    *:8333    *:*    users:(("weed",pid=1026,fd=117))                      
# LISTEN 0    4096    *:8888    *:*    users:(("weed",pid=1026,fd=59))                       
```
測試 S3 API
* 使用 admin 帳號
```bash
export AWS_ACCESS_KEY_ID='seaweed-admin'
export AWS_SECRET_ACCESS_KEY='<seaweed-admin 的 secret>'

# 建立 Bucket
aws s3 mb s3://velero \
  --endpoint-url http://127.0.0.1:8333
# make_bucket: velero

aws s3 ls \
  --endpoint-url http://127.0.0.1:8333
# 2026-08-26 07:43:32 velero
```

* 使用 velero 帳號
```bash
export AWS_ACCESS_KEY_ID='velero-backup'
export AWS_SECRET_ACCESS_KEY='<velero 的 secret>'

aws s3 mb s3://velero \
  --endpoint-url http://127.0.0.1:8333
# make_bucket failed: s3://velero An error occurred (AccessDenied) when calling the CreateBucket operation: Access Denied.

aws s3 ls s3://velero/ \
  --endpoint-url http://127.0.0.1:8333
# 成功 (空)
```

## 改用 HTTPS

安裝 Nginx
```bash
sudo apt update
sudo apt install -y nginx

nginx -v
sudo systemctl enable --now nginx
sudo systemctl status nginx --no-pager

curl -I http://10.90.1.125
# HTTP/1.1 200 OK
# Server: nginx
```

讓 Nginx 成功 Proxy SeaweedFS
```bash
sudo vi /etc/nginx/sites-available/seaweedfs-s3
```
```
server {
    listen 80;
    server_name s3.example.com;

    client_max_body_size 0;

    proxy_http_version 1.1;
    proxy_request_buffering off;
    proxy_buffering off;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_connect_timeout 60s;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;

    proxy_pass http://127.0.0.1:8333;
}
```
```bash
sudo ln -s \
  /etc/nginx/sites-available/seaweedfs-s3 \
  /etc/nginx/sites-enabled/seaweedfs-s3

sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t
# syntax is ok
# test is successful

sudo systemctl reload nginx

curl -I \
  -H 'Host: s3.example.com' \
  http://127.0.0.1
```

## 自動更新憑證

建立憑證
```bash
# 安裝 Certbot
sudo apt install -y certbot python3-certbot-nginx

# 申請 S3 certificate
sudo certbot --nginx -d s3.example.com

sudo nginx -t

sudo systemctl reload nginx

curl -I https://s3.example.com
```
HTTPS 自動續期
```bash
# Let's Encrypt 設定好後確認
sudo systemctl status certbot.timer

sudo certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
```

自建憑證
```bash
sudo mkdir -p /etc/nginx/ssl
sudo chmod 700 /etc/nginx/ssl

# 執行在 examples/demo 中的腳本生成憑證
./generate-certs.sh

# 前往憑證目錄
cd certs

# 複製憑證
# ssl_certificate 通常應該使用 server certificate + intermediate certificate
# 也就是 fullchain.pem 類似的檔案，而不是只放 leaf certificate
# sudo ln -s "$PWD/tls.key" /etc/nginx/ssl/nexai.org.com.key
# sudo ln -s "$PWD/fullchain.crt" /etc/nginx/ssl/nexai.org.com.fullchain.crt
sudo cp tls.key /etc/nginx/ssl/nexai.org.com.key
sudo cp fullchain.crt /etc/nginx/ssl/nexai.org.com.fullchain.crt

# 設定權限
sudo chmod 644 /etc/nginx/ssl/nexai.org.com.fullchain.crt
sudo chmod 600 /etc/nginx/ssl/nexai.org.com.key

# 確認
sudo openssl x509 \
  -in /etc/nginx/ssl/nexai.org.com.fullchain.crt \
  -noout \
  -subject \
  -issuer \
  -dates \
  -ext subjectAltName
# subject=C=TW, ST=Taiwan, L=Taipei, O=NexAI Tech, OU=IT Infrastructure, CN=*.nexai.org.com
# issuer=C=TW, ST=Taiwan, L=Taipei, O=NexAI Tech, OU=IT Infrastructure, CN=NexAI Internal Root CA
# notBefore=Sep  2 08:25:26 2026 GMT
# notAfter=Aug 30 08:25:26 2036 GMT
# X509v3 Subject Alternative Name: 
#     DNS:*.nexai.org.com, DNS:nexai.org.com
```
讓 Ubuntu 信任你的 Root CA
```bash
sudo cp rootCA.crt \
  /usr/local/share/ca-certificates/nexai-root-ca.crt

sudo update-ca-certificates
# Updating certificates in /etc/ssl/certs...
# rehash: warning: skipping ca-certificates.crt, it does not contain exactly one certificate or CRL
# 1 added, 0 removed; done.
# Running hooks in /etc/ca-certificates/update.d...
# done.

ls -l /etc/ssl/certs/ | grep nexai
```

## 建立 Admin 帳號密碼
```bash
sudo apt install -y apache2-utils

# 建立帳號
# -c 會清空並重新建立整個檔案
sudo htpasswd -c /etc/nginx/.htpasswd admin
# New password: 
# Re-type new password: 
# Adding password for user admin

# 更新該帳號
# 不加 -c，只會更新該帳號或新增帳號
sudo htpasswd /etc/nginx/.htpasswd admin
# New password: 
# Re-type new password: 
# Updating password for user admin

# 新增帳號
# 不加 -c，只會更新該帳號或新增帳號
sudo htpasswd /etc/nginx/.htpasswd user
# New password: 
# Re-type new password: 
# Adding password for user user

# 刪除特定帳號
# 加 -D 參數
sudo htpasswd -D /etc/nginx/.htpasswd user
# Deleting password for user user

# 檢查
sudo cat /etc/nginx/.htpasswd
# admin:$apr1$xxxxxxxx$xxxxxxxx

# 權限
sudo chown root:www-data /etc/nginx/.htpasswd
sudo chmod 640 /etc/nginx/.htpasswd

# 重新載入 Nginx 設定
sudo systemctl reload nginx
```


## 完整 Nginx 設定檔
HTTP 強制轉 HTTPS
確認 HTTPS 正常之後，再把 HTTP 強制 redirect

### 加入 S3
```bash
sudo vi /etc/nginx/sites-available/seaweedfs-s3
```
```
server {
    listen 80;
    server_name s3-seaweedfs.nexai.org.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name s3-seaweedfs.nexai.org.com;

    ssl_certificate     /etc/nginx/ssl/nexai.org.com.fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/nexai.org.com.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 0;

    location / {
        proxy_http_version 1.1;

        proxy_request_buffering off;
        proxy_buffering off;

        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_pass http://127.0.0.1:8333;
    }
}
```
```bash
sudo ln -s \
  /etc/nginx/sites-available/seaweedfs-s3 \
  /etc/nginx/sites-enabled/seaweedfs-s3

sudo nginx -t
```

### 加入 Filer
```bash
sudo vi /etc/nginx/sites-available/seaweedfs-filer 
```
```
# IP 限制
location / {
    auth_basic "SeaweedFS Filer";
    auth_basic_user_file /etc/nginx/.htpasswd;

    proxy_http_version 1.1;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_pass http://127.0.0.1:8888;
}

server {
    listen 80;
    server_name filer-seaweedfs.nexai.org.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name filer-seaweedfs.nexai.org.com;

    ssl_certificate     /etc/nginx/ssl/nexai.org.com.fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/nexai.org.com.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    auth_basic "SeaweedFS Filer";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_pass http://127.0.0.1:8888;
    }
}
```
```bash
sudo ln -s \
  /etc/nginx/sites-available/seaweedfs-filer \
  /etc/nginx/sites-enabled/seaweedfs-filer

sudo nginx -t
```

### 加入 Admin UI
```bash
sudo vi /etc/nginx/sites-available/seaweedfs-admin  
```
```
# IP 限制
location / {
    allow 10.90.1.0/24;
    deny all;

    auth_basic "SeaweedFS Administration";
    auth_basic_user_file /etc/nginx/.htpasswd;

    proxy_http_version 1.1;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_pass http://127.0.0.1:23646;
}

server {
    listen 80;
    server_name seaweedfs.nexai.org.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name seaweedfs.nexai.org.com;

    ssl_certificate     /etc/nginx/ssl/nexai.org.com.fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/nexai.org.com.key;

    ssl_protocols TLSv1.2 TLSv1.3;

    auth_basic "SeaweedFS Administration";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_pass http://127.0.0.1:23646;
    }
}
```
```bash
sudo ln -s \
  /etc/nginx/sites-available/seaweedfs-admin \
  /etc/nginx/sites-enabled/seaweedfs-admin

sudo nginx -t
```

### 重新載入 Nginx 設定
```bash
# 如果還有 default 可以移除
sudo rm -f /etc/nginx/sites-enabled/default

# Nginx 檢查
sudo nginx -t
# nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
# nginx: configuration file /etc/nginx/nginx.conf test is successful

# 重新載入 Nginx 設定
sudo systemctl reload nginx
```

### 測試連線

如果憑證已經被 Client 信任
```bash
# 不要需用 -k 才能真正驗證 certificate trust
curl -v https://s3-seaweedfs.nexai.org.com/

curl -v -u admin \
  https://seaweedfs.nexai.org.com/

curl -v -u admin \
  https://filer-seaweedfs.nexai.org.com/
```

如果憑證尚未被 Client 信任
```bash
# 需要加上 -k  
curl -vk https://s3-seaweedfs.nexai.org.com/

curl -vk -u admin \
  https://seaweedfs.nexai.org.com/

curl -vk -u admin \
  https://filer-seaweedfs.nexai.org.com/
```

如果還沒有處理好 DNS 或 Hosts
```bash
# 需要加上 --resolve  
curl -vk \
  --resolve s3-seaweedfs.nexai.org.com:443:10.90.1.125 https://s3-seaweedfs.nexai.org.com/

curl -vk \
  -u admin \
  --resolve seaweedfs.nexai.org.com:443:10.90.1.125 https://seaweedfs.nexai.org.com/

curl -vk \
  -u admin \
  --resolve filer-seaweedfs.nexai.org.com:443:10.90.1.125 https://filer-seaweedfs.nexai.org.com/

# 變數替換
SEAWEEDFS_HOSTNAME="s3-seaweedfs.nexai.org.com";
SEAWEEDFS_HOSTNAME="seaweedfs.nexai.org.com";
SEAWEEDFS_HOSTNAME="filer-seaweedfs.nexai.org.com";
curl -vk \
  --resolve "${SEAWEEDFS_HOSTNAME}:443:10.90.1.125" "https://${SEAWEEDFS_HOSTNAME}/"
```

## Firewall
```bash
sudo ufw status verbose
sudo ufw status numbered

# 如果顯示 Status: inactive

# 先允許 SSH / HTTP / HTTPS
# sudo ufw allow OpenSSH
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# 加入 SeaweedFS 封鎖規則
sudo ufw deny 7333/tcp
sudo ufw deny 8181/tcp
sudo ufw deny 8333/tcp
sudo ufw deny 8888/tcp
sudo ufw deny 9101/tcp
sudo ufw deny 23646/tcp

# 確認規則
sudo ufw status numbered

# 啟用 UFW
sudo ufw enable
# Command may disrupt existing ssh connections. Proceed with operation (y|n)? 
# 輸入 y

sudo ufw status verbose
```

確認 SeaweedFS 本身沒問題
```bash
# 應該成功
curl -v http://127.0.0.1:8333/
curl -v http://127.0.0.1:8888/
curl -v http://127.0.0.1:23646/
```

從另一台機器測 Firewall
```bash
# 應該成功
curl -vk https://s3-seaweedfs.nexai.org.com/

curl -vk \
  -u admin \
  https://seaweedfs.nexai.org.com/

curl -vk \
  -u admin \
  https://filer-seaweedfs.nexai.org.com/

# 應該被 firewall 擋住
curl -v http://10.90.1.125:8333/
curl -v http://10.90.1.125:8888/
curl -v http://10.90.1.125:23646/
```
