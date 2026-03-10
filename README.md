
# qBittorrent Enhanced Edition + WebDAV (PaaS 单端口终极版)

这是一个专为现代 PaaS (Platform as a Service) 平台部署优化的 Docker 镜像项目。它集成了 **qBittorrent Enhanced Edition (增强版)** 与 **Rclone**，不仅提供强大的 BT/PT 下载功能，还内置了轻量级的 WebDAV 服务供本地拉取文件。

**🔥 核心突破 (单端口架构)：**
针对 Koyeb, Render, Heroku 等**严格限制只允许对外暴露一个 HTTP 端口**的 PaaS 平台，本镜像内置了 **Caddy** 轻量级反向代理服务器。它能将一个公网端口完美分发给内部的两个独立服务：
- 访问根路径 `/` ➡️ 路由至 qBittorrent 面板
- 访问路径 `/webdav/*` ➡️ 路由至 Rclone WebDAV 服务

## ✨ 核心特性

- **单端口双服务**：利用 Caddy 代理，彻底突破 PaaS 单端口限制。
- **自动构建最新版**：通过 GitHub Actions 自动获取并编译最新静态核心。
- **PaaS 深度优化**：
  - 支持通过环境变量 `QBT_USER` 自定义 qBittorrent 登录账号。
  - 自动注入默认密码，绕过新版 qBittorrent 终端随机密码锁死机制。
  - 动态适配 PaaS 平台强行注入的 `$PORT` 环境变量。
  - 容器启动时自动清除 IP 封禁记录（防 PaaS 网关被 Ban），并自动修复 `/data` 目录读写权限。
- **双端镜像推送**：自动将镜像推送到 Docker Hub 和 GHCR。

---

## ⚙️ 环境变量 (Environment Variables)

部署时，您可以通过设置以下环境变量来配置容器：

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `QBT_USER` | `admin` | qBittorrent WebUI 面板的登录用户名。 |
| `PORT` | `8080` | 对外暴露的唯一公网 HTTP 端口。大部分 PaaS 会自动注入此变量。 |
| `WEBDAV_USER` | `admin` | WebDAV 服务的登录用户名，**强烈建议修改**。 |
| `WEBDAV_PASS` | `password` | WebDAV 服务的登录密码，**强烈建议修改**。 |
| `TZ` | `Asia/Shanghai` | 容器时区。 |

*(注：由于采用了单端口代理架构，之前的 `WEBDAV_PORT` 变量已弃用，内部已自动接管。)*

---

## 📂 目录结构与数据持久化 (Volumes)

为了防止容器重启导致数据丢失，请在部署时，挂载持久化存储卷 (Volume) 到容器内的 `/data` 目录：

- `/data/config`：存储 qBittorrent 的配置文件和种子校验数据。
- `/data/downloads`：默认下载保存路径。WebDAV 服务仅会暴露此目录。
- `/data/rclone`：预留的 Rclone 配置文件目录。

---

## 🚀 部署指南

### 1. 在 Koyeb / Render 等单端口 PaaS 平台部署

1. 在控制台创建新的 Web Service 或 App。
2. 镜像来源选择 Docker，填入：`您的DockerHub账号/qbittorrent-ee-rclone:latest` (或 GHCR 链接)。
3. **设置端口 (Ports)**：仅暴露一个 HTTP 端口，填写 `8080` (平台通常会自动将其映射到 80 和 443)。
4. **环境变量 (Env Vars)**：添加 `QBT_USER`, `WEBDAV_USER`, `WEBDAV_PASS`。
5. **持久化存储 (Volumes)**：创建一个 Volume，挂载路径必须填写 `/data`。
6. 点击部署即可。

### 2. 在 Zeabur 等支持多端口的 PaaS 平台部署

操作基本同上。虽然 Zeabur 支持多端口，但由于本镜像已升级为单端口架构，您现在只需要为它生成**唯一的一个域名**即可同时访问面板和 WebDAV！建议在 Zeabur 的“网络”设置中，额外开启 `6881` (TCP) 的端口转发以加速 BT 下载。

### 3. 本地使用 Docker Compose 测试

```yaml
version: "3.8"
services:
  qbittorrent:
    image: ghcr.io/your-github-username/your-repo-name:latest
    container_name: qbittorrent-webdav
    restart: unless-stopped
    environment:
      - QBT_USER=myqbtuser
      - PORT=8080
      - WEBDAV_USER=mywebdavuser
      - WEBDAV_PASS=mypassword
      - TZ=Asia/Shanghai
    ports:
      - "8080:8080" # Caddy 统一代理端口 (同时包含 WebUI 和 WebDAV)
      - "6881:6881" # BT TCP
      - "6881:6881/udp" # BT UDP
    volumes:
      - ./data:/data

```

---

## 💡 访问与使用说明

部署成功并绑定域名后（假设您的域名是 `https://my-app.koyeb.app`）：

### 1. 访问 qBittorrent 面板

* **地址**：直接访问根域名 `https://my-app.koyeb.app`
* **初始账号**：您在 `QBT_USER` 中设置的值（默认 `admin`）
* **初始密码**：`adminadmin`

> **⚠️ 警告**：请在首次登录后，立即前往 **工具 (Tools) -> 选项 (Options) -> Web UI** 中修改密码！

### 2. 连接 WebDAV 服务拉取文件

WebDAV 服务挂载在 `/webdav` 路径下。请在本地电脑终端运行 `rclone config`，按以下参数配置：

* 新建远端类型 (Type)：`webdav`
* **URL 输入**：`https://my-app.koyeb.app/webdav` (**注意：必须带有 `/webdav` 后缀！**)
* Vendor 选择：`other`
* User 输入：您设置的 `WEBDAV_USER`
* Password 输入：您设置的 `WEBDAV_PASS`

#### Rclone 拉取命令示例：

配置完成后（假设远端命名为 `paas-webdav`）：

**将云端下载好的文件拉取到本地，并自动删除云端文件以释放 PaaS 空间：**

```bash
rclone move paas-webdav:/ /您的本地/下载路径/ --delete-empty-src-dirs --transfers 4 --progress

```

---

## 🛠️ GitHub Actions 自动化构建设置

Fork 或克隆此仓库后：

1. 前往 GitHub 仓库的 **Settings -> Secrets and variables -> Actions**。
2. 添加 `DOCKER_USERNAME`（您的 Docker Hub 账号）。
3. 添加 `DOCKER_PASSWORD`（您的 Docker Hub Access Token）。
4. 推送到 `main` 分支即可自动构建并发布。

---

*Powered by [qBittorrent-Enhanced-Edition](https://github.com/c0re100/qBittorrent-Enhanced-Edition), [Rclone](https://rclone.org/) & [Caddy*](https://caddyserver.com/)
