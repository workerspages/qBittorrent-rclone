#!/bin/bash
set -e

echo "================================================="
echo "Initializing PaaS Environment Config & Permissions..."
echo "================================================="

# 获取环境变量，如果未在 PaaS 设置，则赋予默认值
CURRENT_USER="${QBT_USER:-admin}"
CURRENT_PORT="${PORT:-8080}"

# ==========================================
# 0. 确保目录结构存在并修复权限
# ==========================================
mkdir -p /data/downloads
mkdir -p /data/config/qBittorrent/config
mkdir -p /data/rclone

echo "Fixing directory permissions for /data..."
chmod -R 777 /data

QBT_CONFIG_FILE="/data/config/qBittorrent/config/qBittorrent.conf"

# ==========================================
# 1. 自动修复旧版本的配置 Bug
# ==========================================
if grep -q "WebUIPassword" "$QBT_CONFIG_FILE" 2>/dev/null; then
    echo "Detected corrupted config from previous version. Resetting..."
    rm -f "$QBT_CONFIG_FILE"
fi

# ==========================================
# 2. 自动配置 qBittorrent (注入环境变量)
# ==========================================
if [ ! -f "$QBT_CONFIG_FILE" ]; then
    echo "Creating default qBittorrent configuration..."
    cat <<EOF > "$QBT_CONFIG_FILE"
[BitTorrent]
Session\\DefaultSavePath=/data/downloads

[Preferences]
Downloads\\SavePath=/data/downloads
WebUI\\Port=${CURRENT_PORT}
WebUI\\Username=${CURRENT_USER}
WebUI\\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8O1QdXg2lfi5P1hGWe1Z2A==)"
EOF
    echo "Initial credentials set to: ${CURRENT_USER} / adminadmin"
    echo "Default save path permanently linked to: /data/downloads"
else
    # 如果配置文件已存在，依然强制同步 PaaS 环境变量中的端口和用户名
    echo "Updating WebUI port and username from Environment Variables..."
    
    # 更新端口
    sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=${CURRENT_PORT}/g" "$QBT_CONFIG_FILE"
    if ! grep -q "^WebUI\\\\Port=" "$QBT_CONFIG_FILE"; then
        sed -i "/\[Preferences\]/a WebUI\\\\Port=${CURRENT_PORT}" "$QBT_CONFIG_FILE"
    fi

    # 更新用户名
    if grep -q "^WebUI\\\\Username=" "$QBT_CONFIG_FILE"; then
        sed -i "s/^WebUI\\\\Username=.*/WebUI\\\\Username=${CURRENT_USER}/g" "$QBT_CONFIG_FILE"
    else
        sed -i "/\[Preferences\]/a WebUI\\\\Username=${CURRENT_USER}" "$QBT_CONFIG_FILE"
    fi
    
    # ==========================================
    # ★ 新增：自动解除 IP 封禁，防止 PaaS 网关被 Ban 导致死锁
    # ==========================================
    echo "Clearing any Banned IPs to prevent lockout..."
    sed -i '/BannedIPs=/d' "$QBT_CONFIG_FILE"
fi

# ==========================================
# 3. 启动 WebDAV 服务 (后台运行)
# ==========================================
echo "Starting WebDAV on port ${WEBDAV_PORT} with user: ${WEBDAV_USER}"
rclone serve webdav /data/downloads \
    --addr :${WEBDAV_PORT} \
    --user "${WEBDAV_USER}" \
    --pass "${WEBDAV_PASS}" \
    --vfs-cache-mode writes &

# ==========================================
# 4. 启动 qBittorrent (前台运行)
# ==========================================
echo "Starting qBittorrent Enhanced Edition..."
exec qbittorrent-nox --profile="/data/config"
