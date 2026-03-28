FROM alpine:latest

# 环境变量设置
ENV PORT=8080
ENV TZ=Asia/Shanghai
ENV QBT_PROFILE=/data/config

# 安装依赖、Rclone、Caddy，并获取最新版 qBittorrent-Enhanced-Edition
RUN apk update && \
    apk add --no-cache bash curl unzip rclone caddy tzdata ca-certificates jq sed python3 py3-requests py3-pip && \
    pip3 install --no-cache-dir qbittorrent-api --break-system-packages && \
    ln -sf /usr/bin/python3 /usr/bin/python && \
    mkdir -p /tmp/qbittorrent && \
    LATEST_URL=$(curl -s https://api.github.com/repos/c0re100/qBittorrent-Enhanced-Edition/releases/latest | jq -r '.assets[] | select(.name | test("x86_64-linux-musl_static.zip$")) | .browser_download_url') && \
    echo "Downloading qBittorrent from: $LATEST_URL" && \
    curl -L $LATEST_URL -o /tmp/qbittorrent/qb.zip && \
    unzip /tmp/qbittorrent/qb.zip -d /tmp/qbittorrent && \
    mv /tmp/qbittorrent/qbittorrent-nox /usr/local/bin/qbittorrent-nox && \
    chmod +x /usr/local/bin/qbittorrent-nox && \
    apk del jq && \
    rm -rf /tmp/qbittorrent /var/cache/apk/*

# 创建所需的数据目录及默认配置目录
RUN mkdir -p /data/downloads /data/config/qBittorrent/config /data/rclone /defaults

# 复制默认配置文件、分类文件、搜索引擎插件和启动脚本并赋予执行权限
COPY qBittorrent.conf /defaults/qBittorrent.conf
COPY categories.json /defaults/categories.json
COPY engines /defaults/engines
COPY monitor.py /defaults/monitor.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 仅暴露唯一的一个公网 HTTP 端口 (供 PaaS 映射) 以及 BT 端口
EXPOSE $PORT 6881 6881/udp

VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]
