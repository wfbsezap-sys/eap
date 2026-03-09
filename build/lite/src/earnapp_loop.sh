#!/usr/bin/env bash
# EarnApp restart loop - launched via exec env -i to keep /proc/1/environ clean
set -uo pipefail

BIN="${1:?Usage: earnapp_loop <binary_path>}"

backoff=5
MAX_BACKOFF=300

while true; do
    # Check if IP monitor flagged this IP as proxy
    if [[ -f /tmp/.ip_stop ]]; then
        echo "[IP-MON] Proxy IP detected, refusing to start. Container exiting."
        exit 1
    fi

    "$BIN" start || true
    sleep 2

    # Run in foreground, will block until exit
    start_time=$(date +%s)
    "$BIN" run || true
    run_duration=$(( $(date +%s) - start_time ))

    # Check stop flag again after earnapp exits
    if [[ -f /tmp/.ip_stop ]]; then
        echo "[IP-MON] Proxy IP detected, container exiting."
        exit 1
    fi

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

    "$BIN" stop 2>/dev/null || true
    sleep 1
done
