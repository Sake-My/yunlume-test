# XY 导航站

一个参考 [xydh.fun](https://xydh.fun/) 视觉风格实现的前后端分离导航站。前台提供搜索、分类和书签入口，后台用于维护当前主题实际使用的站点信息、背景、分类、书签与搜索引擎。

## 项目结构

```text
.
├── nav-frontend/       Vue 3 + Vite + TypeScript 前端
├── nav-backend/        Spring Boot 3 + Java 17 后端
├── database/           PostgreSQL 权威结构、迁移与旧 MySQL 参考
├── nginx/nginx.conf    统一入口与反向代理
├── ops/                备份、校验、迁移、恢复演练与回滚脚本
├── docker-compose.yml  PostgreSQL、Redis、前后端和 Nginx 编排
└── .env.example        部署环境变量示例
```

## 本地开发

依赖：Node.js 20+、npm 10+、JDK 17 和 Maven 3.9+。默认 `local` profile 使用 PostgreSQL 兼容模式的内存 H2，直接开发不要求安装 PostgreSQL 或 Redis；数据会在后端进程退出后清空。`prod` profile 和 Docker 部署使用 PostgreSQL 17 + Redis 7。

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

如需在本机按生产方式联调，请先启动 PostgreSQL/Redis，对空库执行 `database/init.sql`，再设置 `SPRING_PROFILES_ACTIVE=prod`、`CACHE_TYPE=redis`，以及 `DB_URL`、`DB_USERNAME`、`DB_PASSWORD`、`REDIS_HOST`、`REDIS_PORT`、`REDIS_PASSWORD`、`JWT_SECRET` 后启动后端。新库默认通过网页安装向导创建首位管理员；如需沿用环境变量引导，再额外配置 `NAV_BOOTSTRAP_ENABLED=true` 与 `ADMIN_PASSWORD`。

## Docker Compose 一键启动

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

   正式 Linux 服务器必须在填写任何密钥前把 `.env` 设为 `0600`；Compose 本身不会阻止权限过宽的文件，而项目的备份、迁移和恢复脚本会直接拒绝它。

   `POSTGRES_PASSWORD`、`REDIS_PASSWORD` 和 `JWT_SECRET` 为启动必填项；留空或不创建 `.env` 时 Compose 会拒绝启动。新部署还必须把 `NAV_INSTALL_TOKEN` 设置为 64 位小写十六进制随机值（例如执行 `openssl rand -hex 32`），它只用于首次网页安装，不是管理员密码。空值或弱值会让新库保持“尚未就绪”，不会自动生成或写入日志。

2. 构建并启动：

   ```bash
   docker compose up -d --build
   ```

3. 查看状态与日志：

   ```bash
   docker compose ps
   docker compose logs -f backend nginx
   ```

默认 `APP_PORT=8080`，统一入口如下：

- 导航首页：`http://localhost:8080/`
- 首次安装：`http://localhost:8080/install`
- 管理后台：`http://localhost:8080/admin/login`
- API 健康检查：`http://localhost:8080/api/health`
- Swagger UI：`http://localhost:8080/swagger-ui/index.html`（仅 `OPENAPI_ENABLED=true`）
- Swagger 兼容入口：`http://localhost:8080/swagger-ui.html`（仅 `OPENAPI_ENABLED=true`）
- Knife4j（若后端启用）：`http://localhost:8080/doc.html`

内置 PostgreSQL 与 Redis 只在容器内部网络开放。默认使用 `xydh-nav_postgres_data`、`xydh-nav_redis_data`、`xydh-nav_uploads_data`、`xydh-nav_backend_logs` 和 `xydh-nav_database_config` 五个显式命名卷，容器更新或重启不会清空业务数据、上传文件或安装向导保存的数据库连接配置。卷名可通过 `.env` 的 `*_VOLUME_NAME` 切换，供隔离恢复和快速回退使用。

## 首次部署安装向导

新部署把 `NAV_DATABASE_SOURCE` 设为 `UNCONFIGURED` 后，访问首页、后台或 `/install` 会进入首次部署向导。向导支持两种 PostgreSQL 模式：

- **内置 PostgreSQL**：使用 Compose 自带的 PostgreSQL 17 服务以及 `.env` 中的 `POSTGRES_*` 参数。
- **外部 PostgreSQL**：在页面中填写主机、端口、数据库名、业务用户名、密码和 TLS 模式。页面不接受原始 JDBC URL，也不会创建 PostgreSQL 服务器、数据库或角色。

当前根目录只有一套 Compose 编排：即使最终选择外部 PostgreSQL，`docker compose up` 仍会校验 `POSTGRES_PASSWORD`、创建并启动内置 PostgreSQL 服务及其命名卷。数据库接管成功后，后端业务连接会改用外部库，但这个未被使用的内置实例不会自动停用，也不能当作外部库的备份或恢复目标；检测到 `EXTERNAL` 时，项目运维脚本会失败关闭。若要完全不启动内置 PostgreSQL，需要另行维护外部模式专用的 Compose override，当前仓库不提供该编排。

外部模式要求部署者预先创建一个空白、专用的 PostgreSQL 14+ 数据库和非 superuser 业务用户，并授予连接及在 `public` schema 创建表、索引、序列、函数、触发器和迁移登记所需的 DDL 权限。向导会先只读测试连接；目标含未知对象、残缺项目结构、旧版未迁移结构或已安装管理员时均零写入拒绝。空库只有在用户明确确认后才执行权威 PostgreSQL schema 初始化。

安装页先验证 `NAV_INSTALL_TOKEN`，再进入“口令 → 数据库 → 环境 → 站点 → 账号 → 确认”六步流程。数据库测试成功只返回 5 分钟有效、单次使用且仅保存在当前页面内存中的随机 ticket；数据库密码和 CA 原文会立即从页面状态清除。配置成功后，后端把连接信息写入仅后端挂载的 `database_config` 卷（目录/文件限制为所有者可读写），自动重启并从该配置接管连接；密码不会进入 URL、浏览器存储或应用日志。外部 TLS 默认 `VERIFY_FULL`，也可选择 `VERIFY_CA`；`REQUIRE` 不校验证书和主机名，必须显式确认风险，外部模式不允许关闭 TLS。

数据库接管后才执行站点单例、上传目录和 Redis 检查，然后创建站点信息与唯一首位管理员。匿名状态接口不会探测外部资源或公开组件细节。安装口令只从权限为 `0600` 的 `.env` 传入，后端不会生成、回传或打印明文口令。当前 Compose 通过容器环境变量传递口令，拥有 Docker 管理权限的用户可查看容器配置；因此该权限等同于 root 权限。安装完成后应从 `.env` 删除口令、设置 `NAV_WEB_INSTALL_ENABLED=false` 并重建后端容器。

安装提交受到 Nginx 每来源 IP 限流。服务端会在同一事务中再次锁定并检查安装状态，只有用户表为空且安装标记未完成时才能写入；成功后入口永久关闭，不会签发自动登录令牌，需使用刚创建的账号在 `/admin/login` 登录。即使之后误删全部用户，安装标记也不会自动重开。已有管理员的升级部署会在数据库迁移时回填完成标记，不修改管理员、密码或站点业务数据。

默认示例入口是 HTTP，只适合受信任的本机或局域网首次安装。数据库密码、安装口令和管理员密码在公网 HTTP 中可能被旁路读取，因此外部数据库配置默认要求 HTTPS；仅在受信任局域网临时设置 `NAV_ALLOW_INSECURE_DATABASE_SETUP=true` 才允许 HTTP 提交。仓库内置 Nginx 目前只监听 HTTP，并会把上游传入的 `X-Forwarded-Proto` 覆写为自身的 `$scheme`；因此在它前面直接增加一个 TLS 代理并不能开箱即用，后端仍会看到 `http`。公网部署必须在项目 Nginx 同层终止 TLS，或者定制项目 Nginx，使其只接受明确列出的可信代理 IP 所传递的 HTTPS 协议信息和真实客户端地址；后一种拓扑还必须让项目 Nginx 入口仅绑定或暴露在 loopback/私有网络，不能同时允许公网客户端绕过可信代理直连。禁止无条件信任任意客户端提供的 `X-Forwarded-Proto` 或 `X-Forwarded-For`。

已有站点升级必须保持 `NAV_DATABASE_SOURCE=LEGACY_ENV`（或不设置，使用兼容默认值），不能改成 `UNCONFIGURED`。数据库连接文件、配置标记、完成标记或已有实例身份任一存在时，数据库断线只会进入故障状态，不会重新开放换库入口。

`database_config` 是安装状态与数据库实例身份的一部分，不是可丢弃缓存。当前 `ops/backup.sh`、恢复和演练脚本都不归档或重建这个卷：内置模式的同宿主机恢复依赖原卷仍然存在，跨宿主机恢复必须另行保护它；外部模式的卷还保存明文连接凭据及可选 CA，整个卷丢失后项目没有受支持的“重新关联既有外部库”流程，也不能把重新运行安装向导当作恢复方式。该卷的独立备份必须加密并异机保存，恢复后保持目录 `0700`、文件 `0600`。安装完成并确认登录成功后，应立即清空安装口令、关闭网页安装，并禁止对该卷执行 `down -v`、`volume rm` 或 `volume prune`。

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
| `APP_PORT` | Nginx 对外端口 | `8080` |
| `TZ` | 容器时区 | `Asia/Hong_Kong` |
| `POSTGRES_DB` | PostgreSQL 数据库名 | `nav_system` |
| `POSTGRES_USER` | PostgreSQL 业务用户 | `nav_user` |
| `POSTGRES_PASSWORD` | PostgreSQL 业务用户密码；当前 Compose 即使选择外部模式也会校验并启动内置 PostgreSQL | 必须修改 |
| `POSTGRES_VOLUME_NAME` | 当前 PostgreSQL 数据卷 | `xydh-nav_postgres_data` |
| `REDIS_VOLUME_NAME` | 当前 Redis 数据卷 | `xydh-nav_redis_data` |
| `UPLOADS_VOLUME_NAME` | 当前上传文件卷 | `xydh-nav_uploads_data` |
| `LOGS_VOLUME_NAME` | 当前后端日志卷 | `xydh-nav_backend_logs` |
| `DATABASE_CONFIG_VOLUME_NAME` | 安装向导持久化数据库连接与实例标记的后端专用卷 | `xydh-nav_database_config` |
| `BACKEND_IMAGE` / `FRONTEND_IMAGE` | 可固定或回滚的应用镜像引用 | `xydh-nav-*-latest` |
| `REDIS_PASSWORD` | Redis 密码 | 必须修改 |
| `CACHE_TYPE` | Spring 缓存实现 | Compose 使用 `redis` |
| `JWT_SECRET` | JWT 签名密钥 | 至少 32 字节随机值 |
| `JWT_EXPIRATION_MINUTES` | 登录令牌有效期（分钟，允许 5–10080） | `120` |
| `OPENAPI_ENABLED` | 生产环境是否开放 Swagger/OpenAPI | `false` |
| `CORS_ALLOWED_ORIGINS` | 允许跨域的来源列表 | 按实际域名修改 |
| `NAV_BOOTSTRAP_ENABLED` | 是否使用环境变量自动创建首位管理员 | `false` |
| `NAV_DEMO_DATA_ENABLED` | 是否由后端补写演示业务数据；生产应关闭 | `false` |
| `NAV_WEB_INSTALL_ENABLED` | 是否允许未初始化的新库使用网页安装向导 | `true` |
| `NAV_INSTALL_TOKEN` | 首次网页安装的一次性口令；必须是 64 位小写十六进制随机值 | 新部署必填 |
| `NAV_DATABASE_SOURCE` | 数据库来源；新部署用 `UNCONFIGURED`，已有站点升级保持 `LEGACY_ENV` | `.env.example` 为 `UNCONFIGURED` |
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
- 单文件上限同时编译进前端上传提示，并传给后端运行配置；修改 `APP_UPLOAD_MAX_BYTES` 后必须同时重新构建 frontend 与 backend，不能只重启容器。
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

可移植 ZIP 适合站点内容迁移和管理员自助恢复，但不替代灾难恢复备份。整站恢复还必须保存 PostgreSQL、上传卷、源码、镜像引用、加密后的环境配置，以及独立加密保存的 `database_config` 卷；当前项目运维脚本不会把最后一项打入普通备份。

## Nginx 路由

- `/`：转发到前端容器。
- `/api`：转发到后端容器并保留原始路径。
- `POST /api/admin/auth/login`：按来源 IP 限制为平均每分钟 5 次、允许 5 次突发；超限返回统一 JSON 格式的 `429`。
- `POST /api/install/database/test` 与 `POST /api/install/database/configure`：共享平均每分钟 3 次、允许 3 次突发的数据库配置预算；`POST /api/install/check` 与 `POST /api/install/complete` 使用另一组同额度预算，避免一次合法六步安装流程消耗掉自己的完成额度。数据库凭据端点不写访问日志且请求体只在内存缓冲，匿名状态查询另限为每分钟 30 次。
- `POST /api/admin/data/import/preview`：独立允许 66MiB 请求体并使用 120 秒上游读取超时，应用层仍严格限制 ZIP 为 64MiB。
- 当前限流键使用入口 Nginx 直接看到的连接地址。若前面还有 Cloudflare、宿主机 Nginx 或其他 HTTPS 反向代理，必须只针对该可信代理配置 `set_real_ip_from`、对应的 `real_ip_header` 以及受信的 HTTPS 协议信息，并把项目 Nginx 入口限制在 loopback/私有网络。仓库配置会把 `X-Forwarded-Proto` 覆写成自身 `$scheme`，所以外层 TLS 代理不是开箱即用；不要直接信任任意客户端传入的转发头，否则来源和安全协议都可被伪造。未配置真实来源恢复时，所有访客还可能共用上游代理的同一个登录额度。
- `/uploads/`：从持久化上传卷直接提供静态文件。
- `/swagger-ui/`、`/v3/api-docs`、`/doc.html`：转发到后端接口文档；生产默认由后端关闭。
- `/healthz`：Nginx 自身健康检查。

## PostgreSQL 初始化、迁移与灾难恢复

根目录 `database/init.sql` 是 Compose 第一次创建内置 PostgreSQL 卷时执行的初始化资源；`nav-backend/src/main/resources/schema-postgresql.sql` 会打包进后端，并由安装向导初始化用户明确确认的空白外部数据库。两份文件必须保持语义同步，包括完整表结构、约束、种子数据以及 `schema_migration` 中登记的迁移文件名和 SHA-256；修改其中任一份时必须同步修改并校验另一份。生产 profile 不自动执行 DDL。内置 PostgreSQL 由 `database/migrations/` 中不可修改的校验和迁移与 `ops/migrate.sh` 升级；外部 PostgreSQL 目前没有项目内置的升级命令，后续 schema 版本变更必须在服务商备份后按受控流程执行并校验实例 UUID，不能运行会操作未使用内置库的 `ops/migrate.sh`。

当前迁移链从 `20260812_0001_postgresql_baseline.sql` 开始，`20260814_0002_web_install_state.sql` 增加网页安装状态，`20260815_0003_install_instance_identity.sql` 增加跨运行配置核验的数据库实例 UUID。新库由初始化 SQL 创建完整结构并登记三项迁移；已有库必须在新版后端启动前运行 `ops/migrate.sh`。脚本会拒绝执行校验和与登记值不一致的迁移。生产默认关闭传统环境变量引导，由一次性网页安装创建首位管理员；即使管理员被删除，持久化的安装完成标记也不会让安装向导或传统引导自动重开。

从项目旧 MySQL 版本升级时：

1. 先对 MySQL、上传卷、源码、`.env` 和镜像引用做完整备份并复验 SHA-256。
2. 使用新的 `POSTGRES_VOLUME_NAME` 启动 PostgreSQL，切勿复用或删除 `xydh-nav_mysql_data`。
3. 设置 `CONFIRM_MIGRATION=MYSQL-TO-POSTGRESQL` 后运行 `ops/migrate-mysql-to-postgresql.sh`。脚本只读 MySQL、在单事务内写入 PostgreSQL，并逐表比较规范化 JSON 与整体摘要。
4. 比较通过后再部署连接 PostgreSQL 的后端；旧 MySQL 容器和卷保留为回退锚点。

`database/legacy-mysql/` 只保存旧版 MySQL schema 和历史迁移，不能对 PostgreSQL 执行。一次性迁移脚本默认拒绝覆盖已经包含管理员的 PostgreSQL 目标，防止误把旧快照重复写回线上库。

整站运维脚本必须在受控项目目录执行，`.env` 权限必须为 `0600`：

- `ops/backup.sh <标签>`：生成 PostgreSQL custom dump、上传卷、可构建源码、迁移登记、计数、镜像引用和校验清单；设置 `BACKUP_AGE_RECIPIENT` 时才会保存 age 加密的环境文件。它不包含 `database_config` 卷。
- `ops/verify-backup.sh <目录>`：复验 SHA-256、manifest、归档路径/链接、文件权限和 `pg_restore` 可读性。
- `ops/restore-drill.sh <目录>`：在批次命名的新 PostgreSQL/上传卷中恢复并核对计数、外键、默认搜索引擎和文件数，默认验收后只删除带精确演练标签的临时资源。
- `ops/restore.sh <目录>`：默认只恢复到新卷，不接入生产；只有同时提供 `--activate` 与 `CONFIRM_RESTORE=RESTORE-PRODUCTION` 才切换，失败自动切回原卷，原卷始终保留。
- `ops/rollback-release.sh <后端镜像> <前端镜像>`：只切换已存在的应用镜像，不更换数据库或上传卷。

当前 `ops/backup.sh`、`ops/migrate.sh`、正式恢复切换、MySQL 转换和版本回滚只支持内置 PostgreSQL。脚本会读取后端专用配置卷并在检测到 `EXTERNAL` 时失败关闭，绝不会继续备份或迁移未被应用使用的本地 PostgreSQL。外部数据库部署应使用数据库服务商提供的加密备份/恢复能力，并同时保存上传卷与后台可移植 ZIP；在项目增加受控外部数据库客户端和实例 UUID 校验前，不应把内置脚本称为外部数据库整站备份。

安装向导管理的内置模式在同一宿主机恢复时依赖原有 `database_config` 卷；跨宿主机恢复时必须从独立备份还原，否则当前脚本不会重建配置与实例身份状态。外部模式还必须把该卷做加密异机备份，因为它包含明文连接凭据、可选 CA 证书和实例身份标记；仅有服务商数据库备份、上传卷和后台可移植 ZIP 仍不足以恢复应用连接。当前项目没有在该卷丢失后重新关联既有外部数据库的受支持流程。恢复配置卷时保持目录 `0700`、文件 `0600`。

绝不要对需要保留的环境执行 `docker compose down -v`、`docker volume prune` 或带 `--remove-orphans` 的切换命令。备份至少应再复制一份到异机/对象存储并定期执行恢复演练；只存在同一虚拟机上的备份不能覆盖宿主机磁盘故障。

## 安全提醒

- 上线前务必更换数据库、Redis、管理员密码以及 `JWT_SECRET`，不要提交 `.env`。
- 管理员密码应遵守账号安全页的强度规则并定期更新；轮换 `JWT_SECRET` 会使所有现有 JWT 失效。
- 生产环境必须在项目 Nginx 同层终止 HTTPS，或采用只信任明确代理 IP、且项目入口仅对 loopback/私网开放的定制代理配置；仓库默认配置不能直接套在外层 TLS 代理后宣称已安全启用 HTTPS。跨域来源还应按实际域名限制。
- 定期轮换密钥、备份数据库和上传文件，并及时更新基础镜像。
- Swagger/OpenAPI 在生产 profile 默认关闭；只应在受控网络中临时设置 `OPENAPI_ENABLED=true`，使用完立即关闭。
- 背景图片接口同时校验 MIME、文件魔数、图像格式、尺寸和文件大小；普通 `/api/` 请求体上限为 12MiB，图片业务层最高接受 10MiB。只有数据包预检精确入口允许 66MiB multipart 请求，ZIP 解析器仍限制归档和总展开量为 64MiB、单条目为 16MiB。
