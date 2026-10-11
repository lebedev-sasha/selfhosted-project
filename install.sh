#!/usr/bin/env bash
# Bootstrap for a fresh Debian/Ubuntu VPS: installs Docker and starts the stack.
# Run from the project directory with a filled-in .env (see README).
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker Engine + compose plugin..."
  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian) DOCKER_URL="https://download.docker.com/linux/debian" ;;
    ubuntu) DOCKER_URL="https://download.docker.com/linux/ubuntu" ;;
    *) echo "ERROR: unsupported distro '${ID:-unknown}'. Install Docker manually." >&2; exit 1 ;;
  esac
  $SUDO curl -fsSL "$DOCKER_URL/gpg" -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] $DOCKER_URL $VERSION_CODENAME stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "==> Docker already installed, skipping."
fi

echo "==> Starting stack..."
$SUDO docker compose up -d

# Vikunja runs as uid 1000, but the root of its files volume can end up
# root-owned (Docker copies ownership from the image on first init; restore
# and migration extract as root) and vikunja then fails with
# "storage validation failed ... permission denied". Fix it and restart.
# Volume name is fixed via `name:` in compose.yaml.
VIKUNJA_VOL="selfhosted_vikunja_files"
vol_owner="$($SUDO docker run --rm -v "$VIKUNJA_VOL":/data alpine \
  stat -c '%u' /data 2>/dev/null || echo 0)"
if [ "$vol_owner" != "1000" ]; then
  echo "==> Fixing ownership of $VIKUNJA_VOL (uid $vol_owner -> 1000)..."
  $SUDO docker run --rm -v "$VIKUNJA_VOL":/data alpine \
    sh -c 'chown -R 1000:0 /data && chmod -R u+rwX,g+rwX /data'
  $SUDO docker compose restart vikunja
fi

$SUDO docker compose ps

# Non-interactive backup setup: install the timer if WebDAV credentials are in .env.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

if [ -n "${BACKUP_WEBDAV_USER:-}" ] && [ -n "${BACKUP_WEBDAV_PASS:-}" ]; then
  echo "==> Installing backup timer..."
  chmod +x backup.sh restore.sh
  sed "s|__PROJECT_DIR__|$(pwd)|g" systemd/backup.service \
    | $SUDO tee /etc/systemd/system/backup.service > /dev/null
  sed "s|__PROJECT_DIR__|$(pwd)|g" systemd/backup.timer \
    | $SUDO tee /etc/systemd/system/backup.timer > /dev/null
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now backup.timer
  $SUDO systemctl list-timers backup.timer --no-pager || true
else
  echo "==> BACKUP_WEBDAV_USER/BACKUP_WEBDAV_PASS not set in .env, skipping backup setup."
  echo "    Fill them in and re-run ./install.sh (see README 'Backups')."
fi

echo "==> Done. Check Caddy logs for certificate issuance: $SUDO docker compose logs -f caddy"
