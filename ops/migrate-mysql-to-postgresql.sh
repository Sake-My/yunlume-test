#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# One-time, data-preserving migration for an existing xydh-nav MySQL container.
# The source container and its volume are never modified or removed.

# shellcheck source=ops/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

[[ "${CONFIRM_MIGRATION:-}" == "MYSQL-TO-POSTGRESQL" ]] ||
  die "请显式设置 CONFIRM_MIGRATION=MYSQL-TO-POSTGRESQL"
assert_project_directory
require_command docker
require_command python3
require_command sha256sum
acquire_operations_lock
load_environment
require_embedded_database_operations
require_healthy_postgres

legacy_container="${LEGACY_MYSQL_CONTAINER:-xydh-nav-mysql-1}"
source_project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "${legacy_container}" 2>/dev/null || true)"
source_service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "${legacy_container}" 2>/dev/null || true)"
[[ "${source_project}" == "${COMPOSE_PROJECT_NAME}" && "${source_service}" == "mysql" ]] ||
  die "MySQL 来源容器不属于 xydh-nav/mysql: ${legacy_container}"

target_container="$(postgres_container_id)"
target_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "${target_container}")"
[[ -n "${target_volume}" ]] || die "无法确定 PostgreSQL 数据卷"
target_volume_project="$(docker volume inspect --format '{{index .Labels "com.docker.compose.project"}}' "${target_volume}")"
target_volume_key="$(docker volume inspect --format '{{index .Labels "com.docker.compose.volume"}}' "${target_volume}")"
[[ "${target_volume_project}" == "${COMPOSE_PROJECT_NAME}" && "${target_volume_key}" == "postgres_data" ]] ||
  die "拒绝覆盖不属于 xydh-nav/postgres_data 的卷: ${target_volume}"
[[ "${target_volume}" != "xydh-nav_mysql_data" ]] || die "PostgreSQL 不能复用 MySQL 数据卷"

# This is a one-time cutover, not a general restore command.  A freshly
# initialized target contains demo navigation rows but no administrator.  Once
# migration has succeeded, sys_user is non-empty and an accidental rerun must
# stop before TRUNCATE.  A deliberately rebuilt target can opt in explicitly.
target_user_count="$(postgres_exec psql --no-psqlrc --tuples-only --no-align \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  --command 'SELECT count(*) FROM sys_user;')"
if [[ "${target_user_count}" != "0" && "${ALLOW_NONEMPTY_POSTGRES_TARGET:-0}" != "1" ]]; then
  die "目标 PostgreSQL 已包含管理员数据；拒绝重复迁移（确需覆盖时显式设置 ALLOW_NONEMPTY_POSTGRES_TARGET=1）"
fi

legacy_database=""
legacy_user=""
legacy_password=""
legacy_root_password=""
while IFS='=' read -r key value; do
  case "${key}" in
    MYSQL_DATABASE) legacy_database="${value}" ;;
    MYSQL_USER) legacy_user="${value}" ;;
    MYSQL_PASSWORD) legacy_password="${value}" ;;
    MYSQL_ROOT_PASSWORD) legacy_root_password="${value}" ;;
  esac
