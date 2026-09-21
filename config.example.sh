#!/bin/bash
# Copy this to config.sh (same directory as the two watchdog scripts) and
# fill in your own values. config.sh is gitignored - it holds your domain,
# service list and ntfy.sh topic, nothing secret, but no reason to publish it.

# --- Layer 1: local-service-watchdog.sh ---
# systemd unit names (without ".service") this watchdog restarts if they're
# in "failed" state. Add every long-running service you rely on.
SERVICES="nginx myapp docker"

# --- Both layers: DNS drift repair ---
# Your externally-reachable domain (the one your DynDNS/dyndns-like client
# actually updates). Used by layer 1 to detect IPv4 drift on the primary
# domain, and by layer 2 as the trigger to re-push DNS after ANY of the
# EXTERNAL_URLS below is found unreachable.
PRIMARY_DOMAIN="example.dyndns-provider.org"

# Shell command that re-pushes your DynDNS record(s). Whatever your provider
# needs - a curl call, ddclient, a vendor CLI. Runs as root; drop to another
# user with `sudo -u youruser ...` inside the command if it needs that
# user's credentials file (see this project's own goip.de example for why).
DNS_REPAIR_CMD='sudo -u youruser /home/youruser/bin/update_dns.sh'

# --- Layer 2: external-reachability-watchdog.sh ---
# Public URLs to check from outside your network. Only add ones that are
# actually finished/live - an incomplete setup (no DNS/cert/backend yet)
# will just generate permanent noise.
EXTERNAL_URLS="https://example.dyndns-provider.org/ https://app.example.dyndns-provider.org/"

# ntfy.sh topic for the "still down after repair" alert. Pick something
# unguessable (topics are public - anyone who knows the name can read it,
# or in a self-hosted ntfy instance, post to it) - e.g.:
#   NTFY_TOPIC="myserver-$(openssl rand -hex 6)"
NTFY_TOPIC="CHANGE-ME-$(openssl rand -hex 6 2>/dev/null || echo unguessable)"

# Optional: point at a self-hosted ntfy instance instead of ntfy.sh.
NTFY_URL="https://ntfy.sh"
