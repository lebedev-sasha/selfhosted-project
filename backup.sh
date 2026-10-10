#!/usr/bin/env bash
# Backup of the stack volumes to a local dir + Yandex Disk (WebDAV).
# Scheduled by systemd/backup.timer; can also be run manually: ./backup.sh
# Requires .env with BACKUP_WEBDAV_* in the project directory (see README).
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# --- Settings (defaults can be overridden in .env) --------------------------
BACKUP_WEBDAV_URL="${BACKUP_WEBDAV_URL:-https://webdav.yandex.ru}"
BACKUP_WEBDAV_USER="${BACKUP_WEBDAV_USER:-}"
BACKUP_WEBDAV_PASS="${BACKUP_WEBDAV_PASS:-}"
BACKUP_WEBDAV_DIR="${BACKUP_WEBDAV_DIR:-selfhosted-backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

if [ -z "$BACKUP_WEBDAV_USER" ] || [ -z "$BACKUP_WEBDAV_PASS" ]; then
  echo "ERROR: BACKUP_WEBDAV_USER/BACKUP_WEBDAV_PASS are not set in .env." >&2
  echo "       Fill them in (see README 'Backups') and re-run ./install.sh." >&2
  exit 1
fi

VOLUMES="pg_data sync_data vikunja_files"
SERVICES="postgres logseq-sync"
DATE="$(date +%F)"
BACKUP_ROOT="$(pwd)/backups"
BACKUP_DIR="$BACKUP_ROOT/$DATE"
LOG_FILE="$BACKUP_ROOT/backup.log"

mkdir -p "$BACKUP_DIR"

log() {
  local msg="[$(date '+%F %T')] $*"
  echo "$msg"
  echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
  command -v logger >/dev/null 2>&1 && logger -t backup "$*" >/dev/null 2>&1 || true
}

# --- WebDAV helpers ---------------------------------------------------------
# Credentials are passed to curl via a config read from stdin (-K -),
# so they never appear in `ps` output.
webdav_curl() {
  local cfg
  cfg="$(printf '%s:%s' "$BACKUP_WEBDAV_USER" "$BACKUP_WEBDAV_PASS" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  curl -sS --max-time 3600 -K - <<<"user = \"$cfg\"" "$@"
}

base_url() { printf '%s/%s' "${BACKUP_WEBDAV_URL%/}" "${BACKUP_WEBDAV_DIR#/}"; }

webdav_mkcol_parents() {
  local remote="" part
  local IFS='/'
  for part in $BACKUP_WEBDAV_DIR; do
    [ -n "$part" ] || continue
    remote="$remote/$part"
    # 405 Method Not Allowed = already exists, that's fine
    webdav_curl -o /dev/null -X MKCOL "${BACKUP_WEBDAV_URL%/}$remote" || true
  done
  webdav_curl -o /dev/null -X MKCOL "$(base_url)/$DATE" || true
}

webdav_upload() { # $1 = local file
  local file="$1" name
  name="$(basename "$file")"
  local url local_size remote_size attempt
  url="$(base_url)/$DATE/$name"
  local_size="$(stat -c%s "$file")"
  for attempt in 1 2 3; do
    log "Uploading $name (attempt $attempt/3, ${local_size} bytes)..."
    if webdav_curl -T "$file" "$url"; then
      remote_size="$(webdav_curl -sI "$url" | tr -d '\r' \
        | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' | tail -n1)"
      if [ -n "$remote_size" ] && [ "$remote_size" != "$local_size" ]; then
        log "WARNING: size mismatch for $name (local $local_size, remote $remote_size), retrying..."
      else
        if [ -z "$remote_size" ]; then
          log "WARNING: could not verify $name via HEAD (no Content-Length), assuming OK."
        fi
        return 0
      fi
    else
      log "WARNING: upload of $name failed, retrying..."
    fi
    sleep 5
  done
  log "ERROR: upload of $name failed after 3 attempts."
  return 1
}

webdav_list_dates() { # prints YYYY-MM-DD dirs present in the remote backup dir
  webdav_curl -X PROPFIND -H "Depth: 1" "$(base_url)/" \
    | grep -oE '<[A-Za-z0-9]+:href>[^<]+' \
    | sed -E 's/<[A-Za-z0-9]+:href>//' \
    | awk -F'/' '{ print $(NF-1) }' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    || true
}

webdav_delete_dir() {
  webdav_curl -o /dev/null -X DELETE "$(base_url)/$1" || true
}

# --- Retention: keep the newest <BACKUP_RETENTION_DAYS> daily backups -------
retention_local() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' | sort \
    | head -n -"$BACKUP_RETENTION_DAYS" \
    | while read -r dir; do
        rm -rf "$dir"
        log "Retention: removed local $(basename "$dir")"
      done
}

retention_remote() {
  webdav_list_dates | sort | head -n -"$BACKUP_RETENTION_DAYS" | while read -r d; do
    webdav_delete_dir "$d"
    log "Retention: removed remote $d"
  done
}

# --- Main -------------------------------------------------------------------
SERVICES_STOPPED=0
UPLOADED=0

finish() {
  local rc=$?
  trap - EXIT
  if [ "$SERVICES_STOPPED" -eq 1 ]; then
    log "Starting services back..."
    # shellcheck disable=SC2086
    if $SUDO docker compose start $SERVICES; then
      SERVICES_STOPPED=0
    else
      log "ERROR: failed to restart services, run manually: docker compose start $SERVICES"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    log "Backup OK: $UPLOADED file(s) uploaded to ${BACKUP_WEBDAV_DIR}/$DATE"
  else
    log "Backup FAILED (exit code $rc)"
  fi
  exit "$rc"
}
trap finish EXIT

# Compose project name is fixed via `name:` in compose.yaml.
PROJ="selfhosted"

# Check volumes exist BEFORE stopping services to keep downtime minimal.
for v in $VOLUMES; do
  if [ -z "$($SUDO docker volume ls -q "${PROJ}_${v}")" ]; then
    log "ERROR: volume ${PROJ}_${v} not found (docker volume ls). Is the stack up?"
    exit 1
  fi
done

log "=== Backup started ($DATE) ==="
# Mark as stopped BEFORE stopping so the EXIT trap restarts services
# even if `compose stop` itself fails midway.
SERVICES_STOPPED=1
log "Stopping services: $SERVICES"
# shellcheck disable=SC2086
$SUDO docker compose stop $SERVICES

for v in $VOLUMES; do
  log "Archiving volume ${PROJ}_${v}..."
  $SUDO docker run --rm \
    -v "${PROJ}_${v}":/data:ro \
    -v "$BACKUP_DIR":/backup \
    alpine tar czf "/backup/${v}.tar.gz" -C /data .
done

log "Starting services: $SERVICES"
# shellcheck disable=SC2086
$SUDO docker compose start $SERVICES
SERVICES_STOPPED=0

FILES=()
for v in $VOLUMES; do
  FILES+=("$BACKUP_DIR/${v}.tar.gz")
done

webdav_mkcol_parents
for f in "${FILES[@]}"; do
  webdav_upload "$f"
  UPLOADED=$((UPLOADED + 1))
done

retention_local
retention_remote
log "=== Backup finished ==="
