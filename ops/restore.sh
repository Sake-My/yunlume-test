#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# Restores into new volumes first. Production is switched only with --activate
# and an explicit confirmation phrase; old volumes are always retained.

# shellcheck source=ops/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

[[ $# -ge 1 && $# -le 2 ]] || die "用法: $0 <备份目录> [--activate]"
activate=false
if [[ "${2:-}" == "--activate" ]]; then
  activate=true
elif [[ -n "${2:-}" ]]; then
  die "未知参数: ${2}"
fi
if [[ "${activate}" == "true" && "${CONFIRM_RESTORE:-}" != "RESTORE-PRODUCTION" ]]; then
  die "正式切换需要显式设置 CONFIRM_RESTORE=RESTORE-PRODUCTION"
fi

assert_project_directory
require_command docker
require_command python3
require_command curl
acquire_operations_lock
load_environment
if [[ "${activate}" == "true" ]]; then
  require_embedded_database_operations
fi

backup_dir="$(realpath -e "$1")"
assert_path_within_backup_root "${backup_dir}"
SKIP_OPERATIONS_LOCK=1 "${OPS_DIR}/verify-backup.sh" "${backup_dir}"

batch="$(date -u +'%Y%m%d%H%M%S')-$$"
restore_container="xydh-nav-restore-postgres-${batch}"
new_postgres_volume="xydh-nav-postgres-restore-${batch}"
new_uploads_volume="xydh-nav-uploads-restore-${batch}"
# The restored cluster may later be mounted by the production Compose service.
# PostgreSQL ignores POSTGRES_PASSWORD once PGDATA is initialized, so the
# isolated restore must use the configured production password from the start.
restore_password="${POSTGRES_PASSWORD}"
postgres_image="$(resolve_trusted_postgres_image "${backup_dir}")"

[[ "${restore_container}" =~ ^xydh-nav-restore-postgres-[0-9]{14}-[0-9]+$ ]] || die "恢复容器名无效"
[[ "${new_postgres_volume}" =~ ^xydh-nav-postgres-restore-[0-9]{14}-[0-9]+$ ]] || die "恢复卷名无效"
[[ "${new_uploads_volume}" =~ ^xydh-nav-uploads-restore-[0-9]{14}-[0-9]+$ ]] || die "恢复卷名无效"
docker container inspect "${restore_container}" >/dev/null 2>&1 && die "恢复容器名已存在，拒绝复用"
docker volume inspect "${new_postgres_volume}" >/dev/null 2>&1 && die "PostgreSQL 恢复卷已存在，拒绝复用"
docker volume inspect "${new_uploads_volume}" >/dev/null 2>&1 && die "上传恢复卷已存在，拒绝复用"

temporary_container_exists=false
cleanup_temporary_container() {
  if [[ "${temporary_container_exists}" == "true" ]] && docker container inspect "${restore_container}" >/dev/null 2>&1; then
    [[ "$(docker inspect --format '{{index .Config.Labels "xydh-nav.restore"}}' "${restore_container}")" == "true" ]] ||
      die "拒绝清理标签不匹配的恢复容器"
    docker rm -f "${restore_container}" >/dev/null
  fi
}
trap cleanup_temporary_container EXIT

docker volume create \
  --label xydh-nav.restore=true \
  --label com.docker.compose.project="${COMPOSE_PROJECT_NAME}" \
  --label com.docker.compose.volume=postgres_data \
  "${new_postgres_volume}" >/dev/null
docker volume create \
  --label xydh-nav.restore=true \
  --label com.docker.compose.project="${COMPOSE_PROJECT_NAME}" \
  --label com.docker.compose.volume=uploads_data \
  "${new_uploads_volume}" >/dev/null
[[ "$(docker volume inspect --format '{{index .Labels "xydh-nav.restore"}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.volume"}}' "${new_postgres_volume}")" == "true|${COMPOSE_PROJECT_NAME}|postgres_data" ]] ||
  die "PostgreSQL 恢复卷标签校验失败"
[[ "$(docker volume inspect --format '{{index .Labels "xydh-nav.restore"}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.volume"}}' "${new_uploads_volume}")" == "true|${COMPOSE_PROJECT_NAME}|uploads_data" ]] ||
  die "上传恢复卷标签校验失败"
docker run -d \
  --name "${restore_container}" \
  --label xydh-nav.restore=true \
  --network none \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${restore_password}" \
  -v "${new_postgres_volume}:/var/lib/postgresql/data" \
  --health-cmd="pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}" \
  --health-interval=2s --health-timeout=2s --health-retries=30 \
  "${postgres_image}" >/dev/null
temporary_container_exists=true

for _ in $(seq 1 40); do
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${restore_container}")"
  [[ "${state}" == "healthy" ]] && break
  [[ "${state}" == "unhealthy" || "${state}" == "exited" ]] && die "恢复 PostgreSQL 启动失败"
  sleep 2
done
[[ "$(docker inspect --format '{{.State.Health.Status}}' "${restore_container}")" == "healthy" ]] ||
  die "恢复 PostgreSQL 启动超时"

docker exec -i -e "PGPASSWORD=${restore_password}" "${restore_container}" \
  pg_restore --exit-on-error --clean --if-exists --no-owner --no-privileges \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  <"${backup_dir}/database.dump"
docker run --rm -i -v "${new_uploads_volume}:/restore" nginx:1.27-alpine \
  tar -C /restore -xzf - <"${backup_dir}/uploads-data.tar.gz"

actual_counts="$(docker exec -e "PGPASSWORD=${restore_password}" "${restore_container}" \
  psql --no-psqlrc --tuples-only --no-align --field-separator='|' \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  --command "SELECT (SELECT count(*) FROM sys_user), (SELECT count(*) FROM site_config), (SELECT count(*) FROM nav_category), (SELECT count(*) FROM nav_bookmark), (SELECT count(*) FROM search_engine), (SELECT count(*) FROM custom_link);")"
upload_files="$(docker run --rm -v "${new_uploads_volume}:/restore:ro" nginx:1.27-alpine \
  sh -c "find /restore -type f | wc -l")"
python3 - "${backup_dir}/manifest.json" "${actual_counts}" "${upload_files}" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
actual = [int(v) for v in sys.argv[2].strip().split("|")]
c = manifest["counts"]
expected = [c["users"], c["siteConfigs"], c["categories"], c["bookmarks"], c["searchEngines"], c["customLinks"]]
if actual != expected:
    raise SystemExit(f"恢复计数不一致: expected={expected}, actual={actual}")
if int(sys.argv[3].strip()) != c["uploadFiles"]:
    raise SystemExit("恢复后的上传文件数不一致")
PY

cleanup_temporary_container
temporary_container_exists=false

info "恢复数据已写入并校验，新卷尚未连接生产："
info "POSTGRES_VOLUME_NAME=${new_postgres_volume}"
info "UPLOADS_VOLUME_NAME=${new_uploads_volume}"
if [[ "${activate}" != "true" ]]; then
  info "如需正式切换，可重新执行并加 --activate；该操作会再创建一组新卷，当前生产未修改"
  exit 0
fi

old_postgres_volume="${POSTGRES_VOLUME_NAME:-xydh-nav_postgres_data}"
old_uploads_volume="${UPLOADS_VOLUME_NAME:-xydh-nav_uploads_data}"
[[ "${old_postgres_volume}" != "${new_postgres_volume}" ]] || die "新旧 PostgreSQL 卷不能相同"
[[ "${old_uploads_volume}" != "${new_uploads_volume}" ]] || die "新旧上传卷不能相同"

if postgres_is_healthy; then
  info "正式切换前创建当前整站备份..."
  SKIP_OPERATIONS_LOCK=1 "${OPS_DIR}/backup.sh" pre-restore
else
  info "当前 PostgreSQL 不可用，无法创建在线切换前备份；原数据库卷和上传卷将原样保留用于回退"
fi

rollback_env="${PROJECT_DIR}/.env.restore-rollback-${batch}"
cp --preserve=mode,timestamps -- "${ENV_FILE}" "${rollback_env}"
chmod 0600 "${rollback_env}"

update_env_volume_names() {
  local postgres_name="$1"
  local uploads_name="$2"
  ENV_UPDATE_FILE="${ENV_FILE}" \
  ENV_POSTGRES_VOLUME="${postgres_name}" \
  ENV_UPLOADS_VOLUME="${uploads_name}" \
  python3 <<'PY'
import os
from pathlib import Path

path = Path(os.environ["ENV_UPDATE_FILE"])
updates = {
    "POSTGRES_VOLUME_NAME": os.environ["ENV_POSTGRES_VOLUME"],
    "UPLOADS_VOLUME_NAME": os.environ["ENV_UPLOADS_VOLUME"],
}
lines = path.read_text(encoding="utf-8").splitlines()
found = set()
result = []
for line in lines:
    key = line.split("=", 1)[0] if "=" in line and not line.lstrip().startswith("#") else None
    if key in updates:
        result.append(f"{key}={updates[key]}")
        found.add(key)
    else:
        result.append(line)
for key, value in updates.items():
    if key not in found:
        result.append(f"{key}={value}")
temp = path.with_name(path.name + ".tmp")
temp.write_text("\n".join(result) + "\n", encoding="utf-8")
os.chmod(temp, 0o600)
os.replace(temp, path)
PY
}

rollback_production() {
  local status=$?
  info "新卷切换失败，正在切回原卷（新恢复卷保留）..."
  cp --preserve=mode,timestamps -- "${rollback_env}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  export POSTGRES_VOLUME_NAME="${old_postgres_volume}"
  export UPLOADS_VOLUME_NAME="${old_uploads_volume}"
  compose up -d postgres redis backend frontend nginx || true
  rm -f -- "${rollback_env}"
  exit "${status}"
}
trap rollback_production ERR

update_env_volume_names "${new_postgres_volume}" "${new_uploads_volume}"
export POSTGRES_VOLUME_NAME="${new_postgres_volume}"
export UPLOADS_VOLUME_NAME="${new_uploads_volume}"
compose up -d postgres redis backend frontend nginx

active_postgres_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$(compose ps -q postgres)")"
active_backend_uploads="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/uploads"}}{{.Name}}{{end}}{{end}}' "$(compose ps -q backend)")"
active_nginx_uploads="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/www/uploads"}}{{.Name}}{{end}}{{end}}' "$(compose ps -q nginx)")"
[[ "${active_postgres_volume}" == "${new_postgres_volume}" ]] ||
  die "切换后的 PostgreSQL 未挂载预期恢复卷"
[[ "${active_backend_uploads}" == "${new_uploads_volume}" && "${active_nginx_uploads}" == "${new_uploads_volume}" ]] ||
  die "切换后的上传目录未挂载预期恢复卷"

for _ in $(seq 1 45); do
  unhealthy=0
  for service in postgres redis backend frontend nginx; do
    container="$(compose ps -q "${service}")"
    if [[ -z "${container}" ]]; then
      unhealthy=1
      break
    fi
    state="$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container}")"
    [[ "${state}" == "running|healthy" || "${state}" == "running|" ]] || {
      unhealthy=1
      break
    }
  done
  [[ "${unhealthy}" == "0" ]] && break
  sleep 2
done
[[ "${unhealthy}" == "0" ]] || die "切换后的容器未在时限内全部健康"
compose ps
curl --fail --silent --show-error "http://127.0.0.1:${APP_PORT:-8080}/healthz" >/dev/null
curl --fail --silent --show-error "http://127.0.0.1:${APP_PORT:-8080}/api/health" >/dev/null

trap - ERR
rm -f -- "${rollback_env}"
info "正式恢复切换完成；原卷仍保留：${old_postgres_volume}, ${old_uploads_volume}"
