# XY 导航站

一个参考 [xydh.fun](https://xydh.fun/) 视觉风格实现的前后端分离导航站。前台提供搜索、分类和书签入口，后台用于维护当前主题实际使用的站点信息、背景、分类、书签与搜索引擎。

## 项目结构

```text
.
├── nav-frontend/       Vue 3 前端及其轻量 Nginx web 镜像
├── nav-backend/        Spring Boot 3 + Java 17 后端
├── database/           PostgreSQL 权威结构与迁移历史
├── ops/                应用镜像回滚脚本
├── docker-compose.yml  web 与 backend 编排（PostgreSQL、Redis 均使用外部服务）
└── .env.example        部署环境变量示例
```

## 本地开发

依赖：Node.js 20+、npm 10+、JDK 17 和 Maven 3.9+。默认 `local` profile 使用 PostgreSQL 兼容模式的内存 H2，直接开发不要求安装 PostgreSQL 或 Redis；数据会在后端进程退出后清空。`prod` profile 和 Docker 部署只连接部署者提供的外部 PostgreSQL 与外部 Redis。

1. 启动后端：

   ```bash
   cd nav-backend
   mvn spring-boot:run
   ```

2. 在另一个终端启动前端：

   ```bash
   cd nav-frontend
   npm ci
   npm run dev
   ```

开发地址以终端输出为准，通常为：

- 前端：`http://localhost:5173/`
- 后台登录：`http://localhost:5173/admin/login`
- 后端健康检查：`http://localhost:8080/api/health`
- Swagger UI：`http://localhost:8080/swagger-ui/index.html`
- Swagger 兼容入口：`http://localhost:8080/swagger-ui.html`
- OpenAPI JSON：`http://localhost:8080/v3/api-docs`
- H2 控制台：`http://localhost:8080/h2-console`（仅 `local` profile）

`local` profile 默认启用 Swagger/OpenAPI；`prod` profile 默认关闭，生产环境只有显式设置 `OPENAPI_ENABLED=true` 才会开放这些文档地址。

如需在本机按生产方式联调，请先提供外部 PostgreSQL 空白专用库和外部 Redis，再设置 `SPRING_PROFILES_ACTIVE=prod`、`CACHE_TYPE=redis`、Redis/JWT 参数以及 `NAV_DATABASE_SOURCE=UNCONFIGURED`。启动后通过网页安装向导提交外部数据库连接并初始化 schema；不需要手工执行根目录 SQL。

## Docker Compose 一键启动

### GitHub 自动构建镜像

仓库包含 `.github/workflows/publish-images.yml`。Pull Request 和普通分支只执行前后端测试、生产构建与依赖审计，不会登录镜像仓库或发布镜像。只有以下两种提交在全部门禁通过后发布到 GitHub Container Registry（GHCR）：

- 默认分支：`ghcr.io/<所有者>/<仓库>-web:latest` 和 `ghcr.io/<所有者>/<仓库>-backend:latest`。
- `v1.2.3` 形式的版本标签：生成 `1.2.3`、`1.2` 和对应完整提交的 `sha-<40位提交摘要>` 标签；默认分支也始终生成对应的完整 SHA 标签。

镜像路径中的所有者和仓库名会自动转换为小写，以兼容 GHCR 命名规则。两个镜像同时发布 `linux/amd64` 与 `linux/arm64` 清单，并附带 BuildKit provenance 和 SBOM。工作流中的第三方 Action 全部固定到完整提交 SHA；测试任务只有仓库只读权限，发布任务才临时取得 `packages: write`，使用仓库自动提供的 `GITHUB_TOKEN`，不需要添加数据库、Redis、管理员或安装密钥。两个 Docker 构建上下文分别限制在 `nav-frontend` 与 `nav-backend`，根目录的 `jiyi.md`、`jihua.md`、`.env` 和运行时凭据不会进入构建上下文；多阶段镜像最终层只包含前端静态运行文件或后端 JRE/JAR。

首次发布后，在 GitHub 仓库的 **Packages** 中确认两个包的可见性。公开项目建议把包设为 Public；私有包部署时应使用只授予 `read:packages` 的令牌登录 `ghcr.io`，不要在服务器上使用个人账号密码。部署时优先固定版本或完整 SHA 标签；`latest` 适合首次体验，但不适合作为可审计的生产版本锚点。

### 开源提交前检查

不要在 GitHub 网页中直接拖拽整个本地目录；网页上传不会执行 `.gitignore`，可能把私有的 `jiyi.md`、`.env` 或 `.codex*` 临时归档一并上传。应在本地使用 Git 初始化和提交，并在首次提交前核对：

```bash
git check-ignore jiyi.md .env
git status --ignored --short
git ls-files
```

`jiyi.md` 与 `.env` 必须显示为已忽略，`git ls-files` 不得出现凭据、证书、备份、构建产物或 `.codex*` 文件。Shell 脚本应通过本地 Git 保留可执行位；许可证可在正式公开前按项目选择另行加入。

1. 复制环境变量模板并修改其中所有密码和密钥：

   ```bash
   cp .env.example .env
   chmod 600 .env
   test "$(stat -c %a .env)" = 600
   ```

   Windows PowerShell 本地联调可执行：

   ```powershell
   Copy-Item .env.example .env
   ```

   正式 Linux 服务器必须在填写任何密钥前把 `.env` 设为 `0600`；Compose 本身不会阻止权限过宽的文件，镜像回滚脚本会直接拒绝权限过宽的环境文件。

   `REDIS_HOST`、`REDIS_PASSWORD` 和 `JWT_SECRET` 为启动必填项；留空或不创建 `.env` 时 Compose 会拒绝启动。新部署还必须把 `NAV_INSTALL_TOKEN` 设置为 64 位小写十六进制随机值（例如执行 `openssl rand -hex 32`），它只用于首次网页安装，不是管理员密码。外部 PostgreSQL 密码只在安装页中提交，不写入 `.env`。

2. 使用已经发布的镜像时，先在 `.env` 固定同一提交的 `BACKEND_IMAGE` 和 `WEB_IMAGE`：

   ```dotenv
   BACKEND_IMAGE=ghcr.io/<所有者>/<仓库>-backend:sha-<40位提交摘要>
   WEB_IMAGE=ghcr.io/<所有者>/<仓库>-web:sha-<40位提交摘要>
   ```

   再拉取并启动：

   ```bash
   docker compose pull
   docker compose up -d --no-build
   ```

   不应把尖括号原样写入配置；请在对应版本的 GitHub Packages 页面复制同一提交的两个真实镜像引用。使用私有包时，先用只具备 `read:packages` 的令牌执行 `docker login ghcr.io`。

   开发者需要从源码自行构建时才使用 `docker compose up -d --build`。

3. 查看状态与日志：

   ```bash
   docker compose ps
   docker compose logs -f backend web
   ```

默认 `APP_PORT=8080`，统一入口如下：

- 导航首页：`http://localhost:8080/`
- 首次安装：`http://localhost:8080/install`
- 管理后台：`http://localhost:8080/admin/login`
- API 健康检查：`http://localhost:8080/api/health`
- Swagger UI：`http://localhost:8080/swagger-ui/index.html`（仅 `OPENAPI_ENABLED=true`）
- Swagger 兼容入口：`http://localhost:8080/swagger-ui.html`（仅 `OPENAPI_ENABLED=true`）
- Knife4j（若后端启用）：`http://localhost:8080/doc.html`

Compose 不创建 PostgreSQL、Redis 容器或对应数据卷；两项服务都必须由部署者或云服务商预先提供。项目只保留 `xydh-nav_uploads_data`、`xydh-nav_backend_logs` 和 `xydh-nav_database_config` 三个显式命名卷，容器更新或重启不会清空上传文件、后端日志或安装向导保存的数据库连接配置。外部 Redis 的持久化、高可用与备份由服务提供方负责。

外部 Redis 默认启用 TLS，并使用 Java 运行环境的系统信任库完成证书及主机身份校验；使用私有 CA 时，应在自定义后端镜像或 JVM truststore 中安全加入该 CA。只有隔离且受信任的私网测试链路才可显式设置 `REDIS_SSL_ENABLED=false`，不要以关闭 TLS 代替正确的证书配置。

### 从旧四容器拓扑升级

旧版本由 `nginx`、`frontend`、`backend`、`redis` 四个项目容器组成。升级前先完成数据库、上传文件与环境配置备份，完整保留一份可执行的旧发行目录（至少包含旧 `docker-compose.yml` 与旧 `.env`），记录旧镜像 ID 并给它们添加不可变回滚标签，再在新 `.env` 中配置已经验收的外部 Redis、`BACKEND_IMAGE` 与 `WEB_IMAGE`。先用新 Compose 精确重建 `backend`，确认它已通过外部 Redis 完成健康检查；这一步会替换旧后端容器，但旧 `nginx` 与 `frontend` 可暂时保留作为入口回滚锚点。

旧 `xydh-nav-nginx-1` 会占用 `APP_PORT`，不能与新 `web` 同时运行。核对容器名称和 Compose 标签后，先精确停止旧 `xydh-nav-nginx-1`，再启动 `web`。确认首页、后台、API、上传资源与数据库摘要全部正常后，才精确停止并删除旧 `xydh-nav-nginx-1`、`xydh-nav-frontend-1` 和 `xydh-nav-redis-1`。保留旧 Redis 数据卷和旧镜像作为观察期内的回滚锚点。

此迁移会重建 `backend` 并改用外部 Redis，但不会删除或替换 `uploads_data`、`backend_logs`、`database_config`，也不修改外部 PostgreSQL。不要使用 `docker compose down -v`、`docker volume prune`、`docker system prune` 或 `--remove-orphans` 代替精确停用；这些宽泛操作可能删除仍需保留的数据或无关容器。首次拓扑切换不能直接使用只面向新两容器版本的通用回滚脚本，失败时应恢复旧 `.env` 与已标记镜像，再按旧 Compose 精确拉起原容器。

`web` 内的 Nginx 会在启动时解析 `backend` 容器地址。日常发布或回滚后端时应同时重建 `web`，例如 `docker compose up -d --no-build --force-recreate backend web`，不要只替换后端后长期保留旧 web 容器。

### 配合 1Panel OpenResty

`web` 镜像已经包含轻量 Nginx，用于提供前端静态文件、代理 `/api`、读取上传卷和执行应用级限流；1Panel OpenResty 不替代这个内部服务器，只负责域名、HTTPS 和最外层反向代理。因此 Docker 中仍只有 `web` 与 `backend` 两个项目容器，不再单独运行入口 Nginx 容器。

直接通过 `APP_PORT` 访问时保持 `APP_BIND_ADDRESS=0.0.0.0`、`WEB_TRUST_PROXY_HEADERS=false`，此时客户端伪造的转发头不会被信任。接入 1Panel OpenResty 时按以下边界配置：

1. OpenResty 反向代理到宿主机的明确 loopback/私网地址与 `APP_PORT`，并显式覆写 `Host`、`X-Real-IP`、`X-Forwarded-For`、`X-Forwarded-Proto`；公网入口只开放 HTTPS。
2. 把 `APP_BIND_ADDRESS` 改为该明确的 loopback/私网地址，并用宿主机防火墙或隔离网络限制 `APP_PORT`，禁止普通客户端绕过 OpenResty 直连。若 OpenResty 运行在容器中，宿主机 `127.0.0.1` 通常不可从该容器访问，应使用受保护的宿主机私网地址或专用容器网络。
3. 先保持 `WEB_TRUST_PROXY_HEADERS=false` 发起一次代理请求，从 `docker compose logs web` 确认 web 容器实际看到的即时代理源地址；再设置 `WEB_TRUST_PROXY_HEADERS=true`，并把 `WEB_TRUSTED_PROXY_CIDR` 设为该地址的 `/32`（IPv6 用 `/128`）或最窄的隔离代理网段。
4. 执行 `docker compose up -d --no-deps --force-recreate web`，再确认 HTTPS 安装页、登录限流和访问日志中的客户端地址正确。

安全校验会拒绝“信任代理头 + `0.0.0.0`/`::` 泛监听”，也拒绝信任 `0.0.0.0/0` 或 `::/0`。不要为了省事扩大可信网段；只有来自所配即时代理地址的协议和客户端 IP 头才应进入后端。

## 首次部署安装向导

新部署把 `NAV_DATABASE_SOURCE` 设为 `UNCONFIGURED` 后，访问首页、后台或 `/install` 会进入首次部署向导。本发行编排和安装页只支持外部 PostgreSQL：请在数据库步骤填写主机、端口、数据库名、业务用户名、密码和 TLS 模式。Compose 不创建 `postgres` 服务。

部署者必须预先创建一个空白、专用的 PostgreSQL 14+ 数据库和非 superuser 业务用户，并授予连接及在 `public` schema 创建表、索引、序列、函数、触发器和迁移登记所需的 DDL 权限。页面不接受原始 JDBC URL，也不会创建 PostgreSQL 服务器、数据库或角色。向导会先只读测试连接；目标含未知对象、残缺项目结构、旧版未迁移结构或已安装管理员时均零写入拒绝。空库只有在用户明确确认后才执行权威 PostgreSQL schema 初始化。

安装页先验证 `NAV_INSTALL_TOKEN`，再进入“口令 → 数据库 → 环境 → 站点 → 账号 → 确认”六步流程。数据库测试成功只返回 5 分钟有效、单次使用且仅保存在当前页面内存中的随机 ticket；数据库密码和 CA 原文会立即从页面状态清除。配置成功后，后端把连接信息写入仅后端挂载的 `database_config` 卷（目录/文件限制为所有者可读写），自动重启并从该配置接管连接；密码不会进入 URL、浏览器存储或应用日志。外部 TLS 默认 `VERIFY_FULL`，也可选择 `VERIFY_CA`；`REQUIRE` 不校验证书和主机名，必须显式确认风险，外部模式不允许关闭 TLS。

数据库接管后才执行站点单例、上传目录和外部 Redis 检查，然后创建站点信息与唯一首位管理员。匿名状态接口不会探测外部资源或公开组件细节。Redis 不可达时环境检查失败，不允许完成安装；安装完成后的健康检查也会失败关闭。安装口令只从权限为 `0600` 的 `.env` 传入，后端不会生成、回传或打印明文口令。当前 Compose 通过容器环境变量传递口令，拥有 Docker 管理权限的用户可查看容器配置；因此该权限等同于 root 权限。安装完成后应从 `.env` 删除口令、设置 `NAV_WEB_INSTALL_ENABLED=false`，并执行 `docker compose up -d --no-build --force-recreate backend web` 同步重建两个容器。

安装提交受到 web 容器内置 Nginx 的每来源 IP 限流。服务端会在同一事务中再次锁定并检查安装状态，只有用户表为空且安装标记未完成时才能写入；成功后入口永久关闭，不会签发自动登录令牌，需使用刚创建的账号在 `/admin/login` 登录。即使之后误删全部用户，安装标记也不会自动重开。已有管理员的升级部署会在数据库迁移时回填完成标记，不修改管理员、密码或站点业务数据。

默认示例入口是 HTTP，只适合受信任的本机或局域网首次安装。数据库密码、安装口令和管理员密码在公网 HTTP 中可能被旁路读取，因此外部数据库配置默认要求 HTTPS；仅在受信任局域网临时设置 `NAV_ALLOW_INSECURE_DATABASE_SETUP=true` 才允许 HTTP 提交。公网应按上节配置 1Panel OpenResty 和受限代理头信任；未显式启用时，web 容器会忽略客户端传入的 HTTPS 协议头，不能把“外层已经有证书”误当成后端已经安全识别 HTTPS。

通过安装向导完成的站点升级时继续保持 `NAV_DATABASE_SOURCE=UNCONFIGURED`，并原样保留 `database_config` 卷。数据库连接文件、配置标记、完成标记或已有实例身份任一存在时，数据库断线只会进入故障状态，不会重新开放换库入口。旧版依赖 `DB_URL`/`DB_USERNAME`/`DB_PASSWORD` 与 `LEGACY_ENV` 的直连部署不能直接套用本编排升级，应先在独立环境完成数据迁移和恢复演练。

`database_config` 是安装状态与数据库实例身份的一部分，不是可丢弃缓存。它保存明文数据库连接凭据、可选 CA 和实例身份；整个卷丢失后项目没有受支持的“重新关联既有外部库”流程，也不能把重新运行安装向导当作恢复方式。该卷必须独立加密、异机备份，恢复后保持目录 `0700`、文件 `0600`。安装完成并确认登录成功后，应立即清空安装口令、关闭网页安装，并禁止对该卷执行 `down -v`、`volume rm` 或 `volume prune`。

需要无人值守部署时仍可使用传统引导：设置 `NAV_BOOTSTRAP_ENABLED=true`、`ADMIN_USERNAME` 和满足强密码规则的 `ADMIN_PASSWORD`。环境变量引导成功后同样关闭网页安装入口；`ADMIN_PASSWORD` 不会在后台改密时回写。默认 `local` profile 的开发账号仍为 `admin / Local!Start2026`。生产默认 `NAV_DEMO_DATA_ENABLED=false`，不会因某张业务表为空而重新补写演示业务数据。

## 账号安全

登录后可在后台“账号安全”（`/admin/account`）查看当前账户、修改密码或退出全部会话。新密码必须满足以下规则：

- 12–72 个字符，且 UTF-8 编码后不超过 BCrypt 的 72 字节上限。
- 不含空格或其他空白字符。
- 大写字母、小写字母、数字、符号四类中至少包含三类。
- 不包含管理员用户名，且不能与当前密码相同。

修改密码时必须提供当前密码和一致的新密码确认。改密成功后，密码使用 BCrypt 保存，并使当前设备及其他设备上此前签发的全部 JWT 立即失效；请使用新密码重新登录。“退出全部会话”不会修改密码，但也会撤销所有现有 JWT。普通“退出”只清理当前浏览器保存的令牌。

相关管理接口均需要管理员 JWT：

- `PUT /api/admin/auth/password`：修改当前管理员密码并撤销旧会话。
- `POST /api/admin/auth/logout-all`：保留密码并撤销当前管理员的全部旧会话。
- `POST /api/admin/auth/logout`：客户端无状态退出。

## 主要环境变量

| 变量 | 用途 | 示例默认值 |
|---|---|---|
| `APP_PORT` | web 容器映射到宿主机的端口 | `8080` |
| `APP_BIND_ADDRESS` | web 端口绑定地址；信任代理头时必须是明确的 loopback/私网地址 | `0.0.0.0` |
| `WEB_TRUST_PROXY_HEADERS` | 是否接受所配即时代理提供的客户端 IP 与原始协议头 | `false` |
| `WEB_TRUSTED_PROXY_CIDR` | 唯一可信即时代理地址或最窄隔离网段；禁止全网段 | `127.0.0.1/32` |
| `TZ` | 容器时区 | `Asia/Hong_Kong` |
| `UPLOADS_VOLUME_NAME` | 当前上传文件卷 | `xydh-nav_uploads_data` |
| `LOGS_VOLUME_NAME` | 当前后端日志卷 | `xydh-nav_backend_logs` |
| `DATABASE_CONFIG_VOLUME_NAME` | 安装向导持久化数据库连接与实例标记的后端专用卷 | `xydh-nav_database_config` |
| `BACKEND_IMAGE` / `WEB_IMAGE` | 可固定或回滚的后端/web 应用镜像引用 | `xydh-nav-*:latest` |
| `REDIS_HOST` | 外部 Redis 主机 | 必填 |
| `REDIS_PORT` | 外部 Redis 端口 | `6379` |
| `REDIS_USERNAME` | Redis ACL 用户名 | 可选 |
| `REDIS_PASSWORD` | 外部 Redis 密码，不写入 URL 或日志 | 必填 |
| `REDIS_DATABASE` | Redis 逻辑库编号 | `0` |
| `REDIS_SSL_ENABLED` | 是否使用 TLS；仅受信任私网测试可显式关闭 | `true` |
| `REDIS_CONNECT_TIMEOUT` | Redis 建连超时（大于 0 且不超过 60 秒） | `3s` |
| `REDIS_READ_TIMEOUT` | Redis 读写超时（大于 0 且不超过 60 秒） | `3s` |
| `JWT_SECRET` | JWT 签名密钥 | 至少 32 字节随机值 |
| `JWT_EXPIRATION_MINUTES` | 登录令牌有效期（分钟，允许 5–10080） | `120` |
| `OPENAPI_ENABLED` | 生产环境是否开放 Swagger/OpenAPI | `false` |
| `CORS_ALLOWED_ORIGINS` | 允许跨域的来源列表 | 按实际域名修改 |
| `NAV_BOOTSTRAP_ENABLED` | 是否使用环境变量自动创建首位管理员 | `false` |
| `NAV_DEMO_DATA_ENABLED` | 是否由后端补写演示业务数据；生产应关闭 | `false` |
| `NAV_WEB_INSTALL_ENABLED` | 是否允许未初始化的新库使用网页安装向导 | `true` |
| `NAV_INSTALL_TOKEN` | 首次网页安装的一次性口令；必须是 64 位小写十六进制随机值 | 新部署必填 |
| `NAV_DATABASE_SOURCE` | 数据库来源；外部数据库安装向导部署保持 `UNCONFIGURED` | `UNCONFIGURED` |
| `NAV_ALLOW_INSECURE_DATABASE_SETUP` | 是否允许通过 HTTP 提交数据库凭据；仅可信局域网临时开启 | `false` |
| `NAV_DATABASE_TICKET_TTL_SECONDS` | 数据库连接测试 ticket 有效期（服务端限制 30–900 秒） | `300` |
| `NAV_DATABASE_AUTO_RESTART` | 保存数据库配置后是否让容器自动重启接管 | `true` |
| `ADMIN_USERNAME` | 传统环境变量引导的管理员用户名 | `admin` |
| `ADMIN_PASSWORD` | 传统环境变量引导的管理员密码 | 仅启用传统引导时必填 |
| `VITE_API_BASE_URL` | 前端构建时 API 根路径 | `/api` |
| `APP_UPLOAD_MAX_BYTES` | 后台背景图单文件大小上限（字节，允许 1–10485760） | `10485760`（10MiB） |
| `APP_UPLOAD_MAX_TOTAL_BYTES` | 受管背景图片总容量上限（字节） | `1073741824`（1GB） |
| `APP_UPLOAD_MAX_FILES` | 受管背景图片数量上限 | `500` |
| `APP_UPLOAD_ORPHAN_GRACE_MS` | 未被配置引用图片的保留宽限期 | `86400000`（24小时） |
| `APP_UPLOAD_CLEANUP_INTERVAL_MS` | 孤儿图片定时清理间隔 | `21600000`（6小时） |
| `APP_UPLOAD_CLEANUP_INITIAL_DELAY_MS` | 启动后首次清理延迟 | `60000`（1分钟） |
| `JAVA_OPTS` | JVM 运行参数 | 见 `.env.example` |

## 背景设置

后台“站点配置”支持纯色和图片两种背景模式：

- 纯色模式提供纯黑、纯白快捷选项，也可自行选择背景色与字体色。
- 图片模式可分别上传 PC 端和移动端 JPG、JPEG 或 PNG 图片；移动端留空时自动沿用 PC 端图片。
- 上传图片保存在 `uploads_data` 命名卷，容器重建不会丢失；默认限制为单张 10MiB、总量 1GB、最多 500 张。虽然数据包导入的 multipart 入口允许更大请求，背景图片服务仍独立强制 `APP_UPLOAD_MAX_BYTES` 为 1–10485760 字节。
- 单文件上限同时编译进 web 镜像的前端上传提示，并传给后端运行配置；修改 `APP_UPLOAD_MAX_BYTES` 后必须同时重新构建 web 与 backend，不能只重启容器。
- 系统只管理自身生成的 `/uploads/backgrounds/{32位小写十六进制}.{jpg|png}` 文件。当前 PC/移动端配置引用始终受保护；未被任何站点配置引用的文件保留 24 小时后才可回收。
- 孤儿清理默认在启动 1 分钟后执行，此后每 6 小时执行一次，上传新图前也会先清理；读取配置引用失败时整次清理会跳过，不会冒险删除文件。
- 公开首页的公告、标题、简介、搜索、分类、书签和页脚统一使用当前字体色的完整不透明值，不再派生灰色文字层级；字体色设为纯黑时全页文字均为纯黑。
- 当前公开主题不展示推荐书签圆形入口和分类锚点快捷按钮，搜索框后直接进入分类卡片区域。
- 发布地址、背景特效、背景音乐和推荐书签属于兼容字段，当前主题不会消费，内置后台也不再展示对应的无效控件；接口与历史数据继续保留。

## 可靠性与故障处理

- 站点配置使用 `version` 做乐观并发控制。管理端 `PUT /api/admin/site-config` 必须携带本次读取到的 `expectedVersion`；保存成功版本加 1，旧页面继续保存会返回 `409`，不会覆盖较新的配置。
- 后台站点配置只有完整读取服务端数据后才允许编辑和保存；加载失败时表单保持锁定。页面会跟踪整份配置的未保存状态，刷新浏览器、重新加载或离开路由前都会提示，上传中的背景图同样阻止离开。
- 管理会话只有在受保护接口明确返回 `401/403` 时才清除。网络中断和 `5xx` 会保留本地令牌与最近一次用户资料；资料请求会合并并发调用，已有缓存资料时以 30 秒新鲜度窗口避免故障期间反复请求。
- 总览页的分类、书签和站点状态独立加载；单个接口失败不会清空其他已成功数据，可只重试失败项。“公开展示”只统计同时位于可见分类内且自身可见的书签。
- 公开首页首次无法取得服务端数据时会明确提示正在展示内置示例并提供重试；已有真实数据不会被后续短暂故障覆盖。站点名称、简介和背景色会同步更新页面标题、描述与 `theme-color` 元信息。

## 搜索引擎管理

后台“搜索引擎”页面支持新增、编辑、删除、排序、启用/停用以及设置默认引擎。搜索地址必须是完整的 HTTP(S) 地址，可以使用 `{keyword}` 作为关键词占位符；占位符不能出现在主机名或 URL 片段中，并且不支持其他占位符。未填写 `{keyword}` 时，前端会自动追加 `q` 查询参数。

公开首页点击搜索框左侧的当前引擎图标，会在搜索框下方展开毛玻璃网格选择面板；面板按后台公开排序展示全部可用引擎和当前选中项，选择后立即更新图标与占位文字并回到搜索输入框。点击面板外部或按 `Esc` 可收起，桌面端使用四列、移动端使用两列，选项较多时在面板内部滚动。

系统保证有数据时只存在一个启用的默认引擎：第一条引擎会自动成为默认项；停用或删除当前默认项时会按排序选择下一条已启用引擎。最后一条引擎不能删除，仅剩的已启用默认引擎也不能直接停用。

公开接口无需登录：

- `GET /api/public/search-engines`：获取已启用的搜索引擎。

以下管理接口需要管理员 JWT：

- `GET /api/admin/search-engines`：获取全部搜索引擎。
- `POST /api/admin/search-engines`：新增搜索引擎。
- `PUT /api/admin/search-engines/{id}`：编辑搜索引擎。
- `DELETE /api/admin/search-engines/{id}`：删除搜索引擎。
- `PUT /api/admin/search-engines/{id}/default`：设为默认并自动启用。
- `PUT /api/admin/search-engines/{id}/visible`：启用或停用。
- `PUT /api/admin/search-engines/sort`：批量更新排序。

## 分类与书签管理

后台“分类管理”支持新增、编辑、显隐、删除和全量排序；排序弹窗可使用上移/下移按钮，也可聚焦条目后按 `Alt + ↑/↓`。仍含书签的分类不能删除，页面会显示实际书签数量并提示先到书签管理中移动或删除关联书签。

后台“书签管理”支持按分类与关键词筛选、桌面表格多选、移动端卡片选择、分类内完整排序和跨分类批量移动：

- 只有明确选择一个分类后才能排序，排序始终包含该分类的全部书签（包括隐藏书签），不会被关键词筛选裁掉。
- 多选状态可跨筛选保留，并显示不在当前筛选中的已选数量；可随时“清空全部”。
- 批量移动只迁移尚未位于目标分类的书签，混合选择中的原目标书签保持原位；成功后重新加载书签和分类计数，失败时保留当前选择。
- 分类和书签图标可留空、填写 1–3 字短标记/Emoji，或填写显式完整的 HTTP(S) 图片 URL。
- 720px 及以下使用移动端管理卡片，排序、选择、显隐、编辑和删除无需横向滚动表格。

相关管理接口均需要管理员 JWT：

- `PUT /api/admin/categories/sort`：批量更新分类排序。
- `PUT /api/admin/bookmarks/sort`：批量更新书签排序。
- `PUT /api/admin/bookmarks/batch-move`：将 `ids` 中尚未属于 `categoryId` 的书签按请求顺序追加到目标分类末尾。

三类批量请求均先完整校验后写入，任一 ID 非法、重复或不存在时整批不生效。排序请求单次最多 1000 项；批量移动为可安全重试的幂等操作，响应只包含本次请求的书签，内置前端会在成功后重新获取完整列表。

## 后台移动端体验

- 901px 及以上保留可折叠的固定侧栏；900px 及以下切换为带遮罩的侧滑菜单，不占用内容宽度。
- 移动菜单支持点击遮罩、选择菜单项或按 `Esc` 关闭；打开时锁定页面滚动并将键盘焦点限制在菜单内，关闭后焦点返回菜单按钮。
- 720px 及以下的管理列表使用移动卡片，筛选、排序、显隐、编辑、删除和批量操作不依赖横向滚动表格。
- 移动端表单、按钮、菜单项和主要操作区域的触控高度不小于 44px；弹窗在短屏内独立滚动，底部操作始终可达。
- 除按原设计保持紧凑比例的左侧品牌与导航栏外，自定义可见文字不使用低于 12px 的固定字号；后台右侧正文、表格、表单和按钮以约 14–16px 为基准，并同步放大 Element Plus 控件高度，避免文字被裁切。
- 页面按 320px 最小视口宽度适配，登录、总览、站点配置、搜索引擎、分类、书签和账号安全页面均避免产生整页横向滚动。

## 自定义链接兼容接口

自定义链接作为后端兼容能力保留，位置只接受 `header` 与 `footer`。当前公开首页主题不渲染头部或底部自定义链接，内置后台也不再提供管理入口；已有数据不会被删除，API 仍可供其他前端主题或外部集成使用。公开列表固定先返回头部链接，再返回底部链接，各组按 `sortOrder`、`id` 排序。

链接地址允许带有效主机名且不含用户信息的 HTTP(S) 地址、单斜杠开头的站内路径，以及非空 `#` 锚点。系统会拒绝危险协议、协议相对地址、反斜杠及包含空白或控制字符的地址。

公开接口无需登录：

- `GET /api/public/custom-links`：获取合法且已启用的头部/底部链接。

以下管理接口需要管理员 JWT：

- `GET /api/admin/custom-links`：获取全部自定义链接。
- `POST /api/admin/custom-links`：新增自定义链接。
- `PUT /api/admin/custom-links/{id}`：编辑自定义链接。
- `DELETE /api/admin/custom-links/{id}`：删除自定义链接。
- `PUT /api/admin/custom-links/{id}/visible`：启用或停用。
- `PUT /api/admin/custom-links/sort`：批量更新排序。

## 数据管理与可移植备份

后台“数据管理”提供与数据库引擎无关的版本化 ZIP 数据包：

- “导出当前数据”包含站点配置、分类、书签、搜索引擎、兼容自定义链接，以及当前 PC/移动端配置实际引用的受管背景图。
- 管理员账号、密码哈希、会话版本、JWT/Redis/数据库密钥、环境变量和日志永远不会进入可移植数据包。
- 导入必须先上传并做零写入预检。服务端校验 ZIP 路径、条目数、压缩/展开大小、JSON 严格结构、SHA-256、图片签名、业务约束和引用完整性，再显示新增、更新、删除与不变数量。
- 通过预检后还需确认已备份并输入确认短语。预检令牌绑定当前管理员、数据包摘要和当前业务版本，15 分钟过期；预检后业务数据发生变化时返回 `409`，必须重新预检。
- 正式导入只替换上述业务数据，不修改管理员账号。数据库写入和导入后内容验证位于同一事务；失败会回滚数据库，并清理本次新建的背景资产。任务执行后不提供会误导用户的“取消”。
- 导入任务状态只保留在当前后端进程内；进程重启后管理端会明确提示“无法确认结果”，不会误报成功或已回滚，此时应先核对当前数据再决定是否重试。
- 格式 v1 的分类、书签、搜索引擎和兼容链接稳定 key 由导出时数据库 ID 生成；全量导入会创建新的数据库 ID。因此同一旧包在成功导入后再次预检时，部分项目可能显示为新增/删除，而不是不变。内容和关联恢复不受影响，确认时应以资源计数与具体预检内容为准。

同一页面还提供独立的“书签 Markdown 备份”：

- 按分类和后台排序导出全部分类与书签，包括隐藏项、空分类、链接、描述、图标文本、显示状态、推荐状态及打开方式。
- 生成后可直接预览、复制或下载 UTF-8 `.md` 文件；局域网 HTTP 环境下会自动尝试兼容复制，失败时选中预览内容供手动复制。
- Markdown 面向人工阅读、笔记归档和代码仓库留存，不包含管理员、数据库 ID 或内部时间戳，也不能用于系统恢复；需要恢复时仍应使用 ZIP 数据包。
- Markdown 保存完整 URL，链接可能包含私有查询参数。下载文件应妥善保管，不要未经检查提交到公开仓库。

管理接口均要求管理员 JWT：

- `GET /api/admin/data/export`：下载 ZIP 数据包。
- `GET /api/admin/data/bookmarks/markdown`：下载人类可读的 Markdown 书签副本。
- `POST /api/admin/data/import/preview`：上传并预检 ZIP，文件上限 64MiB。
- `POST /api/admin/data/import/{previewToken}/confirm`：确认并创建异步导入任务。
- `GET /api/admin/data/import/jobs/{jobId}`：查询当前管理员创建的任务。

可移植 ZIP 适合站点内容迁移和管理员自助恢复，但不替代灾难恢复备份。整站恢复还必须保存数据库服务商生成且验证过的 PostgreSQL 备份、上传卷、源码或发行清单、镜像引用、加密后的环境配置，以及独立加密保存的 `database_config` 卷。

## Web 容器的 Nginx 路由

- `/`：直接提供构建进 web 镜像的前端静态文件。
- `/api`：转发到后端容器并保留原始路径。
- `POST /api/admin/auth/login`：按来源 IP 限制为平均每分钟 5 次、允许 5 次突发；超限返回统一 JSON 格式的 `429`。
- `POST /api/install/database/test` 与 `POST /api/install/database/configure`：共享平均每分钟 3 次、允许 3 次突发的数据库配置预算；`POST /api/install/check` 与 `POST /api/install/complete` 使用另一组同额度预算，避免一次合法六步安装流程消耗掉自己的完成额度。数据库凭据端点不写访问日志且请求体只在内存缓冲，匿名状态查询另限为每分钟 30 次。
- `POST /api/admin/data/import/preview`：独立允许 66MiB 请求体并使用 120 秒上游读取超时，应用层仍严格限制 ZIP 为 64MiB。
- 默认限流键使用 web Nginx 直接看到的连接地址。只有同时启用 `WEB_TRUST_PROXY_HEADERS=true`、收窄 `APP_BIND_ADDRESS` 并匹配 `WEB_TRUSTED_PROXY_CIDR` 时，才恢复可信代理转发的真实客户端地址与原始协议；否则会安全回退到直接连接地址和 web 自身协议。错误地关闭恢复会使所有访客共用代理地址的限流额度，错误地扩大信任则会允许伪造来源。
- `/uploads/`：从持久化上传卷直接提供静态文件。
- `/swagger-ui/`、`/v3/api-docs`、`/doc.html`：转发到后端接口文档；生产默认由后端关闭。
- `/healthz`：Nginx 自身健康检查。

## PostgreSQL 初始化、迁移与灾难恢复

`nav-backend/src/main/resources/schema-postgresql.sql` 是唯一权威初始化资源，会打包进后端，并由安装向导初始化用户明确确认的空白外部数据库。`database/migrations/` 保存已经登记的不可修改迁移历史及 SHA-256，不能改写已发布文件。

当前发行版不提供对外部 PostgreSQL 自动执行升级迁移的脚本。升级前必须阅读对应版本发布说明；若新版本含数据库迁移，应先在服务商创建并验证可恢复快照，再按该版本提供的受控步骤升级数据库并校验实例 UUID，最后才更新应用镜像。没有明确迁移说明时，不要把历史迁移目录整体重复执行到现有数据库。其他数据库的旧结构和一次性转换脚本已从仓库移除，非 PostgreSQL 站点不能直接使用当前发行包升级。

外部数据库整站保护至少包括：数据库服务商的加密备份与恢复演练、后台可移植 ZIP、上传卷、加密后的 `.env`、镜像版本，以及单独加密保存的 `database_config` 卷。该卷包含明文连接凭据、可选 CA 和实例身份标记；仅有数据库快照和上传文件仍不足以恢复应用连接。当前项目没有在该卷丢失后重新关联既有外部数据库的受支持流程，恢复配置卷时必须保持目录 `0700`、文件 `0600`。

`ops/rollback-release.sh <后端镜像> <web镜像>` 仅切换已经拉取到本机的应用镜像，不修改数据库、`database_config` 或上传卷。执行前必须同时提供 `CONFIRM_ROLLBACK=ROLLBACK-RELEASE` 和 `CONFIRM_EXTERNAL_DATABASE_BACKUP=EXTERNAL-DATABASE-BACKUP-VERIFIED`；代码回滚不能代替数据库回滚，也不能保证新 schema 与旧应用兼容。

绝不要对需要保留的环境执行 `docker compose down -v`、`docker volume prune` 或带 `--remove-orphans` 的切换命令。备份至少应再复制一份到异机/对象存储并定期执行恢复演练；只存在同一虚拟机上的备份不能覆盖宿主机磁盘故障。

## 安全提醒

- 上线前务必为外部数据库创建专用最小权限账号，并更换数据库、Redis、管理员密码以及 `JWT_SECRET`，不要提交 `.env` 或 `database_config` 的任何副本。
- 管理员密码应遵守账号安全页的强度规则并定期更新；轮换 `JWT_SECRET` 会使所有现有 JWT 失效。
- 生产环境必须使用 HTTPS；使用 1Panel OpenResty 等外层代理时，必须同时限制 web 入口、防止绕过，并只信任实际即时代理地址。跨域来源还应按实际域名限制。
- 定期轮换密钥、备份数据库和上传文件，并及时更新基础镜像。
- Swagger/OpenAPI 在生产 profile 默认关闭；只应在受控网络中临时设置 `OPENAPI_ENABLED=true`，使用完立即关闭。
- 背景图片接口同时校验 MIME、文件魔数、图像格式、尺寸和文件大小；普通 `/api/` 请求体上限为 12MiB，图片业务层最高接受 10MiB。只有数据包预检精确入口允许 66MiB multipart 请求，ZIP 解析器仍限制归档和总展开量为 64MiB、单条目为 16MiB。
