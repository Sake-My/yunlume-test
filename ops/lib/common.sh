#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly PROJECT_DIR="$(cd -- "${OPS_DIR}/.." && pwd -P)"
readonly COMPOSE_PROJECT_NAME="xydh-nav"
readonly ENV_FILE="${ENV_FILE:-${PROJECT_DIR}/.env}"
readonly BACKUP_ROOT="${BACKUP_ROOT:-/opt/xy-navigation-backups}"
readonly OPERATIONS_LOCK="${OPERATIONS_LOCK:-/run/lock/xydh-nav-operations.lock}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

assert_project_directory() {
  local expected
  expected="$(realpath -m "${EXPECTED_PROJECT_DIR:-/opt/xy-navigation}")"
  [[ "${PROJECT_DIR}" == "${expected}" ]] ||
    die "拒绝在非预期项目目录执行: ${PROJECT_DIR}（预期 ${expected}）"
  [[ -f "${PROJECT_DIR}/docker-compose.yml" ]] || die "缺少 docker-compose.yml"
}

load_environment() {
  [[ -f "${ENV_FILE}" ]] || die "缺少运行环境文件: ${ENV_FILE}"
  local mode
  mode="$(stat -c '%a' "${ENV_FILE}")"
  (( (8#${mode} & 8#077) == 0 )) || die "${ENV_FILE} 权限过宽，应为 600"

  # Compose dotenv files are not shell scripts (for example JAVA_OPTS may
  # contain unquoted spaces).  Parse only the small allow-list needed by the
  # operational scripts and never execute file contents.
  local raw line key value
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    line="${raw%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "${ENV_FILE} 包含无法解析的环境变量行"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    case "${key}" in
      POSTGRES_DB|POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_VOLUME_NAME|UPLOADS_VOLUME_NAME|\
      DATABASE_CONFIG_VOLUME_NAME|NAV_DATABASE_SOURCE|BACKEND_IMAGE|FRONTEND_IMAGE|APP_PORT)
        printf -v "${key}" '%s' "${value}"
        export "${key}"
        ;;
    esac
  done <"${ENV_FILE}"

  : "${POSTGRES_DB:?POSTGRES_DB 未配置}"
  : "${POSTGRES_USER:?POSTGRES_USER 未配置}"
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD 未配置}"
  NAV_DATABASE_SOURCE="${NAV_DATABASE_SOURCE:-LEGACY_ENV}"
  DATABASE_CONFIG_VOLUME_NAME="${DATABASE_CONFIG_VOLUME_NAME:-xydh-nav_database_config}"
  export NAV_DATABASE_SOURCE DATABASE_CONFIG_VOLUME_NAME
}

acquire_operations_lock() {
  require_command flock
  install -d -m 0755 "$(dirname -- "${OPERATIONS_LOCK}")"
  exec 9>"${OPERATIONS_LOCK}"
  flock -n 9 || die "已有备份、迁移或恢复任务正在运行"
}

compose() {
  docker compose \
    --project-name "${COMPOSE_PROJECT_NAME}" \
    --project-directory "${PROJECT_DIR}" \
    --env-file "${ENV_FILE}" \
    --file "${PROJECT_DIR}/docker-compose.yml" \
    "$@"
}

postgres_container_id() {
  local container
  container="$(compose ps -q postgres)"
  [[ -n "${container}" ]] || die "PostgreSQL 容器未运行"
  printf '%s\n' "${container}"
}

postgres_exec() {
  compose exec -T \
    -e "PGPASSWORD=${POSTGRES_PASSWORD}" \
    postgres "$@"
}

# Operational scripts currently support only the bundled PostgreSQL service.
# A web-configured external database must fail closed here; otherwise a command
# could successfully back up or migrate the unused local PostgreSQL container.
active_database_mode() {
  local mode image image_id
  validate_label "${DATABASE_CONFIG_VOLUME_NAME}"

  if ! docker volume inspect "${DATABASE_CONFIG_VOLUME_NAME}" >/dev/null 2>&1; then
    if [[ "${NAV_DATABASE_SOURCE}" == "LEGACY_ENV" ]]; then
      printf '%s\n' "LEGACY_ENV"
    else
      printf '%s\n' "UNCONFIGURED"
    fi
    return 0
  fi

  image="${BACKEND_IMAGE:-xydh-nav-backend:latest}"
  image_id="$(docker image inspect --format '{{.Id}}' "${image}" 2>/dev/null || true)"
  [[ "${image_id}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "无法安全读取活动数据库模式：后端镜像不存在 ${image}"

  mode="$(docker run --rm --pull never --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges \
    --mount "type=volume,src=${DATABASE_CONFIG_VOLUME_NAME},dst=/app/config,readonly,volume-nocopy" \
    --entrypoint sh "${image_id}" -eu -c '
      config=/app/config/database.properties
      marker=/app/config/database.configured
      completed=/app/config/install.completed
      ca=/app/config/postgresql-ca.pem
      prop() { sed -n "s/^$1=//p" "$2"; }
      invalid() { printf "%s\n" INVALID; exit 0; }

      if [ -L "$config" ]; then invalid; fi
      if [ ! -f "$config" ]; then
        if [ -e "$marker" ] || [ -e "$completed" ] || [ -e "$ca" ]; then
          printf "%s\n" INVALID
        else
          printf "%s\n" MISSING
        fi
        exit 0
      fi
      [ ! -L "$marker" ] && [ -f "$marker" ] || invalid
      [ "$(stat -c %a /app/config)" = 700 ] || invalid
      [ "$(stat -c %a "$config")" = 600 ] || invalid
      [ "$(stat -c %a "$marker")" = 600 ] || invalid
      if [ -e "$completed" ]; then
        [ ! -L "$completed" ] && [ -f "$completed" ] || invalid
        [ "$(stat -c %a "$completed")" = 600 ] || invalid
      fi

      config_format="$(prop "nav\\.database-config\\.format" "$config")"
      config_mode="$(prop "nav\\.database-config\\.mode" "$config")"
      config_id="$(prop "nav\\.database-config\\.expected-instance-id" "$config")"
      marker_format="$(prop "nav\\.database-marker\\.format" "$marker")"
      marker_state="$(prop state "$marker")"
      marker_mode="$(prop mode "$marker")"
      marker_id="$(prop "instance-id" "$marker")"
      [ "$config_format" = 1 ] || invalid
      [ "$marker_format" = 1 ] || invalid
      [ "$marker_state" = CONFIGURED ] || invalid
      [ "$config_mode" = "$marker_mode" ] || invalid
      [ "$config_id" = "$marker_id" ] || invalid
      printf "%s" "$config_id" | grep -Eq "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$" || invalid

      if [ -e "$completed" ]; then
        completed_format="$(prop "nav\\.install-completed\\.format" "$completed")"
        completed_id="$(prop "instance-id" "$completed")"
        [ "$completed_format" = 1 ] || invalid
        [ "$completed_id" = "$config_id" ] || invalid
      fi

      if [ "$config_mode" != EXTERNAL ] && [ "$config_mode" != EMBEDDED ]; then
        invalid
      fi

      printf "%s\n" "$config_mode"
    ')" || die "无法安全读取活动数据库模式"

  case "${mode}" in
    EMBEDDED|EXTERNAL)
      printf '%s\n' "${mode}"
      ;;
    MISSING)
      if [[ "${NAV_DATABASE_SOURCE}" == "LEGACY_ENV" ]]; then
        printf '%s\n' "LEGACY_ENV"
      else
        printf '%s\n' "UNCONFIGURED"
      fi
      ;;
    *)
      die "运行时数据库配置缺失、损坏或格式不受支持；拒绝执行数据库操作"
      ;;
  esac
}

