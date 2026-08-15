#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# shellcheck source=ops/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

label="${1:-manual}"
validate_label "${label}"
assert_project_directory
require_command docker
require_command tar
require_command sha256sum
require_command python3
if [[ "${SKIP_OPERATIONS_LOCK:-0}" != "1" ]]; then
  acquire_operations_lock
fi
load_environment
require_embedded_database_operations
require_healthy_postgres

timestamp="$(date -u +'%Y%m%d-%H%M%S')"
backup_dir="${BACKUP_ROOT}/${label}-${timestamp}"
assert_path_within_backup_root "${backup_dir}"
install -d -m 0700 "${BACKUP_ROOT}" "${backup_dir}"

cleanup_failed_backup() {
  local status=$?
  if (( status != 0 )); then
    info "备份失败；未完成目录保留用于排查: ${backup_dir}"
  fi
  exit "${status}"
}
trap cleanup_failed_backup ERR

info "正在导出 PostgreSQL..."
postgres_exec pg_dump \
  --username "${POSTGRES_USER}" \
  --dbname "${POSTGRES_DB}" \
  --format custom \
  --compress 9 \
  --no-owner \
  --no-privileges >"${backup_dir}/database.dump"
chmod 0600 "${backup_dir}/database.dump"

info "正在归档上传卷..."
compose exec -T nginx tar -C /var/www/uploads -czf - . >"${backup_dir}/uploads-data.tar.gz"
chmod 0600 "${backup_dir}/uploads-data.tar.gz"

info "正在归档可构建源码..."
tar \
  --exclude='.env' \
  --exclude='.git' \
  --exclude='.codex*' \
  --exclude='node_modules' \
  --exclude='dist' \
  --exclude='target' \
  --exclude='coverage' \
  --exclude='*.log' \
  -czf "${backup_dir}/source.tar.gz" \
  -C "${PROJECT_DIR}" \
  .env.example .gitattributes .gitignore docker-compose.yml README.md jihua.md jiyi.md \
  database nginx nav-backend nav-frontend ops
chmod 0600 "${backup_dir}/source.tar.gz"

environment_encrypted=false
if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
  require_command age
  age --recipient "${BACKUP_AGE_RECIPIENT}" \
    --output "${backup_dir}/environment.env.age" "${ENV_FILE}"
  chmod 0600 "${backup_dir}/environment.env.age"
  environment_encrypted=true
fi

IFS='|' read -r user_count site_count category_count bookmark_count search_count custom_count < <(
  postgres_exec psql --no-psqlrc --tuples-only --no-align --field-separator='|' \
    --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
    --command "SELECT (SELECT count(*) FROM sys_user), (SELECT count(*) FROM site_config), (SELECT count(*) FROM nav_category), (SELECT count(*) FROM nav_bookmark), (SELECT count(*) FROM search_engine), (SELECT count(*) FROM custom_link);"
)

postgres_version="$(postgres_exec psql --no-psqlrc --tuples-only --no-align \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" --command 'SHOW server_version;')"
postgres_exec psql --no-psqlrc --tuples-only --no-align \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  --command "SELECT COALESCE(json_agg(row_to_json(m) ORDER BY filename), '[]'::json)::text FROM (SELECT filename, checksum, applied_at FROM schema_migration) AS m;" \
  >"${backup_dir}/schema-migrations.json"
chmod 0600 "${backup_dir}/schema-migrations.json"
backend_container="$(compose ps -q backend)"
frontend_container="$(compose ps -q frontend)"
postgres_container="$(compose ps -q postgres)"
redis_container="$(compose ps -q redis)"
nginx_container="$(compose ps -q nginx)"
backend_image_ref="$(docker inspect --format '{{.Config.Image}}' "${backend_container}")"
frontend_image_ref="$(docker inspect --format '{{.Config.Image}}' "${frontend_container}")"
postgres_image_ref="$(docker inspect --format '{{.Config.Image}}' "${postgres_container}")"
redis_image_ref="$(docker inspect --format '{{.Config.Image}}' "${redis_container}")"
nginx_image_ref="$(docker inspect --format '{{.Config.Image}}' "${nginx_container}")"
backend_image_id="$(docker inspect --format '{{.Image}}' "${backend_container}")"
frontend_image_id="$(docker inspect --format '{{.Image}}' "${frontend_container}")"
postgres_image_id="$(docker inspect --format '{{.Image}}' "${postgres_container}")"
redis_image_id="$(docker inspect --format '{{.Image}}' "${redis_container}")"
nginx_image_id="$(docker inspect --format '{{.Image}}' "${nginx_container}")"
upload_files="$(tar -tzf "${backup_dir}/uploads-data.tar.gz" | awk '!/\/$/ {count++} END {print count+0}')"

