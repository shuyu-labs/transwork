# TransWork 演示环境 Docker 部署说明

## 1. 交付文件

将整个 `演示部署` 目录复制到服务器。目录中必须包含：

```text
演示部署/
├── docker-compose.yaml
├── docker-compose.sandbox.yaml   # 可选：开启命令执行时叠加
├── verify.sh                     # 部署自检
├── .env
└── 后台网站Docker部署操作手册.md
```

`.env` 已包含演示环境默认配置，必须与 `docker-compose.yaml` 放在同一目录。

## 2. 启动

> 目录里的 `.sh` / `.yaml` / `.env` 必须是 **LF** 换行。在 Windows 上用记事本或某些编辑器改过会变成 CRLF，
> Linux 上执行会报 `set: Illegal option -`。VS Code 右下角可切换为 LF；`verify.sh` 已做自愈，其他文件需手动保持。

进入 `演示部署` 目录执行：

```bash
cd 演示部署
docker-compose up -d
```

首次启动会自动拉取四个镜像并启动：

- Web：`3000`
- WebAgent：`4100`，镜像为 `registry.cn-hangzhou.aliyuncs.com/tree456/transwork-webagent:1.0.0`
- 文档解析服务：`5002`
- PostgreSQL：仅 Compose 内部访问

Web 容器会只读挂载宿主机的 `/etc/machine-id` 和
`/sys/class/dmi/id/product_uuid`，据此生成管理后台“组织管理 → 授权配置”中的
“系统识别码”。授权码必须使用这串识别码签发；如果识别码为空，请先确认宿主机
是 Linux 且上述两个文件存在，然后重建 Web 容器：

```bash
docker-compose up -d --force-recreate transwork-web
```

可用以下命令确认容器内已读到标识文件：

```bash
docker-compose exec transwork-web sh -c 'test -s /run/path2ai-host-machine-id && echo machine-id-ok'
docker-compose exec transwork-web sh -c 'test -s /run/path2ai-host-product-uuid && echo product-uuid-ok'
```

Web 容器名和 Compose 服务名均为 `transwork-web`。

查看状态：

```bash
docker-compose ps
```

## 3. 访问地址

- 网站首页：`http://localhost:3000/`
- 管理后台：`http://localhost:3000/admin`
- WebAgent：`http://localhost:4100/`
- 网站健康检查：`http://localhost:3000/healthz`
- WebAgent 健康检查：`http://localhost:4100/api/health`
- 文档解析服务：`http://localhost:5002`

远程访问时，将 `localhost` 替换为服务器 IP。需要修改端口或公网地址时，编辑 `.env` 后重新执行：

```bash
docker-compose up -d
```

### WebAgent 后台连接与转发

`.env` 中的 WebAgent 配置为：

```dotenv
WEBAGENT_HTTP_PORT=4100
PATH2AI_WEB_BASE_URL=http://transwork-web:3000
WEBAGENT_NODE_ENV=development
```

Compose 会将 `PATH2AI_WEB_BASE_URL` 注入 WebAgent 容器，覆盖镜像中默认的线上后台地址，无需重新构建镜像。
它是 **WebAgent 服务端连接后台的地址**，不是浏览器访问 WebAgent 的地址，也不是 WebAgent 前端的构建参数。

请求链路：

```text
浏览器 http://服务器IP:4100
  → transwork-webagent:4100
  → http://transwork-web:3000/api/... 或 /v1/chat/completions
  → 后台 API / 模型网关
```

`transwork-web` 是 Compose 内部 DNS 服务名，`3000` 是容器端口。
修改宿主机的 `PATH2AI_HTTP_PORT` 不影响此内部地址；不要填 `localhost`，
因为 WebAgent 容器里的 `localhost` 指向 WebAgent 自己。

