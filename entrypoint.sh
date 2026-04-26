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
mkdir -p /data/config/qBittorrent/data/nova3/engines
mkdir -p /data/rclone

if [ -d "/defaults/engines" ]; then
    echo "Installing default search engines..."
    cp -rf /defaults/engines/* /data/config/qBittorrent/data/nova3/engines/ 2>/dev/null || true
fi

echo "Fixing directory permissions for /data..."
chmod -R 777 /data

QBT_CONFIG_FILE="/data/config/qBittorrent/config/qBittorrent.conf"
QBT_CATEGORIES_FILE="/data/config/qBittorrent/config/categories.json"

# 自动检测并删除包含旧版损坏/残缺 Hash 的配置文件
if grep -q "WebUIPassword" "$QBT_CONFIG_FILE" 2>/dev/null || grep -q "O1QdXg2lfi5P1hGWe1Z2A==" "$QBT_CONFIG_FILE" 2>/dev/null; then
    echo "Detected corrupted or truncated config. Resetting..."
    rm -f "$QBT_CONFIG_FILE"
fi

# ==========================================
# 1. 生成 Bark 自动通知与 rclone 上传脚本
# ==========================================
NOTIFY_SCRIPT="/data/config/qBittorrent/config/notify.sh"
echo "Generating notification & upload script..."

# 1.1 如果提供了 base64 格式的 rclone 配置文件，则将其解码并写入（便于 PaaS 注入配置）
if [ -n "$RCLONE_CONFIG_BASE64" ]; then
    echo "Decoding base64 rclone configuration..."
    mkdir -p /root/.config/rclone
    echo "$RCLONE_CONFIG_BASE64" | base64 -d > /root/.config/rclone/rclone.conf
    # 若存在，则同时拷贝到网盘挂载配置处，确保 rclone serve也能读到
    cp /root/.config/rclone/rclone.conf /data/rclone/rclone.conf
fi

# 1.2 注入环境变量到脚本头部
cat << EOF > "$NOTIFY_SCRIPT"
#!/bin/sh
BARK_SERVER="${BARK_SERVER}"
BARK_KEY="${BARK_KEY}"
RCLONE_DESTINATION="${RCLONE_DESTINATION}"
RCLONE_UPLOAD_MODE="${RCLONE_UPLOAD_MODE:-copy}"
EOF

# 1.3 追加核心运行逻辑（通知 + Rclone 传输）
cat << 'EOF' >> "$NOTIFY_SCRIPT"
TORRENT_NAME="$1"
# qBittorrent 会把全路径传过来，如 /data/downloads/MyMovie
TORRENT_PATH="$2" 
LOG_FILE="/data/downloads/automation.log"

echo "======================================" >> "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') - notify.sh triggered" >> "$LOG_FILE"
echo "  TORRENT_NAME: ${TORRENT_NAME}" >> "$LOG_FILE"
echo "  TORRENT_PATH: ${TORRENT_PATH}" >> "$LOG_FILE"
echo "  BARK_SERVER:  ${BARK_SERVER:-(empty)}" >> "$LOG_FILE"
echo "  BARK_KEY:     ${BARK_KEY:+***set***}${BARK_KEY:-empty}" >> "$LOG_FILE"

# --- Bark 通知发送函数 ---
send_bark() {
    NOTIFY_TITLE="$1"
    NOTIFY_BODY="$2"
    if [ -z "$BARK_SERVER" ] || [ -z "$BARK_KEY" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Bark not configured, skipping notification." >> "$LOG_FILE"
        return 0
    fi
    if ! command -v curl > /dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: curl not found, cannot send Bark notification." >> "$LOG_FILE"
        return 1
    fi
    SERVER=$(echo "$BARK_SERVER" | sed 's/\/$//')
    # 使用 Bark V2 JSON API（/push 端点），兼容性最好
    BARK_RESPONSE=$(curl -k -s -w "\nHTTP_CODE:%{http_code}" -X POST "${SERVER}/push" \
         -H 'Content-Type: application/json; charset=utf-8' \
         -d "{\"device_key\":\"${BARK_KEY}\",\"title\":\"${NOTIFY_TITLE}\",\"body\":\"${NOTIFY_BODY}\"}" 2>&1)
    BARK_HTTP_CODE=$(echo "$BARK_RESPONSE" | grep 'HTTP_CODE:' | sed 's/HTTP_CODE://')
    BARK_BODY=$(echo "$BARK_RESPONSE" | grep -v 'HTTP_CODE:')
    if [ "$BARK_HTTP_CODE" = "200" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Bark notification sent OK (HTTP $BARK_HTTP_CODE)." >> "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Bark notification may have failed (HTTP $BARK_HTTP_CODE)." >> "$LOG_FILE"
        echo "  Response: $BARK_BODY" >> "$LOG_FILE"
    fi
}

# --- 步骤 1: 发送下载完成通知 ---
send_bark "下载完成" "${TORRENT_NAME} 已下载完毕！"

# --- 步骤 2: Rclone 自动上传 (如有) ---
if [ -n "$RCLONE_DESTINATION" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting Rclone ${RCLONE_UPLOAD_MODE} to ${RCLONE_DESTINATION}" >> "$LOG_FILE"
    
    # 根据用户设定是 copy 还是 move
    if [ "$RCLONE_UPLOAD_MODE" = "move" ]; then
        rclone move "$TORRENT_PATH" "${RCLONE_DESTINATION}/${TORRENT_NAME}" -v --config /root/.config/rclone/rclone.conf >> "$LOG_FILE" 2>&1
        RCLONE_EXIT_CODE=$?
    else
        rclone copy "$TORRENT_PATH" "${RCLONE_DESTINATION}/${TORRENT_NAME}" -v --config /root/.config/rclone/rclone.conf >> "$LOG_FILE" 2>&1
        RCLONE_EXIT_CODE=$?
    fi

    if [ $RCLONE_EXIT_CODE -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Rclone upload successful." >> "$LOG_FILE"
        send_bark "上传网盘成功" "${TORRENT_NAME} 已同步至 ${RCLONE_DESTINATION}"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Rclone upload failed with code ${RCLONE_EXIT_CODE}." >> "$LOG_FILE"
        send_bark "上传网盘失败" "${TORRENT_NAME} 上传失败，错误码: ${RCLONE_EXIT_CODE}"
    fi
fi
EOF

chmod +x "$NOTIFY_SCRIPT"

# ==========================================
# 2. 自动配置 qBittorrent (绑定内部端口与极限提速默认值)
# ==========================================
if [ ! -f "$QBT_CONFIG_FILE" ]; then
    echo "Copying DEFAULT & OPTIMIZED qBittorrent configuration..."
    cp /defaults/qBittorrent.conf "$QBT_CONFIG_FILE"
    echo "Initial credentials set to: ${CURRENT_USER} / adminadmin"
    echo "Optimized settings applied: Port 6881, Bark Notifications Enabled, Chinese UI."
fi

if [ ! -f "$QBT_CATEGORIES_FILE" ]; then
    echo "Copying default categories configuration..."
    cp /defaults/categories.json "$QBT_CATEGORIES_FILE"
fi

echo "Updating WebUI internal port, username and AutoRun script based on environment variables..."
# ==== 以下代码在每次启动时都会执行，以确保环境变量的修改能实时生效 ====
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

# === 安全修复：全面强制开启身份验证，防止 Caddy 反代导致公网免密 ===

# 1. 强制要求本地地址进行密码验证
sed -i "s/^WebUI\\\\LocalHostAuth=.*/WebUI\\\\LocalHostAuth=true/g" "$QBT_CONFIG_FILE"
if ! grep -q "^WebUI\\\\LocalHostAuth=" "$QBT_CONFIG_FILE"; then
    sed -i "/\[Preferences\]/a WebUI\\\\LocalHostAuth=true" "$QBT_CONFIG_FILE"
