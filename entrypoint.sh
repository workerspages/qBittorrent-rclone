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
echo "$(date '+%Y-%m-%d %H:%M:%S') - Task Finished: ${TORRENT_NAME}" >> "$LOG_FILE"

# --- 步骤 1: 发送 Bark 通知 (如有) ---
if [ -n "$BARK_SERVER" ] && [ -n "$BARK_KEY" ]; then
    if command -v curl > /dev/null 2>&1; then
        SERVER=$(echo "$BARK_SERVER" | sed 's/\/$//')
        curl -k -s -X POST "${SERVER}/${BARK_KEY}" \
             --data-urlencode "title=下载完成" \
             --data-urlencode "body=${TORRENT_NAME} 已下载完毕！" > /dev/null 2>&1
        echo "Bark notification sent." >> "$LOG_FILE"
    fi
fi

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
        # 成功后再次发送通知
        if [ -n "$BARK_SERVER" ] && [ -n "$BARK_KEY" ] && command -v curl > /dev/null 2>&1; then
            SERVER=$(echo "$BARK_SERVER" | sed 's/\/$//')
            curl -k -s -X POST "${SERVER}/${BARK_KEY}" \
                 --data-urlencode "title=上传网盘成功" \
                 --data-urlencode "body=${TORRENT_NAME} 已同步至 ${RCLONE_DESTINATION}" > /dev/null 2>&1
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Rclone upload failed with code ${RCLONE_EXIT_CODE}." >> "$LOG_FILE"
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

# 动态注入或更新外部程序执行 (修改为传入 %N 和保存根路径组合的 %D/%N 以供 rclone 获取全路径)
# qBittorrent 变量： %N (名称)  %D (保存路径，如果是多文件则是父目录，单文件则是文件所在目录)
# 由于 %D 在不同种子类型下表现存在差异，为兼容性统一传递名称和绝对路径
# 这里直接传入完整路径参数 %F 和名称 %N
if grep -q "^\[AutoRun\]" "$QBT_CONFIG_FILE"; then
    sed -i "s|^Program=.*|Program=sh ${NOTIFY_SCRIPT} \"%N\" \"%F\"|g" "$QBT_CONFIG_FILE"
    sed -i "s/^Enabled=false/Enabled=true/g" "$QBT_CONFIG_FILE"
    
    # 兼容最新版配置字段
    if grep -q "^OnTorrentFinished\\\\Program=" "$QBT_CONFIG_FILE"; then
        sed -i "s|^OnTorrentFinished\\\\Program=.*|OnTorrentFinished\\\\Program=sh ${NOTIFY_SCRIPT} \"%N\" \"%F\"|g" "$QBT_CONFIG_FILE"
        sed -i "s/^OnTorrentFinished\\\\Enabled=false/OnTorrentFinished\\\\Enabled=true/g" "$QBT_CONFIG_FILE"
    else
        sed -i "/\[AutoRun\]/a OnTorrentFinished\\\\Program=sh ${NOTIFY_SCRIPT} \"%N\" \"%F\"\nOnTorrentFinished\\\\Enabled=true" "$QBT_CONFIG_FILE"
    fi
else
    echo -e "\n[AutoRun]\nEnabled=true\nProgram=sh ${NOTIFY_SCRIPT} \"%N\" \"%F\"\nOnTorrentFinished\\\\Enabled=true\nOnTorrentFinished\\\\Program=sh ${NOTIFY_SCRIPT} \"%N\" \"%F\"" >> "$QBT_CONFIG_FILE"
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
