#!/bin/bash
# Layer 2: checks whether $EXTERNAL_URLS (see config.sh) are reachable from
# OUTSIDE your network, using check-host.net's free multi-node API - not a
# check from this machine itself.
#
# Why not just curl the URLs locally? Many home routers do NAT loopback/
# hairpinning: a request from inside your LAN to your own public hostname
# gets silently routed back internally and can succeed even when your
# DynDNS record has drifted, your port-forwarding is broken, or your ISP
# is having issues - none of which a local check can see. check-host.net
# runs the request from real external nodes, so it actually proves what a
# visitor (or your phone on mobile data) would experience.
#
# On a detected outage, this does NOT just notify - it first tries to fix
# itself: reruns DNS_REPAIR_CMD (covers DNS drift) and this project's own
# local-service-watchdog.sh (covers a crashed local service), waits past
# your DNS TTL for propagation, then checks again. Only if it's STILL down
# after that does it send one ntfy.sh notification - so a transient blip
# that self-heals stays silent, and you only hear about it when it
# genuinely needs your attention.
#
# check-host.net and ntfy.sh are both free, anonymous, single-shot HTTP
# calls - no signup, no account, nothing running/billed on your behalf.

set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$SCRIPT_DIR/config.sh"

STATE_DIR="${STATE_DIR:-/var/lib/external-reachability-watchdog}"
STATE_FILE="$STATE_DIR/down_hosts"
LOG="${EXTERNAL_WATCHDOG_LOG:-/var/log/external-reachability-watchdog.log}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") $1" >> "$LOG"
}

notify() {
    curl -s -m 10 -d "$1" "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1
}

# Checks the given URLs, prints the unreachable ones (space-separated) to
# stdout. Kept side-effect-free (besides logging) so it can be reused for
# the post-repair re-check.
check_urls() {
    local down=""
    for url in "$@"; do
        local req request_id result total ok
        req=$(curl -s -m 10 "https://check-host.net/check-http?host=${url}&max_nodes=3" -H "Accept: application/json")
        request_id=$(echo "$req" | jq -r '.request_id // empty')
        if [ -z "$request_id" ]; then
            log "check-host.net request failed for $url, skipping (not counted as down)"
            continue
        fi
        # Give check-host.net's nodes time to finish (some checks, e.g. a
        # connection timeout, take several seconds per node).
        sleep 8
        result=$(curl -s -m 10 "https://check-host.net/check-result/${request_id}")
        # A node still mid-check reports null instead of an array - bail
        # out on that rather than letting jq crash and silently treating
        # it as "up".
        if ! echo "$result" | jq -e '[.[][]?] | length > 0' >/dev/null 2>&1; then
            log "check-host.net result for $url incomplete/invalid, skipping (not counted as down): $result"
            continue
        fi
        total=$(echo "$result" | jq '[.[][]?] | length')
        # Node result shape: [success(0/1), latency, status_text, http_code, ip].
        # http_code ([3]) is the thing to check - status_text ([2]) is "OK"
        # for 200 but e.g. "Found" for a 302, so matching on the text would
        # wrongly flag healthy redirects as down.
        ok=$(echo "$result" | jq '[.[][]? | select(.[3] != null and (.[3] | tonumber) >= 200 and (.[3] | tonumber) < 400)] | length')
        if [ "$total" -eq 0 ] || [ "$ok" -lt $(( (total + 1) / 2 )) ]; then
            down="$down $url"
        fi
    done
    echo "$down" | xargs
}

repair() {
    log "Attempting repair: DNS_REPAIR_CMD + local-service-watchdog.sh"
    if [ -n "${DNS_REPAIR_CMD:-}" ]; then
        eval "$DNS_REPAIR_CMD" >>"$LOG" 2>&1 || log "DNS_REPAIR_CMD reported an error (see above)"
    fi
    "$SCRIPT_DIR/local-service-watchdog.sh" || log "local-service-watchdog.sh reported an error"
    # DNS propagation and service restarts need time - wait comfortably
    # past your DNS TTL (60-90s covers most default DynDNS TTLs).
    sleep 75
}

now_down=$(check_urls $EXTERNAL_URLS)

if [ -n "$now_down" ]; then
    log "DOWN detected: $now_down"
    repair
    still_down=$(check_urls $now_down)
    if [ -n "$still_down" ]; then
        log "still down after repair attempt: $still_down"
        notify "$(basename "$PWD"): unreachable from outside, repair did not fix it: $still_down"
    else
        log "repair succeeded, reachable again: $now_down"
    fi
    now_down="$still_down"
fi

prev_down=$(cat "$STATE_FILE")
if [ "$now_down" != "$prev_down" ] && [ -z "$now_down" ] && [ -n "$prev_down" ]; then
    log "State change: everything reachable again (was: $prev_down)"
    notify "Reachable again from outside (was down: $prev_down)"
fi
echo "$now_down" > "$STATE_FILE"
