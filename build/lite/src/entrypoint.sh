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

# 5. Spoof Docker MAC address (02:42:ac:* is a dead giveaway)
#    Replace with realistic Intel OUI (f8:75:a4) + stable suffix from UUID
#    Includes connectivity verification with rollback on failure
ETH_DEV=$(ip -o link show | awk -F'[: @]+' '/eth0/{print $2}' | head -1)
if [[ -n "$ETH_DEV" ]]; then
    CURRENT_MAC=$(cat /sys/class/net/"$ETH_DEV"/address 2>/dev/null || true)
    if [[ "$CURRENT_MAC" == 02:42:ac:* ]]; then
        ORIG_MAC="$CURRENT_MAC"
        MAC_HASH=$(echo -n "$EARNAPP_UUID" | md5sum | cut -c1-6)
        NEW_MAC="f8:75:a4:${MAC_HASH:0:2}:${MAC_HASH:2:2}:${MAC_HASH:4:2}"
        DEFAULT_GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)

        ip link set dev "$ETH_DEV" down 2>/dev/null || true
        ip link set dev "$ETH_DEV" address "$NEW_MAC" 2>/dev/null || true
        ip link set dev "$ETH_DEV" up 2>/dev/null || true

        # Restore default route if lost
        if [[ -n "$DEFAULT_GW" ]] && ! ip route show default 2>/dev/null | grep -q .; then
            ip route add default via "$DEFAULT_GW" 2>/dev/null || true
        fi

        # Verify network connectivity; rollback MAC if broken
        sleep 1
        if ! curl -s --connect-timeout 5 --max-time 8 -o /dev/null http://1.1.1.1 2>/dev/null; then
            echo "[WARN] Network broken after MAC spoof, rolling back to $ORIG_MAC"
            ip link set dev "$ETH_DEV" down 2>/dev/null || true
            ip link set dev "$ETH_DEV" address "$ORIG_MAC" 2>/dev/null || true
            ip link set dev "$ETH_DEV" up 2>/dev/null || true
            if [[ -n "$DEFAULT_GW" ]] && ! ip route show default 2>/dev/null | grep -q .; then
                ip route add default via "$DEFAULT_GW" 2>/dev/null || true
            fi
        fi

        unset DEFAULT_GW ORIG_MAC
    fi
    unset CURRENT_MAC MAC_HASH NEW_MAC ETH_DEV
fi

# 6. Mask /proc/mounts and /proc/1/mountinfo (overlay2/docker paths leak)
#    Create a background refresher so the bind mount stays realistic
refresh_fake_mounts() {
    sed -e 's|overlay|/dev/sda1|g' \
        -e 's|/var/lib/docker/overlay2/[^,]*|/|g' \
        -e 's|workdir=[^,)]*||g' \
        -e 's|upperdir=[^,)]*||g' \
        -e 's|lowerdir=[^,)]*||g' \
        -e 's|,,*|,|g' -e 's|,([ )]|\1|g' \
        /proc/self/mounts > /tmp/.fake_mounts_new 2>/dev/null || return 1
    mv -f /tmp/.fake_mounts_new /tmp/.fake_mounts 2>/dev/null || return 1
}

if grep -q 'docker\|overlay' /proc/mounts 2>/dev/null; then
    refresh_fake_mounts || true
    mount --bind /tmp/.fake_mounts /proc/mounts 2>/dev/null || true

    # Periodically refresh the fake mounts (every 6h) so it doesn't look frozen
    (while true; do sleep 21600; refresh_fake_mounts 2>/dev/null || true; done) &
fi
if [[ -f /proc/1/mountinfo ]] && grep -q 'docker\|overlay' /proc/1/mountinfo 2>/dev/null; then
    sed -e 's|/var/lib/docker/overlay2/[^ ]*|/dev/sda1|g' \
        -e 's|overlay|ext4|g' \
        /proc/1/mountinfo > /tmp/.fake_mountinfo 2>/dev/null || true
    mount --bind /tmp/.fake_mountinfo /proc/1/mountinfo 2>/dev/null || true
fi

# 7. Spawn dummy background processes to pad the /proc scan
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

# 8. Clean environment variables that leak container info
#    Docker injects HOME, HOSTNAME, PATH with container-specific values;
#    also remove our own config vars from the environment
unset DEBIAN_FRONTEND 2>/dev/null || true
# MALLOC_ARENA_MAX is passed through exec env -i to limit glibc memory fragmentation

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
# Start IP quality monitor (background, with auto-respawn)
# --------------------------
(while true; do
    /usr/local/bin/_ip_monitor
    # If ip_monitor exited with 1 (proxy detected), propagate the stop
    [[ -f /tmp/.ip_stop ]] && break
    echo "[WARN] ip_monitor exited unexpectedly, restarting in 30s..."
    sleep 30
done) &

# --------------------------
# Clean environment and start EarnApp
# --------------------------
# /proc/1/environ is frozen at process start and cannot be unset.
# Use exec env -i to replace this process with a clean environment, so
# /proc/self/environ won't leak EARNAPP_UUID etc.
echo "[INFO] Starting EarnApp..."
"$BIN_PATH" stop 2>/dev/null || true
sleep 1

exec env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-xterm}" \
    MALLOC_ARENA_MAX=2 \
    bash /usr/local/bin/_earnapp_loop "$BIN_PATH"
