# ServerWatchdogUPsignal

Two-layer watchdog for a self-hosted server behind DynDNS: keep local
services running, and — the part most watchdog scripts skip — actually
verify that they're reachable from *outside* your network, then try to fix
it yourself before bothering you.

No paid or hosted third-party infrastructure. Both external calls it makes
(check-host.net, ntfy.sh) are free, anonymous, single-shot HTTP requests —
nothing runs or gets billed on your behalf.

## The problem this solves

A systemd service with `Restart=on-failure` recovers from most crashes on
its own. But two failure modes slip past that:

1. **systemd gives up.** After enough restart attempts in a short window
   (`StartLimitBurst`), systemd stops trying and leaves the service dead
   until someone notices. This has happened for real: an OOM-killed
   service stayed down for 6.5 hours overnight because of this.
2. **The service is running fine, but nobody outside your network can
   reach it.** DynDNS record drifted to a stale IP, router port-forwarding
   broke, ISP hiccup — the service itself is healthy, only the path to it
   is broken. And a check *from the server itself* can't reliably catch
   this: most home routers do NAT loopback/hairpinning, so a request from
   inside your LAN to your own public hostname gets silently routed back
   internally and can succeed even when a real visitor (or your phone on
   mobile data) gets nothing.

Layer 1 handles the first case. Layer 2 handles the second — by actually
checking from outside, then self-repairing.

## How it works

**Layer 1 — `local-service-watchdog.sh`** (run every 15 min): checks your
systemd `$SERVICES` list, restarts any in `failed` state. Also checks your
primary domain's A record against your real public IPv4 and re-runs your
`DNS_REPAIR_CMD` if it's drifted.

**Layer 2 — `external-reachability-watchdog.sh`** (run every 15 min):
checks `$EXTERNAL_URLS` via [check-host.net](https://check-host.net)'s free
API, which runs the request from several real external nodes — a genuine
outside vantage point, not this machine. If anything's down:

1. Runs `DNS_REPAIR_CMD` (fixes DNS drift) and layer 1's script (fixes a
   crashed local service).
2. Waits past your DNS TTL for propagation.
3. Checks again.
4. Only sends **one** [ntfy.sh](https://ntfy.sh) notification if it's
   *still* down after that — so a transient blip that self-heals stays
   silent, and a state that's already back up doesn't re-notify every
   cycle either.

## Setup

```bash
git clone https://github.com/<you>/ServerWatchdogUPsignal.git
cd ServerWatchdogUPsignal
cp config.example.sh config.sh
```

Edit `config.sh`:
- `SERVICES` — systemd unit names (no `.service`) layer 1 restarts if failed
- `PRIMARY_DOMAIN` / `DNS_REPAIR_CMD` — your DynDNS domain and the command
  that re-pushes its record (a curl call, ddclient, your provider's CLI —
  whatever you already use to keep it updated)
- `EXTERNAL_URLS` — public URLs layer 2 checks; only include ones that are
  actually finished and live, an incomplete setup just generates noise
- `NTFY_TOPIC` — pick something unguessable, ntfy.sh topics are public
  (`openssl rand -hex 6` works fine as a suffix)

```bash
chmod +x local-service-watchdog.sh external-reachability-watchdog.sh
sudo cp *.service.example *.timer.example /etc/systemd/system/
cd /etc/systemd/system
for f in local-service-watchdog external-reachability-watchdog; do
  mv "$f.service.example" "$f.service"
  mv "$f.timer.example" "$f.timer"
done
# edit the ExecStart= paths in both .service files to wherever you cloned this
sudo systemctl daemon-reload
sudo systemctl enable --now local-service-watchdog.timer external-reachability-watchdog.timer
```

Requires `jq` and `curl` (`sudo apt install jq curl` on Debian/Ubuntu).

On your phone: install the [ntfy app](https://ntfy.sh/) (or use the web
client) and subscribe to your `NTFY_TOPIC`.

## Notes

- Both watchdogs run as root (no `User=` in the example units) so they can
  `systemctl restart` arbitrary services and call `DNS_REPAIR_CMD` as
  whichever user needs to run it (see the `sudo -u` pattern in
  `config.example.sh`) without extra sudoers setup.
- check-host.net's plain `curl` endpoint serves an HTML/JS challenge form
  instead of JSON unless you send `Accept: application/json` — already
  handled in the script, just worth knowing if you extend it.
- A cloud-scheduled agent (e.g. a Claude Code routine) was tried first for
  layer 2 instead of a local script, specifically to get a genuinely
  external vantage point. It doesn't work for this: cloud sandboxes
  typically restrict outbound traffic to an allowlist of known package/API
  hosts and 403 arbitrary domains before the request ever leaves the
  sandbox. check-host.net sidesteps this by being an actual purpose-built
  external-check API instead of "any random cloud VM."

## License

MIT — see [LICENSE](LICENSE).