done < <(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${legacy_container}")
: "${legacy_database:?来源容器缺少 MYSQL_DATABASE}"
: "${legacy_user:?来源容器缺少 MYSQL_USER}"
: "${legacy_password:?来源容器缺少 MYSQL_PASSWORD}"
: "${legacy_root_password:?来源容器缺少 MYSQL_ROOT_PASSWORD}"

batch="$(date -u +'%Y%m%d-%H%M%S')"
migration_dir="${BACKUP_ROOT}/mysql-to-postgresql-${batch}"
assert_path_within_backup_root "${migration_dir}"
install -d -m 0700 "${BACKUP_ROOT}" "${migration_dir}"

info "正在生成只读 MySQL 迁移前备份..."
docker exec -e "MYSQL_PWD=${legacy_root_password}" "${legacy_container}" \
  mysqldump --single-transaction --routines --events --triggers --hex-blob \
  --set-gtid-purged=OFF --default-character-set=utf8mb4 \
  -uroot "${legacy_database}" >"${migration_dir}/mysql-before.sql"
chmod 0600 "${migration_dir}/mysql-before.sql"

mysql_json_query() {
  local output="$1"
  local query="$2"
  docker exec -e "MYSQL_PWD=${legacy_password}" "${legacy_container}" \
    mysql --default-character-set=utf8mb4 --batch --raw --skip-column-names \
    -u "${legacy_user}" "${legacy_database}" --execute "${query}" >"${migration_dir}/${output}.jsonl"
  chmod 0600 "${migration_dir}/${output}.jsonl"
}

mysql_json_query sys_user "SELECT JSON_OBJECT('id',id,'username',username,'password',password,'nickname',nickname,'avatar',avatar,'role',role,'status',status,'token_version',token_version,'created_at',DATE_FORMAT(created_at,'%Y-%m-%d %H:%i:%s.%f'),'updated_at',DATE_FORMAT(updated_at,'%Y-%m-%d %H:%i:%s.%f')) FROM sys_user ORDER BY id"
mysql_json_query site_config "SELECT JSON_OBJECT('id',id,'site_name',site_name,'site_description',site_description,'publish_url',publish_url,'background_type',background_type,'background_color',background_color,'background_image',background_image,'mobile_background_image',mobile_background_image,'font_color',font_color,'background_effect',background_effect,'music_enabled',music_enabled,'music_url',music_url,'subscribe_enabled',subscribe_enabled,'top_content_enabled',top_content_enabled,'message_text',message_text,'version',version,'created_at',DATE_FORMAT(created_at,'%Y-%m-%d %H:%i:%s.%f'),'updated_at',DATE_FORMAT(updated_at,'%Y-%m-%d %H:%i:%s.%f')) FROM site_config ORDER BY id"
mysql_json_query nav_category "SELECT JSON_OBJECT('id',id,'name',name,'icon',icon,'sort_order',sort_order,'visible',visible,'created_at',DATE_FORMAT(created_at,'%Y-%m-%d %H:%i:%s.%f'),'updated_at',DATE_FORMAT(updated_at,'%Y-%m-%d %H:%i:%s.%f')) FROM nav_category ORDER BY id"
mysql_json_query nav_bookmark "SELECT JSON_OBJECT('id',id,'category_id',category_id,'name',name,'url',url,'icon',icon,'description',description,'sort_order',sort_order,'is_recommend',is_recommend,'is_external',is_external,'visible',visible,'created_at',DATE_FORMAT(created_at,'%Y-%m-%d %H:%i:%s.%f'),'updated_at',DATE_FORMAT(updated_at,'%Y-%m-%d %H:%i:%s.%f')) FROM nav_bookmark ORDER BY id"
mysql_json_query search_engine "SELECT JSON_OBJECT('id',id,'name',name,'icon',icon,'search_url',search_url,'placeholder',placeholder,'is_default',is_default,'sort_order',sort_order,'visible',visible,'created_at',DATE_FORMAT(created_at,'%Y-%m-%d %H:%i:%s.%f'),'updated_at',DATE_FORMAT(updated_at,'%Y-%m-%d %H:%i:%s.%f')) FROM search_engine ORDER BY id"
mysql_json_query custom_link "SELECT JSON_OBJECT('id',id,'title',title,'url',url,'position',position,'sort_order',sort_order,'visible',visible,'created_at',DATE_FORMAT(created_at,'%Y-%m-%d %H:%i:%s.%f'),'updated_at',DATE_FORMAT(updated_at,'%Y-%m-%d %H:%i:%s.%f')) FROM custom_link ORDER BY id"

export MIGRATION_DIR="${migration_dir}"
python3 <<'PY'
import hashlib
import json
import os
from datetime import datetime
from pathlib import Path

root = Path(os.environ["MIGRATION_DIR"])
specs = {
    "sys_user": {
        "columns": "id,username,password,nickname,avatar,role,status,token_version,created_at,updated_at",
        "types": "id bigint, username text, password text, nickname text, avatar text, role text, status boolean, token_version integer, created_at timestamp, updated_at timestamp",
        "bools": ["status"],
    },
    "site_config": {
        "columns": "id,site_name,site_description,publish_url,background_type,background_color,background_image,mobile_background_image,font_color,background_effect,music_enabled,music_url,subscribe_enabled,top_content_enabled,message_text,version,created_at,updated_at",
        "types": "id bigint, site_name text, site_description text, publish_url text, background_type text, background_color text, background_image text, mobile_background_image text, font_color text, background_effect boolean, music_enabled boolean, music_url text, subscribe_enabled boolean, top_content_enabled boolean, message_text text, version integer, created_at timestamp, updated_at timestamp",
        "bools": ["background_effect", "music_enabled", "subscribe_enabled", "top_content_enabled"],
    },
    "nav_category": {
        "columns": "id,name,icon,sort_order,visible,created_at,updated_at",
        "types": "id bigint, name text, icon text, sort_order integer, visible boolean, created_at timestamp, updated_at timestamp",
        "bools": ["visible"],
    },
    "nav_bookmark": {
        "columns": "id,category_id,name,url,icon,description,sort_order,is_recommend,is_external,visible,created_at,updated_at",
        "types": "id bigint, category_id bigint, name text, url text, icon text, description text, sort_order integer, is_recommend boolean, is_external boolean, visible boolean, created_at timestamp, updated_at timestamp",
        "bools": ["is_recommend", "is_external", "visible"],
    },
    "search_engine": {
        "columns": "id,name,icon,search_url,placeholder,is_default,sort_order,visible,created_at,updated_at",
        "types": "id bigint, name text, icon text, search_url text, placeholder text, is_default boolean, sort_order integer, visible boolean, created_at timestamp, updated_at timestamp",
        "bools": ["is_default", "visible"],
    },
    "custom_link": {
        "columns": "id,title,url,position,sort_order,visible,created_at,updated_at",
        "types": "id bigint, title text, url text, position text, sort_order integer, visible boolean, created_at timestamp, updated_at timestamp",
        "bools": ["visible"],
    },
}

def read_rows(table, spec):
    rows = []
    for line in (root / f"{table}.jsonl").read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        row = json.loads(line)
        for key in spec["bools"]:
            row[key] = bool(row[key])
        for key in ("created_at", "updated_at"):
            if row.get(key):
                row[key] = datetime.fromisoformat(row[key]).strftime("%Y-%m-%d %H:%M:%S.%f")
        rows.append(row)
    return rows

all_rows = {table: read_rows(table, spec) for table, spec in specs.items()}
source_digest = hashlib.sha256(
    json.dumps(all_rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
(root / "source-data.sha256").write_text(source_digest + "\n", encoding="ascii")

sql = [
    "SET lock_timeout = '15s';",
    "SET statement_timeout = '5min';",
    "TRUNCATE TABLE nav_bookmark, nav_category, search_engine, custom_link, site_config, sys_user RESTART IDENTITY CASCADE;",
]
for table, spec in specs.items():
    rows_json = json.dumps(all_rows[table], ensure_ascii=False, separators=(",", ":")).replace("'", "''")
    sql.append(
        f"INSERT INTO {table} ({spec['columns']}) "
        f"SELECT {spec['columns']} FROM jsonb_to_recordset('{rows_json}'::jsonb) AS x({spec['types']});"
    )
for table in specs:
    sql.append(
        f"SELECT setval(pg_get_serial_sequence('{table}','id'), "
        f"COALESCE((SELECT max(id) FROM {table}), 1), EXISTS(SELECT 1 FROM {table}));"
    )
sql.append(
    "DO $$ BEGIN IF (SELECT count(*) FROM site_config) <> 1 THEN "
    "RAISE EXCEPTION 'site_config must contain exactly one row'; END IF; END $$;"
)
sql.append(
    "DO $$ BEGIN IF (SELECT count(*) FROM search_engine WHERE visible IS TRUE AND is_default IS TRUE) <> 1 THEN "
    "RAISE EXCEPTION 'exactly one visible default search engine is required'; END IF; END $$;"
)
(root / "postgres-import.sql").write_text("\n".join(sql) + "\n", encoding="utf-8")
PY
chmod 0600 "${migration_dir}/postgres-import.sql" "${migration_dir}/source-data.sha256"

info "正在把业务数据原子写入新的 PostgreSQL 卷..."
postgres_exec psql --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
  --file - <"${migration_dir}/postgres-import.sql" >/dev/null

for table in sys_user site_config nav_category nav_bookmark search_engine custom_link; do
  postgres_exec psql --no-psqlrc --tuples-only --no-align \
    --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
    --command "SELECT row_to_json(t)::text FROM (SELECT * FROM ${table} ORDER BY id) AS t;" \
    >"${migration_dir}/postgres-${table}.jsonl"
  chmod 0600 "${migration_dir}/postgres-${table}.jsonl"
done

python3 <<'PY'
import hashlib
import json
import os
from datetime import datetime
from pathlib import Path

root = Path(os.environ["MIGRATION_DIR"])
bools = {
    "sys_user": ["status"],
    "site_config": ["background_effect", "music_enabled", "subscribe_enabled", "top_content_enabled"],
    "nav_category": ["visible"],
    "nav_bookmark": ["is_recommend", "is_external", "visible"],
    "search_engine": ["is_default", "visible"],
    "custom_link": ["visible"],
}

def normalize_timestamp(value):
    if not value:
        return value
    return datetime.fromisoformat(value.replace("Z", "+00:00")).replace(tzinfo=None).strftime(
        "%Y-%m-%d %H:%M:%S.%f"
    )

source = {}
target = {}
for table, boolean_fields in bools.items():
    source_rows = []
    for line in (root / f"{table}.jsonl").read_text(encoding="utf-8").splitlines():
        if line:
            row = json.loads(line)
            for key in boolean_fields:
                row[key] = bool(row[key])
            row["created_at"] = normalize_timestamp(row.get("created_at"))
            row["updated_at"] = normalize_timestamp(row.get("updated_at"))
            source_rows.append(row)
    target_rows = []
    for line in (root / f"postgres-{table}.jsonl").read_text(encoding="utf-8").splitlines():
        if line:
            row = json.loads(line)
            row["created_at"] = normalize_timestamp(row.get("created_at"))
            row["updated_at"] = normalize_timestamp(row.get("updated_at"))
            target_rows.append(row)
    source[table] = source_rows
    target[table] = target_rows
if source != target:
    for table in source:
        if source[table] != target[table]:
            print(f"数据不一致: {table}")
    raise SystemExit(1)
digest = hashlib.sha256(
    json.dumps(target, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
expected = (root / "source-data.sha256").read_text(encoding="ascii").strip()
if digest != expected:
    raise SystemExit("迁移数据摘要不一致")
(root / "postgres-data.sha256").write_text(digest + "\n", encoding="ascii")
PY
chmod 0600 "${migration_dir}/postgres-data.sha256"

(
  cd -- "${migration_dir}"
  find . -maxdepth 1 -type f ! -name checksums.sha256 -printf '%P\0' \
    | sort -z \
    | xargs -0 sha256sum >checksums.sha256
  chmod 0600 checksums.sha256
  sha256sum --check --strict checksums.sha256 >/dev/null
)

info "MySQL → PostgreSQL 迁移及逐表数据比较通过"
info "MIGRATION_BACKUP_DIR=${migration_dir}"
info "SOURCE_MYSQL_CONTAINER=${legacy_container}（未修改、未删除）"
info "TARGET_POSTGRES_VOLUME=${target_volume}"