images_archived=false
if [[ "${BACKUP_INCLUDE_IMAGES:-0}" == "1" ]]; then
  require_command gzip
  info "正在归档离线容器镜像..."
  docker image save \
    "${postgres_image_id}" "${redis_image_id}" "${backend_image_id}" \
    "${frontend_image_id}" "${nginx_image_id}" \
    | gzip -9 >"${backup_dir}/images.tar.gz"
  chmod 0600 "${backup_dir}/images.tar.gz"
  images_archived=true
fi

export BACKUP_MANIFEST_PATH="${backup_dir}/manifest.json"
export BACKUP_CREATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
export BACKUP_LABEL="${label}"
export BACKUP_POSTGRES_VERSION="${postgres_version}"
export BACKUP_BACKEND_IMAGE_REF="${backend_image_ref}"
export BACKUP_FRONTEND_IMAGE_REF="${frontend_image_ref}"
export BACKUP_BACKEND_IMAGE_ID="${backend_image_id}"
export BACKUP_FRONTEND_IMAGE_ID="${frontend_image_id}"
export BACKUP_POSTGRES_IMAGE_REF="${postgres_image_ref}"
export BACKUP_REDIS_IMAGE_REF="${redis_image_ref}"
export BACKUP_NGINX_IMAGE_REF="${nginx_image_ref}"
export BACKUP_POSTGRES_IMAGE_ID="${postgres_image_id}"
export BACKUP_REDIS_IMAGE_ID="${redis_image_id}"
export BACKUP_NGINX_IMAGE_ID="${nginx_image_id}"
export BACKUP_IMAGES_ARCHIVED="${images_archived}"
export BACKUP_ENV_ENCRYPTED="${environment_encrypted}"
export BACKUP_USER_COUNT="${user_count}"
export BACKUP_SITE_COUNT="${site_count}"
export BACKUP_CATEGORY_COUNT="${category_count}"
export BACKUP_BOOKMARK_COUNT="${bookmark_count}"
export BACKUP_SEARCH_COUNT="${search_count}"
export BACKUP_CUSTOM_COUNT="${custom_count}"
export BACKUP_UPLOAD_FILES="${upload_files}"

python3 <<'PY'
import json
import os
from pathlib import Path

payload = {
    "formatVersion": 1,
    "createdAt": os.environ["BACKUP_CREATED_AT"],
    "label": os.environ["BACKUP_LABEL"],
    "database": {"engine": "postgresql", "version": os.environ["BACKUP_POSTGRES_VERSION"]},
    "images": {
        "backend": {"reference": os.environ["BACKUP_BACKEND_IMAGE_REF"], "id": os.environ["BACKUP_BACKEND_IMAGE_ID"]},
        "frontend": {"reference": os.environ["BACKUP_FRONTEND_IMAGE_REF"], "id": os.environ["BACKUP_FRONTEND_IMAGE_ID"]},
        "postgres": {"reference": os.environ["BACKUP_POSTGRES_IMAGE_REF"], "id": os.environ["BACKUP_POSTGRES_IMAGE_ID"]},
        "redis": {"reference": os.environ["BACKUP_REDIS_IMAGE_REF"], "id": os.environ["BACKUP_REDIS_IMAGE_ID"]},
        "nginx": {"reference": os.environ["BACKUP_NGINX_IMAGE_REF"], "id": os.environ["BACKUP_NGINX_IMAGE_ID"]},
    },
    "imagesArchived": os.environ["BACKUP_IMAGES_ARCHIVED"] == "true",
    "environmentEncrypted": os.environ["BACKUP_ENV_ENCRYPTED"] == "true",
    "counts": {
        "users": int(os.environ["BACKUP_USER_COUNT"]),
        "siteConfigs": int(os.environ["BACKUP_SITE_COUNT"]),
        "categories": int(os.environ["BACKUP_CATEGORY_COUNT"]),
        "bookmarks": int(os.environ["BACKUP_BOOKMARK_COUNT"]),
        "searchEngines": int(os.environ["BACKUP_SEARCH_COUNT"]),
        "customLinks": int(os.environ["BACKUP_CUSTOM_COUNT"]),
        "uploadFiles": int(os.environ["BACKUP_UPLOAD_FILES"]),
    },
}
Path(os.environ["BACKUP_MANIFEST_PATH"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY
chmod 0600 "${backup_dir}/manifest.json"

(
  cd -- "${backup_dir}"
  find . -maxdepth 1 -type f ! -name checksums.sha256 -printf '%P\0' \
    | sort -z \
    | xargs -0 sha256sum >checksums.sha256
  chmod 0600 checksums.sha256
)

SKIP_OPERATIONS_LOCK=1 "${OPS_DIR}/verify-backup.sh" "${backup_dir}"
trap - ERR
info "BACKUP_DIR=${backup_dir}"
