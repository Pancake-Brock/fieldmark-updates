#!/usr/bin/env bash
# Fieldmark installer (Linux). Published to the public fieldmark-updates repo on every release —
# run via: curl -fsSL https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main/install.sh | bash
#
# Every `read` below is redirected from /dev/tty rather than plain stdin — piping this script
# into bash means stdin is already the script's own bytes, not the terminal, so a plain `read`
# would try to consume the script source instead of waiting for real input.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main"
INSTALL_DIR="${FIELDMARK_INSTALL_DIR:-$HOME/fieldmark}"

echo "== Fieldmark Installer =="
echo

if ! command -v docker >/dev/null 2>&1; then
  cat <<'EOF'
Docker is required but wasn't found.

Install it with Docker's official script:
  curl -fsSL https://get.docker.com | sh

Then log out and back in (or run: newgrp docker) so your user can run
docker without sudo, and re-run this installer.
EOF
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not running (or you don't have permission to use it)." >&2
  echo "Start Docker (e.g. 'sudo systemctl start docker') and re-run this installer." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker is installed, but the 'docker compose' plugin isn't available." >&2
  echo "See https://docs.docker.com/compose/install/ then re-run this installer." >&2
  exit 1
fi

echo "Docker found: $(docker --version)"
echo

echo "How will this be accessed?"
echo "  1) LAN only — everyone opens it from this office's network (no domain needed)"
echo "  2) Internet-facing — reachable from anywhere via a real domain name (automatic HTTPS)"
read -rp "Choose 1 or 2: " MODE_CHOICE < /dev/tty

DOMAIN=""
if [ "$MODE_CHOICE" = "2" ]; then
  read -rp "Domain name (must already point at this machine's public IP), e.g. takeoff.example.com: " DOMAIN < /dev/tty
  if [ -z "$DOMAIN" ]; then
    echo "A domain is required for internet-facing mode." >&2
    exit 1
  fi
fi

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "$LAN_IP" ]; then
  LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
fi
LAN_IP="${LAN_IP:-localhost}"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
echo
echo "Installing into $INSTALL_DIR"

echo "Downloading docker-compose.prod.yml..."
curl -fsSL -o docker-compose.prod.yml "$REPO_RAW/docker-compose.prod.yml"

SETTINGS_ENCRYPTION_KEY="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
WATCHTOWER_HTTP_TOKEN="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

if [ "$MODE_CHOICE" = "2" ]; then
  SITE_ADDRESS="$DOMAIN"
  COOKIE_SECURE="true"
  WEB_ORIGIN="https://$DOMAIN"
else
  SITE_ADDRESS=":80"
  COOKIE_SECURE="false"
  WEB_ORIGIN="http://$LAN_IP"
fi

cat > .env <<ENVEOF
SITE_ADDRESS=$SITE_ADDRESS
COOKIE_SECURE=$COOKIE_SECURE
WEB_ORIGIN=$WEB_ORIGIN
SETTINGS_ENCRYPTION_KEY=$SETTINGS_ENCRYPTION_KEY
WATCHTOWER_HTTP_TOKEN=$WATCHTOWER_HTTP_TOKEN
FIELDMARK_VERSION=latest
UPDATE_MANIFEST_URL=https://raw.githubusercontent.com/Pancake-Brock/fieldmark-updates/main/latest.json
ENVEOF

echo ".env written."
echo

echo "Pulling images (this can take a few minutes on first run)..."
docker compose -f docker-compose.prod.yml pull
echo "Starting Fieldmark..."
docker compose -f docker-compose.prod.yml up -d

echo
printf "Waiting for Fieldmark to start"
READY=""
for _ in $(seq 1 60); do
  if docker compose -f docker-compose.prod.yml exec -T api node -e \
    "fetch('http://localhost:3001/api/branding').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
    >/dev/null 2>&1; then
    READY="1"
    break
  fi
  printf "."
  sleep 2
done
echo
if [ -z "$READY" ]; then
  echo "Fieldmark didn't come up within 2 minutes — check 'docker compose -f docker-compose.prod.yml logs api'." >&2
  exit 1
fi
echo "Fieldmark is running."
echo

echo "Set up your first login:"
echo "  1) Start blank — create the first admin account"
echo "  2) Load sample data — explore Fieldmark with example projects first"
read -rp "Choose 1 or 2: " DATA_CHOICE < /dev/tty

if [ "$DATA_CHOICE" = "2" ]; then
  docker compose -f docker-compose.prod.yml exec -T api pnpm seed-example-data
else
  read -rp "Admin name: " ADMIN_NAME < /dev/tty
  read -rp "Admin email: " ADMIN_EMAIL < /dev/tty
  read -rsp "Admin password (min 8 chars): " ADMIN_PASSWORD < /dev/tty
  echo
  docker compose -f docker-compose.prod.yml exec -T \
    -e BOOTSTRAP_ADMIN_NAME="$ADMIN_NAME" \
    -e BOOTSTRAP_ADMIN_EMAIL="$ADMIN_EMAIL" \
    -e BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    api pnpm bootstrap-admin
fi

echo
echo "=========================================="
if [ "$MODE_CHOICE" = "2" ]; then
  echo "Fieldmark is ready at: https://$DOMAIN"
  echo "(HTTPS is provisioned automatically on first request — allow a minute.)"
else
  echo "Fieldmark is ready at: http://$LAN_IP"
  echo "(anyone on this network can open that address)"
fi
echo "=========================================="
