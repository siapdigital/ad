#!/usr/bin/env bash
# ==============================================================================
# RDP Generator Worker Bootstrapper (Non-root Devcontainer Compatible)
# ==============================================================================
set -euo pipefail

LOG_FILE="/tmp/rdp-worker.log"
exec >> "$LOG_FILE" 2>&1
echo "=== [$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting RDP Generator Worker ==="

WIN_VERSION="${WIN_VERSION:-2022}"
WIN_RAM="${WIN_RAM:-8G}"
WIN_CPUS="${WIN_CPUS:-2}"
WIN_DISK="${WIN_DISK:-32G}"
STORAGE_PATH="/tmp/windows"
CREDS_FILE="/tmp/rdp-creds"
STATUS_FILE="/tmp/rdp-status.json"

sudo mkdir -p "$STORAGE_PATH" /tmp/tsstate /var/run/tailscale
sudo chmod 777 "$STORAGE_PATH" /tmp/tsstate /var/run/tailscale

# Load Codespace Secrets if not passed via env
if [ -f "/workspaces/.codespaces/shared/user-secrets-envs.json" ]; then
    TS_AUTHKEY_SECRET=$(python3 -c "import json; print(json.load(open('/workspaces/.codespaces/shared/user-secrets-envs.json')).get('TS_AUTHKEY', ''))" 2>/dev/null || true)
    WIN_PASSWORD_SECRET=$(python3 -c "import json; print(json.load(open('/workspaces/.codespaces/shared/user-secrets-envs.json')).get('WIN_PASSWORD', ''))" 2>/dev/null || true)
    if [ -n "$TS_AUTHKEY_SECRET" ] && [ -z "${TS_AUTHKEY:-}" ]; then
        TS_AUTHKEY="$TS_AUTHKEY_SECRET"
    fi
    if [ -n "$WIN_PASSWORD_SECRET" ] && [ -z "${WIN_PASSWORD:-}" ]; then
        WIN_PASSWORD="$WIN_PASSWORD_SECRET"
    fi
fi

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

echo "Configured User: $WIN_USER"

# Remove broken yarn repo if present
sudo rm -f /etc/apt/sources.list.d/yarn.list 2>/dev/null || true

# Install Tailscale standalone binaries if not present
if ! command -v tailscale >/dev/null 2>&1; then
    echo "Installing Tailscale standalone binaries..."
    curl -fsSL https://pkgs.tailscale.com/stable/tailscale_1.76.6_amd64.tgz -o /tmp/ts.tgz
    tar -C /tmp -xzf /tmp/ts.tgz
    sudo cp /tmp/tailscale_*/tailscale* /usr/local/bin/
    rm -rf /tmp/ts.tgz /tmp/tailscale_*
fi

# Start tailscaled
if ! pgrep -x tailscaled >/dev/null 2>&1; then
    echo "Starting tailscaled..."
    sudo nohup /usr/local/bin/tailscaled \
        --state=/tmp/tsstate/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock \
        > /tmp/tailscaled.log 2>&1 &
    sleep 3
fi

# Join Tailnet
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_IP=""
if [ -n "$TS_AUTHKEY" ]; then
    echo "Joining Tailscale mesh..."
    SHORT_HOST="winlab-$(cat /etc/hostname | tr -dc 'a-zA-Z0-9' | head -c 8)"
    sudo /usr/local/bin/tailscale up \
        --auth-key="$TS_AUTHKEY" \
        --hostname="$SHORT_HOST" \
        --accept-dns=false \
        --reset || true
    
    TS_IP=$(sudo /usr/local/bin/tailscale ip -4 || true)
    echo "Tailscale connected: IP = $TS_IP"
fi

# Launch Windows Docker container
if ! docker ps -a --format '{{.Names}}' | grep -q '^windows$'; then
    echo "Spawning dockur/windows container..."
    docker run -d \
        --name windows \
        --restart unless-stopped \
        --device=/dev/kvm \
        --device=/dev/net/tun \
        --cap-add NET_ADMIN \
        -e VERSION="$WIN_VERSION" \
        -e RAM_SIZE="$WIN_RAM" \
        -e CPU_CORES="$WIN_CPUS" \
        -e DISK_SIZE="$WIN_DISK" \
        -e USERNAME="$WIN_USER" \
        -e PASSWORD="$WIN_PASS" \
        -p 8006:8006 \
        -p 3389:3389/tcp \
        -v "$STORAGE_PATH:/storage" \
        --stop-timeout 120 \
        ghcr.io/dockur/windows
else
    docker start windows || true
fi

# Record status
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

# Report heartbeat back to controller
CONTROLLER_HOST="${CONTROLLER_HOST:-103.42.245.208:8787}"
CODESPACE_ID="${CODESPACE_NAME:-$(hostname)}"
if [ -n "$TS_IP" ] && [ -n "$CONTROLLER_HOST" ]; then
    echo "Reporting heartbeat to http://$CONTROLLER_HOST/api/instances/$CODESPACE_ID/heartbeat..."
    curl -s -m 5 -X POST "http://$CONTROLLER_HOST/api/instances/$CODESPACE_ID/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"tailscale_ip\":\"$TS_IP\",\"status\":\"running\",\"password\":\"$WIN_PASS\"}" || true
fi

echo "=== RDP Generator Worker initialized successfully ==="
