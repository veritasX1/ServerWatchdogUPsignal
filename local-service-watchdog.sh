#!/bin/bash
# Layer 1: periodically checks the systemd services in $SERVICES (see
# config.sh) and restarts any that are in "failed" state - catches the case
# where a service's own Restart=on-failure gave up after too many attempts
# in a short window (systemd's StartLimitBurst), which otherwise leaves it
# down indefinitely until someone notices manually.
#
# Also checks whether PRIMARY_DOMAIN's A record still matches this
# machine's actual public IPv4, and re-runs DNS_REPAIR_CMD if it's drifted.
# This is a *local* sanity check only - it can miss real external outages
# (see external-reachability-watchdog.sh and the README for why).

set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/config.sh"

LOG="${LOCAL_WATCHDOG_LOG:-/var/log/local-service-watchdog.log}"

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") $1" >> "$LOG"
}

for svc in $SERVICES; do
    if systemctl is-failed --quiet "$svc"; then
        log "$svc is failed, attempting restart"
        systemctl reset-failed "$svc"
        systemctl restart "$svc"
        sleep 3
        if systemctl is-active --quiet "$svc"; then
            log "$svc restarted successfully"
        else
            log "$svc restart FAILED - needs a manual look"
        fi
    fi
done

if [ -n "${PRIMARY_DOMAIN:-}" ] && [ -n "${DNS_REPAIR_CMD:-}" ]; then
    ACTUAL_V4=$(curl -sS --max-time 8 -4 https://ifconfig.me 2>/dev/null || true)
    DNS_V4=$(getent ahostsv4 "$PRIMARY_DOMAIN" 2>/dev/null | head -1 | awk '{print $1}')
    if [ -n "$ACTUAL_V4" ] && [ -n "$DNS_V4" ] && [ "$ACTUAL_V4" != "$DNS_V4" ]; then
        log "IPv4 drift detected (DNS=$DNS_V4, actual=$ACTUAL_V4), running DNS_REPAIR_CMD"
        eval "$DNS_REPAIR_CMD"
    fi
fi
