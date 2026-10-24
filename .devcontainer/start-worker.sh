#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/tmp/rdp-worker.log"
exec >> "$LOG_FILE" 2>&1
echo "=== [$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting RDP Worker ==="

WIN_VERSION="${WIN_VERSION:-2022}"
WIN_RAM="${WIN_RAM:-6G}"
WIN_CPUS="${WIN_CPUS:-2}"
WIN_DISK="${WIN_DISK:-32G}"
STORAGE_PATH="/tmp/windows"
CREDS_FILE="/tmp/rdp-creds"
STATUS_FILE="/tmp/rdp-status.json"

mkdir -p "$STORAGE_PATH" /tmp/tsstate /var/run/tailscale
chmod 700 "$STORAGE_PATH"

if [ ! -f "$CREDS_FILE" ]; then
    WIN_USER="${WIN_USER:-WinAdmin}"
    WIN_PASS="${WIN_PASSWORD:-}"
    if [ -z "$WIN_PASS" ]; then
        WIN_PASS=$(python3 -c 'import secrets,string; chars=string.ascii_letters+string.digits+"!@#%_-"; print("".join(secrets.choice(chars) for _ in range(16)))')
    fi
    printf "%s\n%s\n" "$WIN_USER" "$WIN_PASS" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
fi

WIN_USER=$(sed -n 1p "$CREDS_FILE")
WIN_PASS=$(sed -n 2p "$CREDS_FILE")

if ! command -v socat >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y socat
fi
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! pgrep -x tailscaled >/dev/null 2>&1; then
    sudo nohup tailscaled --state=/tmp/tsstate/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock > /tmp/tailscaled.log 2>&1 &
    sleep 3
fi

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_IP=""
if [ -n "$TS_AUTHKEY" ]; then
    SHORT_HOST="winlab-$(cat /etc/hostname | tr -dc 'a-zA-Z0-9' | head -c 8)"
    sudo tailscale up --auth-key="$TS_AUTHKEY" --hostname="$SHORT_HOST" --accept-dns=false --reset
    TS_IP=$(sudo tailscale ip -4 || true)
fi

if ! docker ps -a --format '{{.Names}}' | grep -q '^windows$'; then
    docker run -d --name windows \
        --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN \
        -e VERSION="$WIN_VERSION" -e RAM_SIZE="$WIN_RAM" -e CPU_CORES="$WIN_CPUS" -e DISK_SIZE="$WIN_DISK" \
        -e USERNAME="$WIN_USER" -e PASSWORD="$WIN_PASS" \
        -p 127.0.0.1:8006:8006 -p 127.0.0.1:3389:3389/tcp -p 127.0.0.1:3389:3389/udp \
        -v "$STORAGE_PATH:/storage" --stop-timeout 120 ghcr.io/dockur/windows
else
    docker start windows || true
fi

if [ -n "$TS_IP" ]; then
    sudo pkill -f "socat TCP-LISTEN:3389" 2>/dev/null || true
    sudo pkill -f "socat TCP-LISTEN:8006" 2>/dev/null || true
    sudo setsid /usr/bin/socat TCP-LISTEN:3389,bind="$TS_IP",reuseaddr,fork TCP:127.0.0.1:3389 </dev/null >/tmp/socat-rdp.log 2>&1 &
    sudo setsid /usr/bin/socat TCP-LISTEN:8006,bind="$TS_IP",reuseaddr,fork TCP:127.0.0.1:8006 </dev/null >/tmp/socat-web.log 2>&1 &
fi

cat <<EOF > "$STATUS_FILE"
{
  "updated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "status": "running",
  "tailscale_ip": "${TS_IP:-unknown}",
  "rdp_host": "${TS_IP:-127.0.0.1}:3389",
  "web_console": "http://${TS_IP:-127.0.0.1}:8006",
  "username": "$WIN_USER",
  "password": "$WIN_PASS",
  "windows_version": "$WIN_VERSION"
}
EOF
chmod 600 "$STATUS_FILE"

CONTROLLER_HOST="${CONTROLLER_HOST:-103.42.245.208:8787}"
CODESPACE_ID="${CODESPACE_NAME:-$(hostname)}"
if [ -n "$TS_IP" ] && [ -n "$CONTROLLER_HOST" ]; then
    curl -s -m 5 -X POST "http://$CONTROLLER_HOST/api/instances/$CODESPACE_ID/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"tailscale_ip\":\"$TS_IP\",\"status\":\"running\"}" || true
fi
