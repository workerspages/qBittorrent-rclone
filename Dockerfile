FROM alpine:latest

# 环境变量设置
ENV QBT_WEBUI_PORT=8080
ENV WEBDAV_PORT=8081
ENV WEBDAV_USER=admin
ENV WEBDAV_PASS=password
ENV TZ=Asia/Shanghai
ENV QBT_PROFILE=/data/config
ENV RCLONE_CONFIG=/data/rclone/rclone.conf

# 安装依赖、rclone，并获取最新版 qBittorrent-Enhanced-Edition 静态编译版
RUN apk update && \
    apk add --no-cache bash curl unzip rclone tzdata ca-certificates jq && \
    mkdir -p /tmp/qbittorrent && \
    # 使用 GitHub API 自动获取最新发布的 x86_64-linux-musl_static.zip 下载链接
    LATEST_URL=$(curl -s https://api.github.com/repos/c0re100/qBittorrent-Enhanced-Edition/releases/latest | jq -r '.assets[] | select(.name | test("x86_64-linux-musl_static.zip$")) | .browser_download_url') && \
    echo "Downloading qBittorrent from: $LATEST_URL" && \
    curl -L $LATEST_URL -o /tmp/qbittorrent/qb.zip && \
    unzip /tmp/qbittorrent/qb.zip -d /tmp/qbittorrent && \
    mv /tmp/qbittorrent/qbittorrent-nox /usr/local/bin/qbittorrent-nox && \
    chmod +x /usr/local/bin/qbittorrent-nox && \
    # 清理临时文件和不必要的包以减小镜像体积
    apk del jq && \
    rm -rf /tmp/qbittorrent /var/cache/apk/*

# 创建所需的数据目录
RUN mkdir -p /data/downloads /data/config /data/rclone /data/scripts

# 复制启动脚本并赋予执行权限
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 暴露 WebUI端口、WebDAV端口 和 BT通讯端口
EXPOSE 8080 8081 6881 6881/udp

# 指定数据卷，方便在 PaaS 上挂载持久化存储
VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]
