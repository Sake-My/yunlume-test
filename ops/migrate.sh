#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# shellcheck source=ops/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

assert_project_directory
require_command sha256sum
require_command sort
acquire_operations_lock
load_environment
require_embedded_database_operations
require_healthy_postgres

migration_dir="${PROJECT_DIR}/database/migrations"
[[ -d "${migration_dir}" ]] || die "缺少 PostgreSQL 迁移目录"

postgres_exec psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migration (
    filename VARCHAR(255) PRIMARY KEY,
    checksum CHAR(64) NOT NULL,
    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
SQL

mapfile -d '' migrations < <(find "${migration_dir}" -maxdepth 1 -type f -name '*.sql' -print0 | sort -z)
(( ${#migrations[@]} > 0 )) || die "PostgreSQL 迁移目录为空"

pending=()
for file in "${migrations[@]}"; do
  filename="$(basename -- "${file}")"
  [[ "${filename}" =~ ^[0-9]{8}_[0-9]{4}_[a-z0-9_]+\.sql$ ]] ||
    die "迁移文件名不符合约定: ${filename}"
  checksum="$(sha256_file "${file}")"
  recorded="$(postgres_exec psql --no-psqlrc --tuples-only --no-align \
    --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
    --command "SELECT checksum FROM schema_migration WHERE filename = '${filename}';")"
  if [[ -n "${recorded}" ]]; then
    [[ "${recorded}" == "${checksum}" ]] || die "已执行迁移被修改: ${filename}"
  else
    pending+=("${file}")
  fi
done

if (( ${#pending[@]} == 0 )); then
  info "没有待执行的 PostgreSQL 迁移"
  exit 0
fi

info "执行迁移前强制创建整站备份..."
SKIP_OPERATIONS_LOCK=1 "${OPS_DIR}/backup.sh" pre-migration

for file in "${pending[@]}"; do
  filename="$(basename -- "${file}")"
  checksum="$(sha256_file "${file}")"
  info "正在执行 ${filename}"
  {
    printf "SET lock_timeout = '15s';\nSET statement_timeout = '10min';\n"
    cat -- "${file}"
    printf "\nINSERT INTO schema_migration(filename, checksum) VALUES ('%s', '%s');\n" \
      "${filename}" "${checksum}"
  } | postgres_exec psql --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction \
      --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" --file - >/dev/null
done

info "PostgreSQL 迁移完成: ${#pending[@]} 个"