fi

# 2. 强制关闭 IP 子网白名单功能
sed -i "s/^WebUI\\\\AuthSubnetWhitelistEnabled=.*/WebUI\\\\AuthSubnetWhitelistEnabled=false/g" "$QBT_CONFIG_FILE"
if ! grep -q "^WebUI\\\\AuthSubnetWhitelistEnabled=" "$QBT_CONFIG_FILE"; then
    sed -i "/\[Preferences\]/a WebUI\\\\AuthSubnetWhitelistEnabled=false" "$QBT_CONFIG_FILE"
fi

# =====================================

# 动态注入或更新 torrent 完成时运行 的外部程序
if grep -q "^\[AutoRun\]" "$QBT_CONFIG_FILE"; then
    # 清理掉错误的 OnTorrentFinished 字段
    sed -i '/^OnTorrentFinished/d' "$QBT_CONFIG_FILE"
    # 清理大写的遗留字段
    sed -i '/^Program=.*/d' "$QBT_CONFIG_FILE"
    sed -i '/^Enabled=.*/d' "$QBT_CONFIG_FILE"
    
    # 正确注入小写的 enabled 和 program (对应"完成时运行")
    if grep -q "^program=" "$QBT_CONFIG_FILE"; then
        sed -i "s|^program=.*|program=sh ${NOTIFY_SCRIPT} \\\"%N\\\" \\\"%F\\\"|g" "$QBT_CONFIG_FILE"
        sed -i "s/^enabled=false/enabled=true/g" "$QBT_CONFIG_FILE"
    else
        sed -i "/\[AutoRun\]/a program=sh ${NOTIFY_SCRIPT} \\\"%N\\\" \\\"%F\\\"\nenabled=true" "$QBT_CONFIG_FILE"
    fi
else
    echo -e "\n[AutoRun]\nenabled=true\nprogram=sh ${NOTIFY_SCRIPT} \\\"%N\\\" \\\"%F\\\"" >> "$QBT_CONFIG_FILE"
fi

# ==========================================
# 3. 生成 Caddy 反向代理配置 (单端口核心)
# ==========================================
CADDY_CONFIG="/tmp/Caddyfile"
echo "Generating Caddy routing on public port ${PUBLIC_PORT}..."
cat <<EOF > "$CADDY_CONFIG"
{
    log {
        level ERROR
    }
}
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
# 4. 启动内部后台服务 (qBittorrent & Rclone)
# ==========================================
echo "Starting qBittorrent Enhanced Edition (Background)..."
qbittorrent-nox --profile="/data/config" --confirm-legal-notice &

echo "Starting qBittorrent completed files monitor (Background)..."
python3 /defaults/monitor.py &

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
# 5. 启动 Caddy (前台运行，接管对外流量)
# ==========================================
echo "Starting Caddy Reverse Proxy..."
exec caddy run --config "$CADDY_CONFIG" --adapter caddyfile
