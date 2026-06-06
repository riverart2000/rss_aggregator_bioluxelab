#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEY_PATH="${PROD_SSH_KEY:-$SCRIPT_DIR/revenuemindproai.priv}"
REMOTE_HOST="${PROD_SSH_HOST:-ubuntu@18.134.80.37}"
REMOTE_PORT="${PROD_SSH_PORT:-22}"

LOCAL_SCRIPT="${RSS_AGG_LOCAL_SCRIPT:-$SCRIPT_DIR/rss_aggregator.py}"
LOCAL_FEEDS="${RSS_AGG_LOCAL_FEEDS:-$SCRIPT_DIR/rss_feeds.json}"
LOCAL_ENV_FILE="${RSS_AGG_LOCAL_ENV_FILE:-$SCRIPT_DIR/.env}"

REMOTE_APP_DIR="${RSS_AGG_REMOTE_DIR:-/home/ubuntu/rss-aggregator}"
SERVICE_NAME="${RSS_AGG_SERVICE_NAME:-rss-aggregator}"
RSS_PORT="${RSS_AGG_PORT:-18090}"
RSS_MAX_ITEMS="${RSS_AGG_MAX_ITEMS:-1000}"
CHANNEL_LINK="${RSS_AGG_CHANNEL_LINK:-https://revenuemindproai.com/}"
RSS_LOG_DIR="${RSS_AGG_REMOTE_LOG_DIR:-$REMOTE_APP_DIR/logs}"
RSS_LOG_FILE="${RSS_AGG_LOG_FILE:-$RSS_LOG_DIR/rss_aggregator.log}"
RSS_LOG_LEVEL="${RSS_AGG_LOG_LEVEL:-INFO}"
RSS_LOG_MAX_BYTES="${RSS_AGG_LOG_MAX_BYTES:-5242880}"
RSS_LOG_BACKUP_COUNT="${RSS_AGG_LOG_BACKUP_COUNT:-5}"

