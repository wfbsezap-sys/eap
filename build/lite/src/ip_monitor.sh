#!/usr/bin/env bash
# IP quality monitor - checks every 12h, kills container if proxy detected
set -uo pipefail

API_HOST="${IPMON_API_HOST:-23.106.46.135}"
API_PORT="${IPMON_API_PORT:-8066}"
API_PATH="${IPMON_API_PATH:-/api/json/ip}"
API_TOKEN="${IPMON_API_TOKEN:-sk-ipqs-momo}"
INTERVAL=$((12 * 3600))  # 12 hours

# Lightweight JSON string field extractor (no jq dependency)
# Usage: json_str 'fieldname' <<< "$json"
# Handles: "field": "value" and "field" : "value" (with optional spaces)
json_str() {
    local key="$1"
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Lightweight JSON bool/number field extractor
# Usage: json_val 'fieldname' <<< "$json"
json_val() {
    local key="$1"
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([a-z0-9.]*\).*/\1/p' | head -1
}

check_ip() {
    local body
    body=$(curl -s --connect-timeout 10 --max-time 15 \
        -H "Authorization: Bearer $API_TOKEN" \
        "http://${API_HOST}:${API_PORT}${API_PATH}" 2>/dev/null) || true

    if [[ -z "$body" ]]; then
        echo "[IP-MON] API unreachable, skipping check"
        return 0  # don't kill on network error
    fi

    # Check proxy/vpn/tor fields
    local is_proxy is_vpn is_tor
    is_proxy=$(json_val proxy <<< "$body")
    is_vpn=$(json_val vpn <<< "$body")
    is_tor=$(json_val tor <<< "$body")

    # Extract IP and location for logging
    local ip isp city country
    ip=$(json_str host <<< "$body")
    # Extract bare IP if host starts with digits (e.g. "1.2.3.4.example.com")
    if [[ "$ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        ip="${BASH_REMATCH[1]}"
    fi
    isp=$(json_str ISP <<< "$body")
    city=$(json_str city <<< "$body")
    country=$(json_str country_code <<< "$body")

    local label="${ip:-unknown}"
    [[ -n "$city" || -n "$country" ]] && label="$label (${city:+$city, }${country:-})"
    [[ -n "$isp" ]] && label="$label - $isp"

    if [[ "$is_proxy" == "true" || "$is_vpn" == "true" || "$is_tor" == "true" ]]; then
        echo "[IP-MON] PROXY DETECTED! $label | proxy=${is_proxy} vpn=${is_vpn} tor=${is_tor}"
        echo "[IP-MON] Stopping container..."
        touch /tmp/.ip_stop
        # Kill earnapp binary so the loop wakes up and sees the stop flag
        pkill -9 -f earnapp 2>/dev/null || killall -9 earnapp 2>/dev/null || true
        exit 1
    else
        echo "[IP-MON] IP OK: $label (proxy=${is_proxy:-false} vpn=${is_vpn:-false})"
    fi
}

# Initial check after 60s (let network settle)
sleep 60
check_ip

# Then every 12 hours
while true; do
    sleep "$INTERVAL"
    check_ip
done
