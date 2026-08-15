#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# shellcheck source=ops/lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

[[ $# -eq 1 ]] || die "用法: $0 /opt/xy-navigation-backups/<备份目录>"
assert_project_directory
require_command sha256sum
require_command python3
require_command docker
if [[ "${SKIP_OPERATIONS_LOCK:-0}" != "1" ]]; then
  acquire_operations_lock
fi

backup_dir="$(realpath -e "$1")"
assert_path_within_backup_root "${backup_dir}"
[[ -d "${backup_dir}" ]] || die "备份目录不存在"
for required in manifest.json checksums.sha256 database.dump uploads-data.tar.gz source.tar.gz; do
  [[ -f "${backup_dir}/${required}" ]] || die "备份缺少 ${required}"
done

(
  cd -- "${backup_dir}"
  sha256sum --check --strict checksums.sha256
)

python3 - "${backup_dir}" <<'PY'
import json
import os
import sys
import tarfile
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
if manifest.get("formatVersion") != 1:
    raise SystemExit("不支持的整站备份格式版本")
if manifest.get("database", {}).get("engine") != "postgresql":
    raise SystemExit("备份数据库类型不是 PostgreSQL")
if manifest.get("environmentEncrypted") and not (root / "environment.env.age").is_file():
    raise SystemExit("manifest 声明包含加密环境文件，但文件缺失")
if manifest.get("imagesArchived") and not (root / "images.tar.gz").is_file():
    raise SystemExit("manifest 声明包含离线镜像，但文件缺失")

def verify_tar(path: Path, allow_links: bool) -> None:
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            name = member.name.replace("\\", "/")
            parsed = PurePosixPath(name)
            if parsed.is_absolute() or ".." in parsed.parts or not name or "\x00" in name:
                raise SystemExit(f"归档包含不安全路径: {name!r}")
            if not allow_links and (member.issym() or member.islnk()):
                raise SystemExit(f"上传归档不得包含链接: {name!r}")

verify_tar(root / "uploads-data.tar.gz", allow_links=False)
verify_tar(root / "source.tar.gz", allow_links=False)

for path in root.iterdir():
    if path.is_file() and (path.stat().st_mode & 0o077):
        raise SystemExit(f"备份文件权限过宽: {path.name}")
if root.stat().st_mode & 0o077:
    raise SystemExit("备份目录权限过宽")
PY

load_environment
postgres_image="$(resolve_trusted_postgres_image "${backup_dir}")"
verify_container="xydh-nav-backup-verify-$(date -u +'%Y%m%d%H%M%S')-$$"
[[ "${verify_container}" =~ ^xydh-nav-backup-verify-[0-9]{14}-[0-9]+$ ]] ||
  die "备份校验容器名无效"

cleanup_verify_container() {
  local status=$?
  trap - EXIT
  if docker container inspect "${verify_container}" >/dev/null 2>&1; then
    [[ "$(docker inspect --format '{{index .Config.Labels "xydh-nav.backup-verify"}}' "${verify_container}")" == "true" ]] ||
      die "拒绝清理标签不匹配的备份校验容器"
    docker rm -f "${verify_container}" >/dev/null
  fi
  exit "${status}"
}
trap cleanup_verify_container EXIT

docker run -i \
  --name "${verify_container}" \
  --label xydh-nav.backup-verify=true \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  "${postgres_image}" pg_restore --list \
  <"${backup_dir}/database.dump" >/dev/null

docker rm "${verify_container}" >/dev/null
trap - EXIT

info "备份校验通过: ${backup_dir}"
