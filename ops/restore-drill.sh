#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# Restores a backup into isolated, batch-named volumes. Production services and
# volumes are never mounted, stopped, or modified.

# shellcheck source=ops/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

[[ $# -eq 1 ]] || die "用法: $0 /opt/xy-navigation-backups/<备份目录>"
assert_project_directory
require_command docker
require_command openssl
require_command python3
acquire_operations_lock
load_environment

backup_dir="$(realpath -e "$1")"
assert_path_within_backup_root "${backup_dir}"
SKIP_OPERATIONS_LOCK=1 "${OPS_DIR}/verify-backup.sh" "${backup_dir}"

batch="$(date -u +'%Y%m%d%H%M%S')-$$"
drill_container="xydh-nav-drill-postgres-${batch}"
postgres_volume="xydh-nav-drill-postgres-data-${batch}"
uploads_volume="xydh-nav-drill-uploads-data-${batch}"
drill_password="$(openssl rand -hex 32)"
postgres_image="$(resolve_trusted_postgres_image "${backup_dir}")"

assert_drill_name() {
  [[ "$1" =~ ^xydh-nav-drill-(postgres|postgres-data|uploads-data)-[0-9]{14}-[0-9]+$ ]] ||
    die "临时资源名称不安全: $1"
}
assert_drill_name "${drill_container}"
assert_drill_name "${postgres_volume}"
assert_drill_name "${uploads_volume}"
docker container inspect "${drill_container}" >/dev/null 2>&1 && die "演练容器名已存在，拒绝复用"
docker volume inspect "${postgres_volume}" >/dev/null 2>&1 && die "演练 PostgreSQL 卷已存在，拒绝复用"
docker volume inspect "${uploads_volume}" >/dev/null 2>&1 && die "演练上传卷已存在，拒绝复用"

cleanup() {
  local status=$?
  if [[ "${KEEP_DRILL:-0}" == "1" ]]; then
    info "已按 KEEP_DRILL=1 保留隔离资源: ${drill_container}, ${postgres_volume}, ${uploads_volume}"
    exit "${status}"
  fi
  if docker container inspect "${drill_container}" >/dev/null 2>&1; then
    [[ "$(docker inspect --format '{{index .Config.Labels "xydh-nav.restore-drill"}}' "${drill_container}")" == "true" ]] ||
      die "拒绝清理标签不匹配的容器"
    docker rm -f "${drill_container}" >/dev/null
  fi
  for volume in "${postgres_volume}" "${uploads_volume}"; do
    if docker volume inspect "${volume}" >/dev/null 2>&1; then
      [[ "$(docker volume inspect --format '{{index .Labels "xydh-nav.restore-drill"}}' "${volume}")" == "true" ]] ||
        die "拒绝清理标签不匹配的卷: ${volume}"
      docker volume rm "${volume}" >/dev/null
    fi
  done
  exit "${status}"
}
trap cleanup EXIT

docker volume create --label xydh-nav.restore-drill=true "${postgres_volume}" >/dev/null
docker volume create --label xydh-nav.restore-drill=true "${uploads_volume}" >/dev/null
[[ "$(docker volume inspect --format '{{index .Labels "xydh-nav.restore-drill"}}' "${postgres_volume}")" == "true" ]] ||
  die "演练 PostgreSQL 卷标签校验失败"
[[ "$(docker volume inspect --format '{{index .Labels "xydh-nav.restore-drill"}}' "${uploads_volume}")" == "true" ]] ||
  die "演练上传卷标签校验失败"
docker run -d \
  --name "${drill_container}" \
  --label xydh-nav.restore-drill=true \
  --network none \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${drill_password}" \
  -v "${postgres_volume}:/var/lib/postgresql/data" \
  --health-cmd="pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}" \
  --health-interval=2s --health-timeout=2s --health-retries=30 \
  "${postgres_image}" >/dev/null

for _ in $(seq 1 40); do
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${drill_container}")"
  [[ "${state}" == "healthy" ]] && break
  [[ "${state}" == "unhealthy" || "${state}" == "exited" ]] && die "隔离 PostgreSQL 启动失败"
  sleep 2
done
[[ "$(docker inspect --format '{{.State.Health.Status}}' "${drill_container}")" == "healthy" ]] ||
  die "隔离 PostgreSQL 启动超时"

docker exec -i -e "PGPASSWORD=${drill_password}" "${drill_container}" \
  pg_restore --exit-on-error --clean --if-exists --no-owner --no-privileges \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  <"${backup_dir}/database.dump"

docker run --rm -i \
  --label xydh-nav.restore-drill=true \
  -v "${uploads_volume}:/restore" \
  nginx:1.27-alpine tar -C /restore -xzf - \
  <"${backup_dir}/uploads-data.tar.gz"

actual_counts="$(docker exec -e "PGPASSWORD=${drill_password}" "${drill_container}" \
  psql --no-psqlrc --tuples-only --no-align --field-separator='|' \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  --command "SELECT (SELECT count(*) FROM sys_user), (SELECT count(*) FROM site_config), (SELECT count(*) FROM nav_category), (SELECT count(*) FROM nav_bookmark), (SELECT count(*) FROM search_engine), (SELECT count(*) FROM custom_link);")"
upload_files="$(docker run --rm -v "${uploads_volume}:/restore:ro" nginx:1.27-alpine \
  sh -c "find /restore -type f | wc -l")"

python3 - "${backup_dir}/manifest.json" "${actual_counts}" "${upload_files}" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
actual = [int(value) for value in sys.argv[2].strip().split("|")]
expected = manifest["counts"]
expected_values = [
    expected["users"], expected["siteConfigs"], expected["categories"],
    expected["bookmarks"], expected["searchEngines"], expected["customLinks"],
]
if actual != expected_values:
    raise SystemExit(f"恢复计数不一致: expected={expected_values}, actual={actual}")
if int(sys.argv[3].strip()) != expected["uploadFiles"]:
    raise SystemExit("恢复后的上传文件数不一致")
PY

violations="$(docker exec -e "PGPASSWORD=${drill_password}" "${drill_container}" \
  psql --no-psqlrc --tuples-only --no-align \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  --command "SELECT (SELECT count(*) FROM nav_bookmark b LEFT JOIN nav_category c ON c.id=b.category_id WHERE c.id IS NULL) + CASE WHEN (SELECT count(*) FROM search_engine WHERE visible IS TRUE AND is_default IS TRUE)=1 THEN 0 ELSE 1 END;")"
[[ "${violations}" == "0" ]] || die "恢复后的关联或默认搜索引擎约束异常"

info "隔离恢复演练通过（生产服务与生产卷未修改）"
info "COUNTS=${actual_counts}|uploads=${upload_files}"
