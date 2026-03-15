#!/usr/bin/env bash
# EarnApp restart loop with graceful shutdown support
# Launched via exec env -i to keep /proc/self/environ clean
set -uo pipefail

BIN="${1:?Usage: earnapp_loop <binary_path>}"

backoff=5
MAX_BACKOFF=300
EARNAPP_PID=""

# Interruptible sleep: runs sleep in background so SIGTERM can break wait
isleep() { sleep "$1" & wait $!; }

# Graceful shutdown on SIGTERM/SIGINT (forwarded by tini from docker stop)
cleanup() {
    echo "[INFO] Received shutdown signal, stopping EarnApp..."
    if [[ -n "$EARNAPP_PID" ]] && kill -0 "$EARNAPP_PID" 2>/dev/null; then
        kill -TERM "$EARNAPP_PID" 2>/dev/null || true
        # Wait up to 10s for graceful exit
        for _ in $(seq 1 20); do
            kill -0 "$EARNAPP_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$EARNAPP_PID" 2>/dev/null || true
    fi
    timeout 5 "$BIN" stop 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

while true; do
    # Check if IP monitor flagged this IP as proxy
    if [[ -f /tmp/.ip_stop ]]; then
        echo "[IP-MON] Proxy IP detected, refusing to start. Container exiting."
        exit 1
    fi

    "$BIN" start || true
    isleep 2

    # Run in background so trap can interrupt wait on signal
    start_time=$(date +%s)
    "$BIN" run &
    EARNAPP_PID=$!
    wait "$EARNAPP_PID" 2>/dev/null || true
    EARNAPP_PID=""
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
        isleep "$backoff"
        backoff=$((backoff * 2))
        [[ $backoff -gt $MAX_BACKOFF ]] && backoff=$MAX_BACKOFF
    fi

    timeout 10 "$BIN" stop 2>/dev/null || true
    isleep 1
done