require_embedded_database_operations() {
  local mode
  mode="$(active_database_mode)"
  case "${mode}" in
    LEGACY_ENV|EMBEDDED)
      return 0
      ;;
    EXTERNAL)
      die "当前站点使用外部 PostgreSQL；此脚本仅支持内置数据库，已拒绝操作未使用的本地库"
      ;;
    UNCONFIGURED)
      die "数据库尚未完成配置；不能执行备份、迁移、恢复切换或版本回滚"
      ;;
    *)
      die "无法确认活动数据库模式；拒绝继续"
      ;;
  esac
}

validate_label() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "标签格式无效"
}

assert_path_within_backup_root() {
  local target root
  target="$(realpath -m "$1")"
  root="$(realpath -m "${BACKUP_ROOT}")"
  [[ "${target}" == "${root}/"* ]] || die "路径不在备份根目录内: ${target}"
  [[ "${target}" != "${root}" ]] || die "拒绝把备份根目录本身作为操作目标"
}

require_healthy_postgres() {
  local container health
  container="$(postgres_container_id)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container}")"
  [[ "${health}" == "healthy" || "${health}" == "running" ]] ||
    die "PostgreSQL 容器状态异常: ${health}"
  postgres_exec pg_isready -q -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" ||
    die "PostgreSQL 尚未就绪"
}

postgres_is_healthy() {
  local container health
  container="$(compose ps -q postgres 2>/dev/null)" || return 1
  [[ -n "${container}" ]] || return 1
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container}" 2>/dev/null)" ||
    return 1
  [[ "${health}" == "healthy" || "${health}" == "running" ]] || return 1
  postgres_exec pg_isready -q -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1
}

# Resolve a PostgreSQL image without consulting a running production container.
# The checked-in Compose service is preferred.  An immutable image ID recorded
# in a checksum-verified backup is an offline fallback (for example after
# loading that backup's images.tar.gz).  No untrusted manifest reference is
# pulled or executed implicitly.
resolve_trusted_postgres_image() {
  local backup_dir="$1"
  local compose_image actual_id
  local -a manifest_image

  [[ -f "${backup_dir}/manifest.json" ]] || die "备份缺少 manifest.json"
  require_command python3

  compose_image="$(compose config --format json | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
image = payload.get("services", {}).get("postgres", {}).get("image")
if not isinstance(image, str) or not image or len(image) > 500 or any(ch.isspace() for ch in image):
    raise SystemExit("Compose PostgreSQL 镜像配置无效")
print(image)
')" || die "无法读取 Compose PostgreSQL 镜像配置"

  mapfile -t manifest_image < <(python3 - "${backup_dir}/manifest.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
postgres = payload.get("images", {}).get("postgres", {})
reference = postgres.get("reference", "")
image_id = postgres.get("id", "")
print(reference if isinstance(reference, str) else "")
print(image_id if isinstance(image_id, str) else "")
PY
  )
  (( ${#manifest_image[@]} == 2 )) || die "备份缺少 PostgreSQL 镜像元数据"

  if docker image inspect "${compose_image}" >/dev/null 2>&1; then
    printf '%s\n' "${compose_image}"
    return 0
  fi

  [[ "${manifest_image[1]}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "Compose PostgreSQL 镜像不在本地，且备份镜像 ID 无效"
  actual_id="$(docker image inspect --format '{{.Id}}' "${manifest_image[1]}" 2>/dev/null || true)"
  [[ "${actual_id}" == "${manifest_image[1]}" ]] ||
    die "可信 PostgreSQL 镜像不在本地；请先拉取 Compose 镜像或加载备份 images.tar.gz"
  printf '%s\n' "${manifest_image[1]}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}
