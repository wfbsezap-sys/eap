#!/usr/bin/env bash
set -euo pipefail

# --------------------------
# Config
# --------------------------
INSTALLER_URL="https://brightdata.com/static/earnapp/install.sh"
CDN_BASE="https://cdn-earnapp.b-cdn.net/static"
APP_DIR="/app/src/"
BIN_PATH="/usr/bin/earnapp"
CONFIG_DIR="/etc/earnapp"

# --------------------------
# Debug mode
# --------------------------
if [[ "${DEBUG_MODE:-}" == "1" ]]; then
    echo "[INFO] DEBUG_MODE enabled, launching shell..."
    exec bash
fi

# --------------------------
# Validate UUID
# --------------------------
if [[ -z "${EARNAPP_UUID:-}" ]]; then
    echo "[ERROR] EARNAPP_UUID not set!"
    exit 1
fi

# --------------------------
# Container camouflage
# --------------------------

# 1. Remove Docker runtime marker
rm -f /.dockerenv

# 2. Generate stable machine-id from UUID (earnapp reads /etc/machine-id for fingerprinting)
if [[ ! -f /etc/machine-id ]] || [[ ! -s /etc/machine-id ]]; then
    echo -n "$EARNAPP_UUID" | md5sum | cut -d' ' -f1 > /etc/machine-id
fi

# 3. Set realistic hostname (default Docker hostname is a 12-char hex container ID)
if [[ "$(hostname)" =~ ^[0-9a-f]{12}$ ]]; then
    FAKE_HOST="debian-$(echo -n "$EARNAPP_UUID" | md5sum | cut -c1-8)"
    hostname "$FAKE_HOST" 2>/dev/null || true
fi

# 4. Fake systemd markers
mkdir -p /run/systemd/system

# 5. Spawn dummy background processes to pad the /proc scan
#    (earnapp reads /proc/*/cmdline,status,stat for every PID on the system;
#     a container with only 1-3 processes is an obvious giveaway)
#    exec -a sets /proc/PID/cmdline; _idle uses prctl(PR_SET_NAME) to set comm
DUMMY_NAMES=( "/sbin/init" "/usr/sbin/cron" "/usr/sbin/sshd" "/usr/bin/dbus-daemon"
    "/lib/systemd/systemd-journald" "/lib/systemd/systemd-logind"
    "/lib/systemd/systemd-resolved" "/usr/sbin/rsyslogd" "/sbin/agetty"
    "/usr/lib/policykit-1/polkitd" )
for _name in "${DUMMY_NAMES[@]}"; do
    (exec -a "$_name" /usr/local/bin/_idle "$_name") &
done
unset DUMMY_NAMES _name