如果需要经由已有 Web 站点反向代理访问后台，也可以将 `PATH2AI_WEB_BASE_URL`
改为该站点地址，例如 `https://web.example.com`（支持后台部署子路径）。
该地址必须从 WebAgent 容器内可达，并确保 `/api/` 和 `/v1/` 等后台接口转发到 Web 容器，
不能指向 WebAgent 自己。默认的内部直连无需额外反向代理或 CORS 配置。
WebAgent 不是挂载在 Web 后台子路径下，不能仅将该变量设为 `/webagent` 来实现同域子路径部署。

WebAgent 使用后台已激活并分配角色的普通用户账号登录，不是管理后台管理员账号。
后台需先完成授权及用户、角色、模型等配置。
会话、工作区、登录密钥等数据保存在独立 Docker 卷中；附件解析复用同一 `fileext` 服务。
WebAgent 会等 Web 容器健康后启动；它自己的 `/api/health` 只检查进程，并不验证后台授权或模型可用性。

### HTTP 演示与 HTTPS 部署

WebAgent 当前代码在 `NODE_ENV=production` 时为登录 Cookie 添加 `Secure`。
因此通过 `http://服务器IP:4100` 演示时，必须保留 `WEBAGENT_NODE_ENV=development`，
否则普通 HTTP 下浏览器无法正常保持登录态。
Compose 默认关闭 stdio MCP 和命令执行沙箱，不会因演示模式自动开放这些工具；
需要用命令执行生成文档时，按第 7 节显式打开。
HTTP 会明文传输账号及会话，仅适用于可信网络中的演示。

公网部署应在外部反向代理上配置独立的 WebAgent HTTPS 域名，并将其转发至宿主机的 `4100` 端口，
然后将 `WEBAGENT_NODE_ENV` 改为 `production`。
代理须保留浏览器原始 `Host`（否则写请求会被 WebAgent 的同源校验拒绝），
转发所有路径，并关闭 SSE 缓冲、适当延长流式连接超时；避免直接暴露 HTTP 端口。
此时 `PATH2AI_WEB_BASE_URL` 仍可保持内部地址 `http://transwork-web:3000`，
不需要改成 WebAgent 的 HTTPS 域名。

修改 `.env` 后运行 `docker-compose up -d` 重建受影响的容器，不能只执行 `docker-compose restart`。

## 4. 默认账号

后台管理员：

```text
账号：admin
密码：TransWork_Admin_2026
```

数据库账号：

```text
数据库：transwork
用户：transwork
密码：TransWork_DB_2026_Demo
```

以上密码仅适用于演示环境。

## 5. pgvector

Web 启动时会自动检查并注册 PostgreSQL `vector` 扩展，成功后才启动 Web 服务。

查看日志：

```bash
docker-compose logs -f transwork-web
docker-compose logs -f transwork-webagent
docker-compose logs -f postgres
docker-compose logs -f fileext
```

如果出现 `pgvector is not available`，请确认数据库镜像包含 pgvector 扩展。

## 6. 常用命令

```bash
# 停止服务，保留数据
docker-compose stop

# 启动已创建的服务
docker-compose start

# 重启 Web
docker-compose restart transwork-web

# 重启 WebAgent（仅重启，不加载新的环境变量）
docker-compose restart transwork-webagent

# 拉取新镜像并更新
docker-compose pull
docker-compose up -d

# 部署自检（容器状态、健康检查、命令执行配置）
sh verify.sh
```

不要执行以下命令，除非确认要删除数据库数据：

```bash
docker-compose down -v
```

## 7. 命令执行与文档生成（可选）

默认 `.env` 里 `WEBAGENT_SANDBOX=off`：**只能问答**。docx / xlsx 这类需要跑脚本的技能会失败，
表现为对话里出现提示「命令执行未启用」，或者数字员工说生成了、右栏却没有文件。

确认当前状态：

```bash
sh verify.sh
```

### 7.1 准备沙箱镜像

镜像已推送到 registry，演示环境直接拉：

```bash
docker pull registry.cn-hangzhou.aliyuncs.com/tree456/transwork-webagent-sandbox:1.0.0
```

`.env` 里保持：

```dotenv
WEBAGENT_SANDBOX_IMAGE=registry.cn-hangzhou.aliyuncs.com/tree456/transwork-webagent-sandbox:1.0.0
```