read_dotenv_value() {
  local key="$1"
  local file="$2"
  local line raw
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  raw="${line#*=}"
  raw="${raw%$'\r'}"
  if [[ "$raw" == '"'*'"' && ${#raw} -ge 2 ]]; then
    raw="${raw:1:${#raw}-2}"
  elif [[ "$raw" == "'"*"'" && ${#raw} -ge 2 ]]; then
    raw="${raw:1:${#raw}-2}"
  fi
  printf '%s' "$raw"
}

SHOPIFY_DOMAIN="${RSS_AGG_SHOPIFY_DOMAIN:-${MYSHOPIFY_DOMAIN:-}}"
SHOPIFY_API_VERSION="${RSS_AGG_SHOPIFY_API_VERSION:-${SHOPIFY_API_VERSION:-2026-01}}"
# Use explicit Admin token only when provided; otherwise rely on OAuth client credentials.
SHOPIFY_ADMIN_TOKEN="${RSS_AGG_SHOPIFY_ADMIN_TOKEN:-${SHOPIFY_ADMIN_ACCESS_TOKEN:-}}"
SHOPIFY_CLIENT_ID="${RSS_AGG_SHOPIFY_CLIENT_ID:-${SHOPIFY_CLIENT_ID:-}}"
SHOPIFY_CLIENT_SECRET="${RSS_AGG_SHOPIFY_CLIENT_SECRET:-${SHOPIFY_CLIENT_SECRET:-}}"

if [[ -f "$LOCAL_ENV_FILE" ]]; then
  [[ -n "$SHOPIFY_DOMAIN" ]] || SHOPIFY_DOMAIN="$(read_dotenv_value MYSHOPIFY_DOMAIN "$LOCAL_ENV_FILE" || true)"
  [[ -n "$SHOPIFY_API_VERSION" ]] || SHOPIFY_API_VERSION="$(read_dotenv_value SHOPIFY_API_VERSION "$LOCAL_ENV_FILE" || true)"
  [[ -n "$SHOPIFY_ADMIN_TOKEN" ]] || SHOPIFY_ADMIN_TOKEN="$(read_dotenv_value SHOPIFY_ADMIN_ACCESS_TOKEN "$LOCAL_ENV_FILE" || true)"
  [[ -n "$SHOPIFY_CLIENT_ID" ]] || SHOPIFY_CLIENT_ID="$(read_dotenv_value SHOPIFY_CLIENT_ID "$LOCAL_ENV_FILE" || true)"
  [[ -n "$SHOPIFY_CLIENT_SECRET" ]] || SHOPIFY_CLIENT_SECRET="$(read_dotenv_value SHOPIFY_CLIENT_SECRET "$LOCAL_ENV_FILE" || true)"
fi

SHOPIFY_DOMAIN="${SHOPIFY_DOMAIN#https://}"
SHOPIFY_DOMAIN="${SHOPIFY_DOMAIN#http://}"
SHOPIFY_DOMAIN="${SHOPIFY_DOMAIN%/}"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "SSH key not found: $KEY_PATH" >&2
  exit 1
fi
if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "Aggregator script not found: $LOCAL_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$LOCAL_FEEDS" ]]; then
  echo "Feed list file not found: $LOCAL_FEEDS" >&2
  exit 1
fi

if grep -qi '^shopify-admin://' "$LOCAL_FEEDS"; then
  if [[ -z "$SHOPIFY_DOMAIN" ]]; then
    echo "shopify-admin:// source requires Shopify domain (RSS_AGG_SHOPIFY_DOMAIN or MYSHOPIFY_DOMAIN)." >&2
    exit 1
  fi
  if [[ -z "$SHOPIFY_ADMIN_TOKEN" && ( -z "$SHOPIFY_CLIENT_ID" || -z "$SHOPIFY_CLIENT_SECRET" ) ]]; then
    echo "shopify-admin:// source requires either admin token or Shopify client credentials." >&2
    echo "Set RSS_AGG_SHOPIFY_ADMIN_TOKEN or RSS_AGG_SHOPIFY_CLIENT_ID + RSS_AGG_SHOPIFY_CLIENT_SECRET." >&2
    exit 1
  fi
fi

SSH_OPTS=(
  -i "$KEY_PATH"
  -p "$REMOTE_PORT"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)

SCP_OPTS=(
  -i "$KEY_PATH"
  -P "$REMOTE_PORT"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)

ssh_remote() {
  ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$@"
}

scp_remote() {
  local src="$1"
  local dst="$2"
  scp "${SCP_OPTS[@]}" "$src" "$REMOTE_HOST:$dst"
}

echo "[1/7] Checking that target port $RSS_PORT is free on $REMOTE_HOST..."
if ssh_remote "systemctl cat '$SERVICE_NAME' >/dev/null 2>&1"; then
  echo "Service $SERVICE_NAME already exists; allowing current port usage for in-place redeploy."
else
  if ssh_remote "ss -ltn '( sport = :$RSS_PORT )' | awk 'NR>1{print; found=1} END{exit found?0:1}'" >/tmp/rss_agg_port_check.$$ 2>/dev/null; then
    echo "Port $RSS_PORT is already in use on the server. Choose another with RSS_AGG_PORT=..." >&2
    cat /tmp/rss_agg_port_check.$$ >&2 || true
    rm -f /tmp/rss_agg_port_check.$$ || true
    exit 1
  fi
  rm -f /tmp/rss_agg_port_check.$$ || true
fi

echo "[2/7] Preparing remote app directory $REMOTE_APP_DIR..."
ssh_remote "mkdir -p '$REMOTE_APP_DIR' '$RSS_LOG_DIR'"
ssh_remote "touch '$RSS_LOG_FILE' && chmod 664 '$RSS_LOG_FILE'"

echo "[3/7] Uploading aggregator files..."
scp_remote "$LOCAL_SCRIPT" "$REMOTE_APP_DIR/rss_aggregator.py"
scp_remote "$LOCAL_FEEDS" "$REMOTE_APP_DIR/rss_feeds.json"
ssh_remote "chmod 644 '$REMOTE_APP_DIR/rss_aggregator.py' '$REMOTE_APP_DIR/rss_feeds.json'"

echo "[4/7] Installing/refreshing systemd service $SERVICE_NAME..."
ssh_remote "sudo tee /etc/systemd/system/$SERVICE_NAME.service >/dev/null" <<EOF
[Unit]
Description=RSS Feed Aggregator Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=$REMOTE_APP_DIR
ExecStart=/usr/bin/python3 $REMOTE_APP_DIR/rss_aggregator.py --feeds-file $REMOTE_APP_DIR/rss_feeds.json --host 127.0.0.1 --port $RSS_PORT --cache-ttl 300 --timeout 20 --max-items $RSS_MAX_ITEMS --channel-link $CHANNEL_LINK --channel-title RevenueMindProAI_Aggregated_Feed --channel-description Aggregated_RSS_feeds_for_RevenueMindProAI
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment="RSS_AGG_SHOPIFY_DOMAIN=$SHOPIFY_DOMAIN"
Environment="RSS_AGG_SHOPIFY_API_VERSION=$SHOPIFY_API_VERSION"
Environment="RSS_AGG_SHOPIFY_ADMIN_TOKEN=$SHOPIFY_ADMIN_TOKEN"
Environment="RSS_AGG_SHOPIFY_CLIENT_ID=$SHOPIFY_CLIENT_ID"
Environment="RSS_AGG_SHOPIFY_CLIENT_SECRET=$SHOPIFY_CLIENT_SECRET"
Environment="RSS_AGG_LOG_FILE=$RSS_LOG_FILE"
Environment="RSS_AGG_LOG_LEVEL=$RSS_LOG_LEVEL"
Environment="RSS_AGG_LOG_MAX_BYTES=$RSS_LOG_MAX_BYTES"
Environment="RSS_AGG_LOG_BACKUP_COUNT=$RSS_LOG_BACKUP_COUNT"

[Install]
WantedBy=multi-user.target
EOF

echo "[5/7] Reloading systemd and starting service..."
ssh_remote "sudo systemctl daemon-reload && sudo systemctl enable --now '$SERVICE_NAME' && sudo systemctl restart '$SERVICE_NAME'"

echo "[6/7] Verifying service health on origin..."
ssh_remote "systemctl --no-pager --full status '$SERVICE_NAME' | sed -n '1,25p'"
ssh_remote "for i in \$(seq 1 20); do if curl -fsS 'http://127.0.0.1:$RSS_PORT/health' >/dev/null 2>&1; then curl -fsS 'http://127.0.0.1:$RSS_PORT/health'; exit 0; fi; sleep 1; done; echo 'Health check timed out after 20s' >&2; exit 1"
ssh_remote "echo '\nRecent aggregator logs ($RSS_LOG_FILE):'; tail -n 25 '$RSS_LOG_FILE' || true"

echo "[7/7] Done."
echo

echo "Service is running on origin loopback: http://127.0.0.1:$RSS_PORT/feed.xml"
echo "Aggregator log file: $RSS_LOG_FILE"
echo "Cloudflare should continue using HTTPS on 443/8443 to your web server; keep this backend port private on loopback."
echo "Next: ensure a reverse-proxy route on standard 443 exposes /apps/rss (Shopify-safe when custom ports are stripped)."
echo "Examples are in: $SCRIPT_DIR/rss_reverse_proxy_examples.md"
echo "Production baseline mirror is in: $SCRIPT_DIR/ops/production/README.md"