# --------------------------
# VLESS proxy setup
# --------------------------
if [[ -n "${VLESS_URL:-}" ]]; then
    echo "[INFO] VLESS proxy configured, setting up xray..."

    # Parse vless://uuid@host:port?params#tag
    VLESS_BODY="${VLESS_URL#vless://}"
    VLESS_UUID="${VLESS_BODY%%@*}"
    VLESS_REMAINDER="${VLESS_BODY#*@}"
    VLESS_HOST_PORT="${VLESS_REMAINDER%%\?*}"
    VLESS_HOST="${VLESS_HOST_PORT%%:*}"
    VLESS_PORT="${VLESS_HOST_PORT##*:}"
    VLESS_PARAMS="${VLESS_REMAINDER#*\?}"
    VLESS_PARAMS="${VLESS_PARAMS%%#*}"  # strip #tag

    # Extract query parameters
    parse_param() { echo "$VLESS_PARAMS" | tr '&' '\n' | grep "^$1=" | cut -d= -f2 || true; }
    VLESS_TYPE=$(parse_param type)
    VLESS_SECURITY=$(parse_param security)
    VLESS_SNI=$(parse_param sni)
    VLESS_FP=$(parse_param fp)
    VLESS_FLOW=$(parse_param flow)
    VLESS_PBK=$(parse_param pbk)
    VLESS_SID=$(parse_param sid)
    VLESS_PATH=$(parse_param path)
    VLESS_ENCRYPTION=$(parse_param encryption)

    # Defaults
    : "${VLESS_TYPE:=tcp}"
    : "${VLESS_SECURITY:=none}"
    : "${VLESS_ENCRYPTION:=none}"

    # Build streamSettings
    STREAM_NETWORK="\"network\": \"${VLESS_TYPE}\""
    STREAM_SECURITY="\"security\": \"none\""
    STREAM_TLS=""

    if [[ "$VLESS_SECURITY" == "tls" ]]; then
        STREAM_SECURITY="\"security\": \"tls\""
        STREAM_TLS=", \"tlsSettings\": { \"serverName\": \"${VLESS_SNI:-$VLESS_HOST}\", \"fingerprint\": \"${VLESS_FP:-chrome}\" }"
    elif [[ "$VLESS_SECURITY" == "reality" ]]; then
        STREAM_SECURITY="\"security\": \"reality\""
        STREAM_TLS=", \"realitySettings\": { \"serverName\": \"${VLESS_SNI:-}\", \"fingerprint\": \"${VLESS_FP:-chrome}\", \"publicKey\": \"${VLESS_PBK:-}\", \"shortId\": \"${VLESS_SID:-}\" }"
    fi

    # flow field (for XTLS Vision etc.)
    FLOW_LINE=""
    if [[ -n "$VLESS_FLOW" ]]; then
        FLOW_LINE=", \"flow\": \"${VLESS_FLOW}\""
    fi

    # WebSocket transport settings
    WS_SETTINGS=""
    if [[ "$VLESS_TYPE" == "ws" ]]; then
        DECODED_PATH=$(printf '%b' "${VLESS_PATH//%/\\x}")
        WS_SETTINGS=", \"wsSettings\": { \"path\": \"${DECODED_PATH:-/}\" }"
    fi

    # Generate xray config
    cat > /tmp/xray-config.json <<XEOF
{
    "inbounds": [{
        "listen": "127.0.0.1",
        "port": 10808,
        "protocol": "socks",
        "settings": { "udpEnabled": false }
    }],
    "outbounds": [{
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": "${VLESS_HOST}",
                "port": ${VLESS_PORT},
                "users": [{
                    "id": "${VLESS_UUID}",
                    "encryption": "${VLESS_ENCRYPTION}"
                    ${FLOW_LINE}
                }]
            }]
        },
        "streamSettings": {
            ${STREAM_NETWORK},
            ${STREAM_SECURITY}
            ${STREAM_TLS}
            ${WS_SETTINGS}
        }
    }]
}
XEOF

    # Start xray
    /usr/local/bin/xray run -config /tmp/xray-config.json &

    # Wait for xray SOCKS5 port to be ready (up to 10s)
    for i in $(seq 1 20); do
        if bash -c "echo -n >/dev/tcp/127.0.0.1/10808" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    if ! bash -c "echo -n >/dev/tcp/127.0.0.1/10808" 2>/dev/null; then
        echo "[ERROR] xray failed to start on port 10808"
        exit 1
    fi
    echo "[INFO] xray started (VLESS -> ${VLESS_HOST}:${VLESS_PORT})"

    # Export upstream host for iptables exclusion, then set SOCKS5_PROXY to reuse redsocks logic
    export PROXY_UPSTREAM_HOST="$VLESS_HOST"
    export SOCKS5_PROXY="socks5://127.0.0.1:10808"

    # Clean up sensitive variables
    unset VLESS_BODY VLESS_UUID VLESS_REMAINDER VLESS_HOST_PORT VLESS_HOST VLESS_PORT
    unset VLESS_PARAMS VLESS_TYPE VLESS_SECURITY VLESS_SNI VLESS_FP VLESS_FLOW
    unset VLESS_PBK VLESS_SID VLESS_PATH VLESS_ENCRYPTION
    unset STREAM_NETWORK STREAM_SECURITY STREAM_TLS FLOW_LINE WS_SETTINGS
fi

# --------------------------
# SOCKS5 proxy setup
# --------------------------
if [[ -n "${SOCKS5_PROXY:-}" ]]; then
    echo "[INFO] SOCKS5 proxy configured, setting up redsocks..."

    # Strip socks5:// prefix if present
    PROXY_STR="${SOCKS5_PROXY#socks5://}"

    # Parse user:pass@host:port or host:port
    PROXY_USER=""
    PROXY_PASS=""
    if [[ "$PROXY_STR" == *@* ]]; then
        PROXY_AUTH="${PROXY_STR%@*}"
        PROXY_USER="${PROXY_AUTH%%:*}"
        PROXY_PASS="${PROXY_AUTH#*:}"
        PROXY_STR="${PROXY_STR##*@}"
    fi

    PROXY_HOST="${PROXY_STR%%:*}"
    PROXY_PORT="${PROXY_STR##*:}"

    if [[ -z "$PROXY_HOST" || -z "$PROXY_PORT" ]]; then
        echo "[ERROR] Invalid SOCKS5_PROXY format. Use: socks5://[user:pass@]host:port"
        exit 1
    fi

    # Generate redsocks config
    cat > /tmp/redsocks.conf <<REOF
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = ${PROXY_HOST};
    port = ${PROXY_PORT};
    type = socks5;