需要改镜像内容时再自己构建并推送（国内机器必须换源，否则会卡在 `deb.debian.org`，实测 0 B/s）：

```bash
cd /path/to/Path2AI-WebAgent
docker build \
  --build-arg DEBIAN_MIRROR=mirrors.cloud.tencent.com \
  --build-arg PIP_INDEX=https://mirrors.cloud.tencent.com/pypi/simple \
  --build-arg NPM_REGISTRY=https://mirrors.cloud.tencent.com/npm/ \
  -t registry.cn-hangzhou.aliyuncs.com/tree456/transwork-webagent-sandbox:1.0.0 server/sandbox
docker push registry.cn-hangzhou.aliyuncs.com/tree456/transwork-webagent-sandbox:1.0.0
```

镜像内已包含 python3、python-docx、openpyxl、python-pptx，以及预装的 `docx` npm 包。

### 7.2 查到 data 卷在宿主机上的真实路径

```bash
docker volume ls | grep webagent
docker volume inspect 演示部署_transwork-webagent-data -f '{{.Mountpoint}}'
```

卷名前缀是 Compose 项目名（通常是目录名），以 `docker volume ls` 的结果为准。

### 7.3 修改 .env

```dotenv
WEBAGENT_SANDBOX=docker
WEBAGENT_SANDBOX_HOST_DATA_DIR=/var/lib/docker/volumes/演示部署_transwork-webagent-data/_data
```

### 7.4 叠加沙箱配置启动

```bash
docker-compose -f docker-compose.yaml -f docker-compose.sandbox.yaml up -d transwork-webagent
```

这一步会把宿主机的 `/var/run/docker.sock` 交给 WebAgent，权限等同于 root，
**仅限单机演示**。对外服务请关闭命令执行或改用独立沙箱节点。

叠加文件会顺带把宿主机的 docker CLI 挂进容器。如果 `which docker` 不是 `/usr/bin/docker`，
把 `.env` 里的 `DOCKER_CLI_PATH` 改成实际路径，否则容器里 `docker` 命令会变成空目录。

另外容器以 uid 1000 运行，而 `/var/run/docker.sock` 是 `root:docker 660`，所以叠加文件里加了
`group_add` 把宿主 docker 组补进去。组 gid 用 `getent group docker | cut -d: -f3` 查，
填到 `.env` 的 `DOCKER_GID`（常见 988 / 999）。

### 7.5 验收

```bash
docker logs --tail 50 transwork-webagent | grep sandbox
```

看到 `[sandbox] docker 后端就绪` 才算成功。然后在对话里让数字员工生成一个 docx，
右栏「文件」应能看到产物。

### 7.6 回滚

`.env` 改回 `WEBAGENT_SANDBOX=off`，然后：

```bash
docker-compose up -d transwork-webagent
```

### 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 对话里提示「命令执行未启用」 | 沙箱关闭（默认配置） | 按 7.1–7.4 开启；只演示问答可忽略 |
| 开了 docker 仍不可用 | 没挂 socket / 容器里没有 docker CLI / 沙箱镜像不存在 | `sh verify.sh` 会逐项标出来 |
| 文件生成了但右栏看不到 | `WEBAGENT_SANDBOX_HOST_DATA_DIR` 为空或填错 | 按 7.2 重新取路径 |
| 日志里完全没有 `[sandbox]` 行 | 镜像较旧，不含沙箱代码 | 重新构建 `transwork-webagent` 镜像 |
| 改了 `.env` 没生效 | 只 restart 不会重新加载环境变量 | `docker-compose up -d transwork-webagent` |

## 8. 数据持久化

- `uploads/`：文档解析上传文件
- `static/`：文档解析静态文件
- Docker 卷 `transwork-data`：Web 运行数据
- Docker 卷 `transwork-webagent-data`：WebAgent 会话、工作区、缓存与登录密钥
- Docker 卷 `transwork-postgres-data`：PostgreSQL 数据

备份数据库：

```bash
docker-compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > transwork-backup.sql
```
