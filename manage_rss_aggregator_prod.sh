#!/usr/bin/env bash
#
# Production Management Script for RSS Aggregator Service
#
# Allows starting, stopping, checking status, restarting, and tailing logs
# of the remote systemd rss-aggregator service.
#
# Usage:
#   ./manage_rss_aggregator_prod.sh [start|stop|restart|status|logs] [options]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config overrides or fallbacks
KEY_PATH="${PROD_SSH_KEY:-/Users/joebains/revenuemindproai/revenuemindproai.priv}"
REMOTE_HOST="${PROD_SSH_HOST:-ubuntu@18.134.80.37}"
REMOTE_PORT="${PROD_SSH_PORT:-22}"
SERVICE_NAME="${RSS_AGG_SERVICE_NAME:-rss-aggregator}"
REMOTE_APP_DIR="${RSS_AGG_REMOTE_DIR:-/home/ubuntu/rss-aggregator}"
RSS_LOG_FILE="${RSS_AGG_LOG_FILE:-/home/ubuntu/rss-aggregator/logs/rss_aggregator.log}"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Error: SSH private key not found: $KEY_PATH" >&2
  exit 1
fi

SSH_OPTS=(
  -i "$KEY_PATH"
  -p "$REMOTE_PORT"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)

ssh_remote() {
  ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$@"
}

print_help() {
  echo "RSS Aggregator Production Manager Helper"
  echo "========================================"
  echo "Usage: $0 <command>"
  echo
  echo "Commands:"
  echo "  start     - Start the systemd rss-aggregator service on the remote node"
  echo "  stop      - Stop the systemd rss-aggregator service on the remote node"
  echo "  restart   - Restart the systemd rss-aggregator service on the remote node"
  echo "  status    - View systemd execution state, health checklist, and publar config details"
  echo "  logs      - View recent service output. Use option -f to tail live logs (e.g. ./manage_rss_aggregator_prod.sh logs -f)"
  echo
}

if [[ $# -lt 1 ]]; then
  print_help
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  start)
    echo "Starting remote service: $SERVICE_NAME on $REMOTE_HOST..."
    ssh_remote "sudo systemctl start '$SERVICE_NAME'"
    echo "Service started successfully."
    ;;

  stop)
    echo "Stopping remote service: $SERVICE_NAME on $REMOTE_HOST..."
    ssh_remote "sudo systemctl stop '$SERVICE_NAME'"
    echo "Service stopped successfully."
    ;;

  restart)
    echo "Restarting remote service: $SERVICE_NAME on $REMOTE_HOST..."
    ssh_remote "sudo systemctl restart '$SERVICE_NAME'"
    echo "Service restarted successfully."
    ;;

  status)
    echo "Fetching service status..."
    ssh_remote "systemctl --no-pager --full status '$SERVICE_NAME'"
    echo
    echo "Checking local application loopback health check..."
    ssh_remote "
      if curl -fsS 'http://127.0.0.1:18090/health' >/dev/null 2>&1; then
        curl -s 'http://127.0.0.1:18090/health' | python3 -m json.tool || curl -s 'http://127.0.0.1:18090/health'
      else
        echo 'Error: Port 18090 is not responding. Service might be down or binding is misconfigured.' >&2
      fi
    "
    ;;

  logs)
    TAIL_FLAG=""
    LINE_COUNT="50"
    
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--follow)
          TAIL_FLAG="-f"
          shift
          ;;
        -n|--lines)
          LINE_COUNT="$2"
          shift 2
          ;;
        *)
          echo "Unknown option: $1" >&2
          exit 1
          ;;
      esac
    done

    echo "Fetching latest logs from $RSS_LOG_FILE (lines: $LINE_COUNT, tail: ${TAIL_FLAG:-off})..."
    if [[ -n "$TAIL_FLAG" ]]; then
      # Remote tail follow
      ssh_remote "tail -n '$LINE_COUNT' -f '$RSS_LOG_FILE'"
    else
      # One-shot log print
      ssh_remote "tail -n '$LINE_COUNT' '$RSS_LOG_FILE'"
    fi
    ;;

  *)
    echo "Error: Unknown command '$COMMAND'" >&2
    print_help
    exit 1
    ;;
esac
