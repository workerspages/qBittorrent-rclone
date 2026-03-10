FROM alpine:latest

# ==========================================
# 环境变量配置区 (适配 PaaS 平台)
# ==========================================
# 优先使用 PaaS 注入的 PORT 变量，默认回退为 8080
ENV PORT=8080
# WebDAV 服务的配置
ENV WEBDAV_PORT=8081
ENV WEBDAV_USER=admin
ENV WEBDAV_PASS=password
# 基础环境配置
ENV TZ=Asia/Shanghai
ENV QBT_PROFILE=/data/config

# ==========================================
# 安装依赖与获取程序
# ==========================================
RUN apk update && \
    apk add --no-cache bash curl unzip rclone tzdata ca-certificates jq sed && \
    mkdir -p /tmp/qbittorrent && \
    # 自动拉取最新静态编译版 qBittorrent-EE
    LATEST_URL=$(curl -s https://api.github.com/repos/c0re100/qBittorrent-Enhanced-Edition/releases/latest | jq -r '.assets[] | select(.name | test("x86_64-linux-musl_static.zip$")) | .browser_download_url') && \
    echo "Downloading qBittorrent from: $LATEST_URL" && \
    curl -L $LATEST_URL -o /tmp/qbittorrent/qb.zip && \
    unzip /tmp/qbittorrent/qb.zip -d /tmp/qbittorrent && \
    mv /tmp/qbittorrent/qbittorrent-nox /usr/local/bin/qbittorrent-nox && \
    chmod +x /usr/local/bin/qbittorrent-nox && \
    # 清理构建垃圾减小体积
    apk del jq && \
    rm -rf /tmp/qbittorrent /var/cache/apk/*

# 创建数据存储和配置目录
RUN mkdir -p /data/downloads /data/config/qBittorrent/config /data/rclone

# 注入启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 暴露端口 (PaaS 通常会根据 ENV 自动映射，这里作声明参考)
EXPOSE 8080 8081 6881 6881/udp

# 指定数据卷
VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]
