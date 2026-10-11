#!/usr/bin/env bash
# Restore the stack volumes from a backup (local ./backups/<date> or Yandex Disk).
#
# Usage:
#   ./restore.sh                # latest available backup, asks for confirmation
#   ./restore.sh 2026-10-10     # specific date
#   ./restore.sh latest --yes   # no confirmation prompt
#
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

BACKUP_WEBDAV_URL="${BACKUP_WEBDAV_URL:-https://webdav.yandex.ru}"
BACKUP_WEBDAV_USER="${BACKUP_WEBDAV_USER:-}"
BACKUP_WEBDAV_PASS="${BACKUP_WEBDAV_PASS:-}"
BACKUP_WEBDAV_DIR="${BACKUP_WEBDAV_DIR:-selfhosted-backups}"

VOLUMES="pg_data sync_data vikunja_files"
BACKUP_ROOT="$(pwd)/backups"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- WebDAV helpers (same as backup.sh) -------------------------------------
webdav_curl() {
  local cfg
  cfg="$(printf '%s:%s' "$BACKUP_WEBDAV_USER" "$BACKUP_WEBDAV_PASS" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  curl -sS --max-time 3600 -K - <<<"user = \"$cfg\"" "$@"
}

base_url() { printf '%s/%s' "${BACKUP_WEBDAV_URL%/}" "${BACKUP_WEBDAV_DIR#/}"; }

webdav_list_dates() {
  webdav_curl -X PROPFIND -H "Depth: 1" "$(base_url)/" \
    | grep -oE '<[A-Za-z0-9]+:href>[^<]+' \
    | sed -E 's/<[A-Za-z0-9]+:href>//' \
    | awk -F'/' '{ print $(NF-1) }' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    || true
}

webdav_exists() { # $1 = path under backup dir, e.g. 2026-10-10/pg_data.tar.gz
  local code
  code="$(webdav_curl -o /dev/null -w '%{http_code}' -I "$(base_url)/$1")"
  [ "$code" = "200" ]
}

webdav_download() { # $1 = remote path, $2 = local target
  webdav_curl -o "$2" "$(base_url)/$1"
}

# --- Argument parsing --------------------------------------------------------
TARGET="${1:-latest}"
ASSUME_YES="${2:-}"

if [ "$TARGET" != "latest" ] && ! date -d "$TARGET" >/dev/null 2>&1; then
  die "'$TARGET' is not a valid date (expected YYYY-MM-DD or 'latest')."
fi

# --- Resolve backup date ------------------------------------------------------
latest_of() { sort -u | sort | tail -n1; }

if [ "$TARGET" = "latest" ]; then
  CANDIDATES="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' -printf '%f\n' 2>/dev/null || true)"
  if [ -n "$BACKUP_WEBDAV_USER" ] && [ -n "$BACKUP_WEBDAV_PASS" ]; then
    REMOTE_DATES="$(webdav_list_dates || true)"
    CANDIDATES="$(printf '%s\n%s' "$CANDIDATES" "$REMOTE_DATES")"
  fi
  TARGET="$(printf '%s\n' "$CANDIDATES" | latest_of || true)"
  [ -n "$TARGET" ] || die "No backups found locally in $BACKUP_ROOT nor remotely."
fi

echo "==> Restoring backup: $TARGET"

resolve_file() { # $1 = volume; echoes path to a local archive
  local v="$1"
  local plain="$BACKUP_ROOT/$TARGET/$v.tar.gz"
  if [ -f "$plain" ]; then echo "$plain"; return 0; fi
  if [ -z "$BACKUP_WEBDAV_USER" ] || [ -z "$BACKUP_WEBDAV_PASS" ]; then
    die "$plain not found locally and WebDAV is not configured in .env."
  fi
  echo "==> Downloading $v.tar.gz from $BACKUP_WEBDAV_DIR/$TARGET..." >&2
  mkdir -p "$BACKUP_ROOT/$TARGET"
  if webdav_exists "$TARGET/$v.tar.gz"; then
    webdav_download "$TARGET/$v.tar.gz" "$plain"
  else
    die "$v.tar.gz not found in $BACKUP_WEBDAV_DIR/$TARGET."
  fi
  echo "$plain"
}

declare -A FILES=()
for v in $VOLUMES; do
  FILES[$v]="$(resolve_file "$v")"
done

# --- Confirm ------------------------------------------------------------------
if [ "$ASSUME_YES" != "--yes" ]; then
  echo
  echo "The WHOLE stack will be stopped, volumes will be OVERWRITTEN with data from $TARGET:"
  for v in $VOLUMES; do
    echo "  ${v}: ${FILES[$v]}"
  done
  read -r -p "Continue? [y/N] " reply || reply=""
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Compose project name is fixed via `name:` in compose.yaml.
PROJ="selfhosted"

# --- Stop everything -----------------------------------------------------------
echo "==> Stopping the stack..."
$SUDO docker compose down

for v in $VOLUMES; do
  vol="${PROJ}_${v}"
  if ! $SUDO docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "==> Creating missing volume $vol"
    $SUDO docker volume create "$vol" >/dev/null
  fi
  src_dir="$(dirname "${FILES[$v]}")"
  src_name="$(basename "${FILES[$v]}")"
  echo "==> Restoring $vol from $src_name"
  $SUDO docker run --rm \
    -v "$vol":/data \
    -v "$src_dir":/src:ro \
    alpine sh -c "find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} + ; tar xzf '/src/$src_name' -C /data"
done

# Vikunja runs as uid 1000, and the extraction above ran as root: without
# this fix its files volume stays root-owned and vikunja fails with
# "storage validation failed ... permission denied".
echo "==> Fixing ownership of ${PROJ}_vikunja_files"
$SUDO docker run --rm -v "${PROJ}_vikunja_files":/data alpine \
  sh -c 'chown -R 1000:0 /data && chmod -R u+rwX,g+rwX /data'

echo "==> Starting the stack..."
$SUDO docker compose up -d
$SUDO docker compose ps

cat <<EOF

==> Done. Verify:
    docker compose ps                              # all Up, postgres healthy
    curl https://$VIKUNJA_DOMAIN/api/v1/info       # expect 200
    docker compose logs -f --tail=50 caddy logseq-sync vikunja
EOF
