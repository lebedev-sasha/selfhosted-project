#!/usr/bin/env bash
# Daily backup of stack data volumes into ~/backup/YYYY-MM-DD/.
# Stops data-holding services, snapshots volumes as tar.gz, starts them back.
# Intended to run from cron (see install.sh); user must be in the docker group.
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backup}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

cd "$(dirname "$0")"

# Services with data: stopped during the snapshot, restarted on exit.
readonly -a SERVICES=(logseq-sync vikunja postgres)
# Named volumes to snapshot as "<volume>:<archive-name>" (project name: selfhosted).
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

DATE="$(date +%F)"
DEST="$BACKUP_ROOT/$DATE"
mkdir -p "$DEST"
chmod 700 "$BACKUP_ROOT" "$DEST"

# Prevent overlapping runs (slow backup vs the next cron tick).
exec 9>"$BACKUP_ROOT/.lock"
flock -n 9 || { echo "ERROR: another backup is already running" >&2; exit 1; }

echo "==> $(date '+%F %T') stopping services: ${SERVICES[*]}"
docker compose stop "${SERVICES[@]}" >/dev/null

fail=0
for entry in "${VOLUMES[@]}"; do
  vol="${entry%%:*}"
  archive="$DEST/${entry##*:}"
  echo "==> $vol -> $archive"
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "    ERROR: volume not found, skipped" >&2
    fail=1
    continue
  fi
  if docker run --rm \
      -v "$vol:/src:ro" \
      -v "$DEST:/backup" \
      alpine tar --numeric-owner -czf "/backup/${archive##*/}" -C /src .; then
    size="$(stat -c '%s' "$archive" 2>/dev/null || echo 0)"
    if [ "$size" -gt 0 ]; then
      echo "    ok ($((size / 1024)) KiB)"
    else
      echo "    ERROR: archive is empty" >&2
      fail=1
    fi
  else
    echo "    ERROR: tar failed" >&2
    fail=1
  fi
done

echo "==> pruning backups older than $RETENTION_DAYS days"
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' \
  -mtime "+$RETENTION_DAYS" -exec rm -rf {} +

if [ "$fail" -eq 0 ]; then
  echo "==> $(date '+%F %T') backup finished: $DEST"
else
  echo "==> $(date '+%F %T') backup finished WITH ERRORS (see log above)" >&2
  exit 1
fi
