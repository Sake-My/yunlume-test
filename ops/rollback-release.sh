#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# Code-only rollback. Database and upload volumes are never changed.

# shellcheck source=ops/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

[[ $# -eq 2 ]] || die "用法: $0 <后端镜像引用> <前端镜像引用>"
[[ "${CONFIRM_ROLLBACK:-}" == "ROLLBACK-RELEASE" ]] ||
  die "请显式设置 CONFIRM_ROLLBACK=ROLLBACK-RELEASE"
backend_target="$1"
frontend_target="$2"

assert_project_directory
require_command docker
require_command python3
require_command curl
acquire_operations_lock
load_environment
require_embedded_database_operations
require_healthy_postgres
docker image inspect "${backend_target}" >/dev/null 2>&1 || die "后端镜像不存在: ${backend_target}"
docker image inspect "${frontend_target}" >/dev/null 2>&1 || die "前端镜像不存在: ${frontend_target}"

old_backend="${BACKEND_IMAGE:-xydh-nav-backend:latest}"
old_frontend="${FRONTEND_IMAGE:-xydh-nav-frontend:latest}"
rollback_env="${PROJECT_DIR}/.env.release-rollback-$(date -u +'%Y%m%d%H%M%S')-$$"
cp --preserve=mode,timestamps -- "${ENV_FILE}" "${rollback_env}"
chmod 0600 "${rollback_env}"

info "版本回滚前创建整站备份..."
SKIP_OPERATIONS_LOCK=1 "${OPS_DIR}/backup.sh" pre-release-rollback

update_image_refs() {
  ENV_UPDATE_FILE="${ENV_FILE}" ENV_BACKEND_IMAGE="$1" ENV_FRONTEND_IMAGE="$2" python3 <<'PY'
import os
from pathlib import Path

path = Path(os.environ["ENV_UPDATE_FILE"])
updates = {"BACKEND_IMAGE": os.environ["ENV_BACKEND_IMAGE"], "FRONTEND_IMAGE": os.environ["ENV_FRONTEND_IMAGE"]}
lines = path.read_text(encoding="utf-8").splitlines()
seen = set()
out = []
for line in lines:
    key = line.split("=", 1)[0] if "=" in line and not line.lstrip().startswith("#") else None
    if key in updates:
        out.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")
temp = path.with_name(path.name + ".tmp")
temp.write_text("\n".join(out) + "\n", encoding="utf-8")
os.chmod(temp, 0o600)
os.replace(temp, path)
PY
}

recover_previous_release() {
  local status=$?
  info "目标镜像未通过健康检查，正在恢复原镜像..."
  cp --preserve=mode,timestamps -- "${rollback_env}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  export BACKEND_IMAGE="${old_backend}"
  export FRONTEND_IMAGE="${old_frontend}"
  compose up -d --no-build backend frontend nginx || true
  rm -f -- "${rollback_env}"
  exit "${status}"
}
trap recover_previous_release ERR

update_image_refs "${backend_target}" "${frontend_target}"
export BACKEND_IMAGE="${backend_target}"
export FRONTEND_IMAGE="${frontend_target}"
compose up -d --no-build backend frontend nginx

for _ in $(seq 1 45); do
  backend_id="$(compose ps -q backend)"
  frontend_id="$(compose ps -q frontend)"
  nginx_id="$(compose ps -q nginx)"
  if [[ -n "${backend_id}" && -n "${frontend_id}" && -n "${nginx_id}" ]] &&
     [[ "$(docker inspect --format '{{.State.Health.Status}}' "${backend_id}")" == "healthy" ]] &&
     [[ "$(docker inspect --format '{{.State.Health.Status}}' "${frontend_id}")" == "healthy" ]] &&
     [[ "$(docker inspect --format '{{.State.Health.Status}}' "${nginx_id}")" == "healthy" ]]; then
    break
  fi
  sleep 2
done
[[ -n "${backend_id:-}" && -n "${frontend_id:-}" && -n "${nginx_id:-}" ]] ||
  die "回滚后的服务容器不完整"
[[ "$(docker inspect --format '{{.State.Health.Status}}' "${backend_id}")" == "healthy" ]] ||
  die "回滚后的后端未通过健康检查"
[[ "$(docker inspect --format '{{.State.Health.Status}}' "${frontend_id}")" == "healthy" ]] ||
  die "回滚后的前端未通过健康检查"
[[ "$(docker inspect --format '{{.State.Health.Status}}' "${nginx_id}")" == "healthy" ]] ||
  die "回滚后的 Nginx 未通过健康检查"
curl --fail --silent --show-error "http://127.0.0.1:${APP_PORT:-8080}/healthz" >/dev/null
curl --fail --silent --show-error "http://127.0.0.1:${APP_PORT:-8080}/api/health" >/dev/null

trap - ERR
rm -f -- "${rollback_env}"
info "代码回滚完成；数据库与上传卷未更换"
