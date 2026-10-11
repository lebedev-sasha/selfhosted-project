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

# Fix: vikunja runs as uid 1000, but the root of its files volume can end up root-owned
VIKUNJA_VOL="selfhosted_vikunja_files"
vol_owner="$($SUDO docker run --rm -v "$VIKUNJA_VOL":/data alpine \
  stat -c '%u' /data 2>/dev/null || echo 0)"
if [ "$vol_owner" != "1000" ]; then
  echo "==> Fixing ownership of $VIKUNJA_VOL (uid $vol_owner -> 1000)..."
  $SUDO docker run --rm -v "$VIKUNJA_VOL":/data alpine \
    sh -c 'chown -R 1000:0 /data && chmod -R u+rwX,g+rwX /data'
  $SUDO docker compose restart vikunja
fi

# --- Daily backups (backup.sh via cron) ---
if [ -f "./backup.sh" ]; then
  chmod +x ./backup.sh ./restore.sh 2>/dev/null || chmod +x ./backup.sh
  mkdir -p "$HOME/backup"
  # Let the user's cron job talk to Docker without sudo. Cron re-reads group
  # membership for every job, so no re-login is needed for the schedule.
  RUN_USER="${SUDO_USER:-$(id -un)}"
  if ! id -nG "$RUN_USER" | grep -qw docker; then
    $SUDO usermod -aG docker "$RUN_USER"
    echo "==> User '$RUN_USER' added to the docker group (new shells need re-login)."
  fi
  PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CRON_LINE="30 3 * * * cd $PROJECT_DIR && ./backup.sh >> \$HOME/backup/backup.log 2>&1"
  if crontab -l 2>/dev/null | grep -Fq "$CRON_LINE"; then
    echo "==> Backup cron job already registered."
  else
    { crontab -l 2>/dev/null || true; echo "$CRON_LINE"; } | crontab -
    echo "==> Registered daily backup cron job (03:30)."
  fi
fi

$SUDO docker compose ps

echo "==> Done. Check Caddy logs for certificate issuance: $SUDO docker compose logs -f caddy"
