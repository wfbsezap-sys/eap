#!/usr/bin/env bash
# IP quality monitor - checks every 12h, kills container if proxy detected
set -uo pipefail

API_HOST="23.106.46.135"
API_PORT="8066"
API_PATH="/api/json/ip"
API_TOKEN="sk-ipqs-momo"
INTERVAL=$((12 * 3600))  # 12 hours

check_ip() {
    local resp
    resp=$(timeout --kill-after=3 15 bash -c '
        exec 3<>/dev/tcp/'"$API_HOST"'/'"$API_PORT"'
        printf "GET '"$API_PATH"' HTTP/1.1\r\nHost: '"$API_HOST"':'"$API_PORT"'\r\nAuthorization: Bearer '"$API_TOKEN"'\r\nConnection: close\r\n\r\n" >&3
        cat <&3
        exec 3>&-
    ' 2>/dev/null) || true

    if [[ -z "$resp" ]]; then
        echo "[IP-MON] API unreachable, skipping check"
        return 0  # don't kill on network error
    fi

    # Extract JSON body (last line after HTTP headers)
    local body
    body=$(echo "$resp" | tail -1)

    # Check proxy/vpn/tor fields
    local is_proxy is_vpn is_tor
    is_proxy=$(echo "$body" | grep -o '"proxy"[[:space:]]*:[[:space:]]*[a-z]*' | grep -o '[a-z]*$' || true)
    is_vpn=$(echo "$body" | grep -o '"vpn"[[:space:]]*:[[:space:]]*[a-z]*' | grep -o '[a-z]*$' || true)
    is_tor=$(echo "$body" | grep -o '"tor"[[:space:]]*:[[:space:]]*[a-z]*' | grep -o '[a-z]*$' || true)

    # Extract IP and location for logging
    local ip isp city country
    ip=$(echo "$body" | grep -o '"host"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)
    # Extract bare IP if host starts with digits (e.g. "1.2.3.4.example.com")
    if [[ "$ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        ip="${BASH_REMATCH[1]}"
    else
        ip="$ip"
    fi
    isp=$(echo "$body" | grep -o '"ISP"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)
    city=$(echo "$body" | grep -o '"city"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)
    country=$(echo "$body" | grep -o '"country_code"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)
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
