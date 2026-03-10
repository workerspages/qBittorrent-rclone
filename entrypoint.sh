#!/bin/bash
set -e

echo "================================================="
echo "Initializing PaaS Environment Config & Permissions..."
echo "================================================="

# ==========================================
# 0. 确保目录结构存在并修复权限 (终极修复方案)
# ==========================================
# 即使 PaaS 挂载了空的持久化磁盘，这里也会自动建好目录
mkdir -p /data/downloads
mkdir -p /data/config/qBittorrent/config
mkdir -p /data/rclone

# 强制赋予 /data 目录最高读写权限 (777)，彻底解决 PaaS 挂载卷权限冲突导致的 Permission denied 问题
echo "Fixing directory permissions for /data..."
chmod -R 777 /data

QBT_CONFIG_FILE="/data/config/qBittorrent/config/qBittorrent.conf"

# ==========================================
# 1. 自动配置 qBittorrent (解决无终端痛点)
# ==========================================
if [ ! -f "$QBT_CONFIG_FILE" ]; then
    echo "Creating default qBittorrent configuration..."
    cat <<EOF > "$QBT_CONFIG_FILE"
[BitTorrent]
Session\DefaultSavePath=/data/downloads

[Preferences]
Downloads\SavePath=/data/downloads
WebUI\Port=${PORT}
WebUI\Username=admin
WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8O1QdXg2lfi5P1hGWe1Z2A==)"
EOF
    echo "Initial credentials set to: admin / adminadmin"
    echo "Default save path permanently linked to: /data/downloads"
else
    # 如果配置文件已存在，确保 WebUI 端口与 PaaS 环境变量 $PORT 保持一致
    echo "Updating WebUI port to ${PORT} in existing configuration..."
    sed -i "s/^WebUI\\\\Port=.*/WebUI\\\\Port=${PORT}/g" "$QBT_CONFIG_FILE"
    
    # 如果旧配置文件中没有 Port 字段，则追加进去
    if ! grep -q "^WebUI\\\\Port=" "$QBT_CONFIG_FILE"; then
        sed -i "/\[Preferences\]/a WebUI\\\\Port=${PORT}" "$QBT_CONFIG_FILE"
    fi
fi

# ==========================================
# 2. 启动 WebDAV 服务 (后台运行)
# ==========================================
echo "Starting WebDAV on port ${WEBDAV_PORT} with user: ${WEBDAV_USER}"
rclone serve webdav /data/downloads \
    --addr :${WEBDAV_PORT} \
    --user "${WEBDAV_USER}" \
    --pass "${WEBDAV_PASS}" \
    --vfs-cache-mode writes &

# ==========================================
# 3. 启动 qBittorrent (前台运行，占据主进程)
# ==========================================
echo "Starting qBittorrent Enhanced Edition..."
exec qbittorrent-nox --profile="/data/config"
