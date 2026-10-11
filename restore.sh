#!/usr/bin/env bash
# Restore stack data volumes from a daily backup folder: ./restore.sh 2026-10-24
# The folder must exist under BACKUP_ROOT (default ~/backup) and contain the
# tar.gz archives produced by backup.sh. Stack should already be deployed
# (see install.sh): volumes are recreated in place.
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backup}"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <YYYY-MM-DD>   (backup folder inside $BACKUP_ROOT)" >&2
  exit 1
fi

DATE="$1"
SRC="$BACKUP_ROOT/$DATE"

cd "$(dirname "$0")"
[ -d "$SRC" ] || { echo "ERROR: backup folder $SRC not found" >&2; exit 1; }

readonly -a SERVICES=(logseq-sync vikunja postgres)
# Named volumes to restore as "<volume>:<archive-name>" (must match backup.sh).
readonly -a VOLUMES=(
  "selfhosted_sync_data:sync_data.tar.gz"
  "selfhosted_vikunja_files:vikunja_files.tar.gz"
  "selfhosted_pg_data:pg_data.tar.gz"
)

stack_up() {
  # Never leave the stack down, whatever happened above.
  docker compose up -d "${SERVICES[@]}" >/dev/null || true
}
trap stack_up EXIT

echo "==> $(date '+%F %T') stopping services: ${SERVICES[*]}"
docker compose stop "${SERVICES[@]}" >/dev/null

fail=0
for entry in "${VOLUMES[@]}"; do
  vol="${entry%%:*}"
  name="${entry##*:}"
  archive="$SRC/$name"
  if [ ! -s "$archive" ]; then
    echo "==> WARNING: $archive missing or empty, volume $vol left untouched" >&2
    fail=1
    continue
  fi
  echo "==> restoring $vol from $name"
  docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create "$vol" >/dev/null
  # Wipe the volume (including dotfiles), then unpack the snapshot.
  docker run --rm \
    -e ARCHIVE="$name" \
    -v "$vol:/data" \
    -v "$SRC:/backup:ro" \
    alpine sh -c 'rm -rf /data/* /data/..?* /data/.[!.]* && tar --numeric-owner -xzf "/backup/$ARCHIVE" -C /data'
done

if [ "$fail" -eq 0 ]; then
  echo "==> $(date '+%F %T') restore finished, starting stack"
else
  echo "==> $(date '+%F %T') restore finished WITH WARNINGS, starting stack anyway" >&2
fi