$(if [[ -n "$PROXY_USER" ]]; then
    echo "    login = \"${PROXY_USER}\";"
    echo "    password = \"${PROXY_PASS}\";"
fi)
}
REOF

    # Start redsocks
    redsocks -c /tmp/redsocks.conf
    sleep 1
    echo "[INFO] redsocks started (proxy: ${PROXY_HOST}:${PROXY_PORT})"

    # Set up iptables rules
    iptables -t nat -N REDSOCKS

    # Skip local/private traffic
    iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A REDSOCKS -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A REDSOCKS -d 240.0.0.0/4 -j RETURN

    # Skip traffic to the proxy server itself (avoid loop)
    iptables -t nat -A REDSOCKS -d "$PROXY_HOST" -j RETURN

    # Skip traffic to VLESS upstream server (avoid loop when xray connects out)
    if [[ -n "${PROXY_UPSTREAM_HOST:-}" ]]; then
        iptables -t nat -A REDSOCKS -d "$PROXY_UPSTREAM_HOST" -j RETURN
    fi

    # Redirect everything else to redsocks local port
    iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345

    # Apply to all outgoing TCP
    iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

    echo "[INFO] iptables rules configured, all TCP traffic routed through SOCKS5 proxy"

    # Clean up sensitive vars
    unset PROXY_STR PROXY_AUTH PROXY_USER PROXY_PASS PROXY_HOST PROXY_PORT
fi

# --------------------------
# Prepare directories and config files
# --------------------------
mkdir -p "$APP_DIR" "$CONFIG_DIR"
echo -n "$EARNAPP_UUID" > "$CONFIG_DIR/uuid"
touch "$CONFIG_DIR/status"
chmod 600 "$CONFIG_DIR/"*

# --------------------------
# Download EarnApp if missing
# --------------------------
if [[ ! -x "$BIN_PATH" ]]; then
    echo "[INFO] Downloading EarnApp..."
    ARCH=$(uname -m)
    VERSION=$(curl -fsSL "$INSTALLER_URL" | grep VERSION= | cut -d'"' -f2)
    PRODUCT="earnapp"
    case "$ARCH" in
        x86_64|amd64) FILE="$PRODUCT-x64-$VERSION" ;;
        armv6l|armv7l) FILE="$PRODUCT-arm7l-$VERSION" ;;
        aarch64|arm64) FILE="$PRODUCT-aarch64-$VERSION" ;;
        *) echo "[ERROR] Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    curl -fL "$CDN_BASE/$FILE" -o "$BIN_PATH"
    chmod +x "$BIN_PATH"
    echo "[INFO] EarnApp downloaded."
fi

# --------------------------
# Start EarnApp with auto-restart loop
# --------------------------
echo "[INFO] Starting EarnApp..."
"$BIN_PATH" stop 2>/dev/null || true
sleep 1

backoff=5
MAX_BACKOFF=300

while true; do
    "$BIN_PATH" start || true
    sleep 2
    
    # Run in foreground, will block until exit
    start_time=$(date +%s)
    "$BIN_PATH" run || true
    run_duration=$(( $(date +%s) - start_time ))
    
    # If ran for >60s, it was stable - reset backoff
    if [[ $run_duration -gt 60 ]]; then
        backoff=5
        echo "[INFO] EarnApp exited after ${run_duration}s, restarting in ${backoff}s..."
    else
        echo "[WARN] EarnApp crashed after ${run_duration}s, backing off ${backoff}s before restart..."
        sleep "$backoff"
        backoff=$((backoff * 2))
        [[ $backoff -gt $MAX_BACKOFF ]] && backoff=$MAX_BACKOFF
    fi
    
    "$BIN_PATH" stop 2>/dev/null || true
    sleep 1
done