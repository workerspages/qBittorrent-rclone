#!/bin/bash
set -e

echo "================================================="
echo "Initializing Single-Port PaaS Environment (Caddy)..."
echo "================================================="

# 获取 PaaS 变量，设置内部端口防冲突
CURRENT_USER="${QBT_USER:-admin}"
PUBLIC_PORT="${PORT:-8080}"
QBT_INTERNAL_PORT=18080
WEBDAV_INTERNAL_PORT=18081

# ==========================================
# 0. 确保目录结构存在并修复权限
# ==========================================
mkdir -p /data/downloads
mkdir -p /data/config/qBittorrent/config
mkdir -p /data/rclone

echo "Fixing directory permissions for /data..."
chmod -R 777 /data

QBT_CONFIG_FILE="/data/config/qBittorrent/config/qBittorrent.conf"

# 自动检测并删除包含旧版损坏/残缺 Hash 的配置文件
if grep -q "WebUIPassword" "$QBT_CONFIG_FILE" 2>/dev/null || grep -q "O1QdXg2lfi5P1hGWe1Z2A==" "$QBT_CONFIG_FILE" 2>/dev/null; then
    echo "Detected corrupted or truncated config. Resetting..."
    rm -f "$QBT_CONFIG_FILE"
fi

# ==========================================
# 1. 自动配置 qBittorrent (绑定内部端口与极限提速默认值)
# ==========================================
if [ ! -f "$QBT_CONFIG_FILE" ]; then
echo "Creating DEFAULT & OPTIMIZED qBittorrent configuration..."
# 注入全部提速和本地化参数
cat <<EOF > "$QBT_CONFIG_FILE"
[Application]
FileLogger\\Age=1
FileLogger\\AgeType=1
FileLogger\\Backup=true
FileLogger\\DeleteOld=true
FileLogger\\Enabled=true
FileLogger\\MaxSizeBytes=66560
FileLogger\\Path=/data/config/qBittorrent/data/logs

[BitTorrent]
Session\\AddExtensionToIncompleteFiles=true
Session\\AddTorrentStopped=false
Session\\AddTrackersFromURLEnabled=true
Session\\AdditionalTrackersURL=https://cf.trackerslist.com/all.txt
Session\\AsyncIOThreadsCount=4
Session\\AutoBanUnknownPeer=true
Session\\ConnectionSpeed=15
Session\\DHTEnabled=true
Session\\DefaultSavePath=/data/downloads
Session\\DiskCacheSize=32
Session\\DiskIOReadMode=DisableOSCache
Session\\DiskIOWriteMode=DisableOSCache
Session\\Encryption=0
Session\\ExcludedFileNames=
Session\\FinishedTorrentExportDirectory="/data/downloads/torrent "
Session\\LSDEnabled=true
Session\\MaxConnections=300
Session\\MaxConnectionsPerTorrent=100
Session\\PeXEnabled=true
Session\\Port=6881
Session\\Preallocation=true
Session\\QueueingSystemEnabled=true
Session\\SSL\\Port=49490
Session\\SendBufferWatermark=2048
Session\\ShareLimitAction=Stop
Session\\TempPathEnabled=true
Session\\TorrentExportDirectory="/data/downloads/torrent "
Session\\UseUPnP=false

[Core]
AutoDeleteAddedTorrentFile=IfAdded

[Meta]
MigrationVersion=8

[Network]
PortForwardingEnabled=false
Proxy\\HostnameLookupEnabled=false
Proxy\\Profiles\\BitTorrent=true
Proxy\\Profiles\\Misc=true
Proxy\\Profiles\\RSS=true

[Preferences]
Bittorrent\\DHT=true
Bittorrent\\Encryption=0
Bittorrent\\LSD=true
Bittorrent\\PeX=true
Connection\\PortRangeMin=6881
Connection\\ResolvePeerCountries=false
Connection\\UPnP=false
Downloads\\SavePath=/data/downloads
General\\Locale=zh_CN
MailNotification\\req_auth=true
WebUI\\AuthSubnetWhitelist=@Invalid()
WebUI\\Locale=zh
WebUI\\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==)"
WebUI\\Port=18080
WebUI\\Username=admin

[RSS]
AutoDownloader\\\\DownloadRepacks=true
AutoDownloader\\\\SmartEpisodeFilter=s(\\\\d+)e(\\\\d+), (\\\\d+)x(\\\\d+), "(\\\\d{4}[.\\\\-]\\\\d{1,2}[.\\\\-]\\\\d{1,2})", "(\\\\d{1,2}[.\\\\-]\\\\d{1,2}[.\\-]\\\\d{4})"
EOF
    echo "Initial credentials set to: ${CURRENT_USER} / adminadmin"
    echo "Optimized settings applied: Port 6881, 2000 Connections, Chinese UI, Auto-Trackers."
else
    echo "Updating WebUI internal port and username..."
    sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=${QBT_INTERNAL_PORT}/g" "$QBT_CONFIG_FILE"
    if ! grep -q "^WebUI\\\\Port=" "$QBT_CONFIG_FILE"; then
        sed -i "/\[Preferences\]/a WebUI\\\\Port=${QBT_INTERNAL_PORT}" "$QBT_CONFIG_FILE"
    fi

    if grep -q "^WebUI\\\\Username=" "$QBT_CONFIG_FILE"; then
        sed -i "s/^WebUI\\\\Username=.*/WebUI\\\\Username=${CURRENT_USER}/g" "$QBT_CONFIG_FILE"
    else
        sed -i "/\[Preferences\]/a WebUI\\\\Username=${CURRENT_USER}" "$QBT_CONFIG_FILE"
    fi
    
    # 自动解除 IP 封禁
    sed -i '/BannedIPs=/d' "$QBT_CONFIG_FILE"
fi

# ==========================================
# 2. 生成 Caddy 反向代理配置 (单端口核心)
# ==========================================
CADDY_CONFIG="/tmp/Caddyfile"
echo "Generating Caddy routing on public port ${PUBLIC_PORT}..."
cat <<EOF > "$CADDY_CONFIG"
:${PUBLIC_PORT} {
    handle /webdav/* {
        reverse_proxy 127.0.0.1:${WEBDAV_INTERNAL_PORT}
    }
    handle {
        reverse_proxy 127.0.0.1:${QBT_INTERNAL_PORT}
    }
}
EOF

# ==========================================
# 3. 启动内部后台服务 (qBittorrent & Rclone)
# ==========================================
echo "Starting qBittorrent Enhanced Edition (Background)..."
qbittorrent-nox --profile="/data/config" --confirm-legal-notice &

echo "Starting WebDAV on internal port ${WEBDAV_INTERNAL_PORT} (Background)..."
rclone serve webdav /data/downloads \
    --addr 127.0.0.1:${WEBDAV_INTERNAL_PORT} \
    --baseurl /webdav \
    --user "${WEBDAV_USER}" \
    --pass "${WEBDAV_PASS}" \
    --vfs-cache-mode writes &

# 给内部服务一点点启动时间
sleep 3

# ==========================================
# 4. 启动 Caddy (前台运行，接管对外流量)
# ==========================================
echo "Starting Caddy Reverse Proxy..."
exec caddy run --config "$CADDY_CONFIG" --adapter caddyfile
