# vpn-dns-sync

Keeps a DigitalOcean DNS A record in sync with the current IP of an OpenVPN `tun0` interface on Ubuntu. Whenever the VPN reconnects and gets a new IP, the DNS record is updated automatically — no manual intervention needed.

## How it works

Three complementary triggers ensure no reconnect is ever missed:

| Trigger | What it catches |
|---|---|
| `vpn-dns-sync.path` (systemd) | Any IPv4 address add/remove (kernel rewrites `/proc/net/fib_trie`) |
| `networkd-dispatcher` hook | Interface going from "configuring" → "routable" |
| OpenVPN `up` script | Explicit VPN connect/reconnect event |

Each trigger runs `vpn-dns-sync.sh`, which:

1. Reads the current IP from the VPN interface (`ip -4 addr show dev tun0`)
2. Compares it to the last-known IP stored in `/var/lib/vpn-dns-sync/last_ip`
3. If changed, calls the DigitalOcean v2 DNS API to PUT (update) or POST (create) an A record with TTL 60s
4. Writes the new IP to the state file

If the IP hasn't changed, the script exits immediately — making it safe to trigger frequently.

## Requirements

- Ubuntu with systemd and `networkd-dispatcher`
- `curl` and `jq` (installed automatically by `install.sh`)
- A DigitalOcean personal access token with DNS write scope (`domain:create` + `domain:update`)
- The domain must already be managed in DigitalOcean DNS

## Repository layout

```
vpn-dns-sync/
├── install.sh                               # Installer — run as root on the target server
├── vpn-dns-sync.sh                          # Main sync script
├── vpn-dns-sync.conf.example                # Config template — copy to /etc/vpn-dns-sync.conf
├── systemd/
│   ├── vpn-dns-sync.service                 # Oneshot service unit
│   ├── vpn-dns-sync.path                    # Path unit (watches /proc/net/fib_trie)
│   └── networkd-dispatcher/
│       └── 50-vpn-dns-sync                  # Hook: fires when an interface becomes routable
└── openvpn/
    └── vpn-dns-sync-up.sh                   # Hook: fires on OpenVPN connect/reconnect
```

## Installation

```bash
# 1. Clone onto the target Ubuntu server
git clone <repo-url> vpn-dns-sync
cd vpn-dns-sync

# 2. Create and edit the config
sudo cp vpn-dns-sync.conf.example /etc/vpn-dns-sync.conf
sudo nano /etc/vpn-dns-sync.conf   # fill in DO_API_TOKEN, DOMAIN, RECORD_NAME

# 3. Run the installer
sudo bash install.sh
```

After install, verify the path unit is active:

```bash
systemctl status vpn-dns-sync.path
```

## Configuration reference

Configured in `/etc/vpn-dns-sync.conf` (sourced by the script as shell variables):

| Variable | Default | Description |
|---|---|---|
| `DO_API_TOKEN` | *(required)* | DigitalOcean personal access token |
| `DOMAIN` | `example.com` | DNS zone as registered in DigitalOcean (e.g. `example.com`) |
| `RECORD_NAME` | `ubuntu-server.home.internal` | Subdomain stored in DO — everything left of the zone (e.g. for `ubuntu-server.home.internal.example.com` use `ubuntu-server.home.internal`) |
| `VPN_IFACE` | `tun0` | Kernel interface name of the VPN tunnel |
| `STATE_FILE` | `/var/lib/vpn-dns-sync/last_ip` | Path to the last-known-IP cache file |

A scoped token (`domain:create` + `domain:update`) is safer than a full-access one.

## OpenVPN integration (optional)

To also trigger on OpenVPN connect/reconnect events, add these two lines to your client `.ovpn` or `.conf`:

```
script-security 2
up /etc/openvpn/scripts/vpn-dns-sync-up.sh
```

The `install.sh` script installs the hook automatically; you just need to add the directives to the OpenVPN config.

## Interface name note

The networkd-dispatcher hook at `/etc/networkd-dispatcher/routable.d/50-vpn-dns-sync` has the interface name `tun0` hardcoded — it runs before the config is sourced. If you use a different interface, edit that file manually after running `install.sh`.

## Testing

```bash
# Safe dry-run — no API call, no state written
sudo /usr/local/bin/vpn-dns-sync.sh --dry-run

# Force a real run (remove state file so the IP is seen as "changed")
sudo rm /var/lib/vpn-dns-sync/last_ip
sudo /usr/local/bin/vpn-dns-sync.sh

# Watch live logs
journalctl -t vpn-dns-sync -f
```

## Troubleshooting

| Message | Cause / Fix |
|---|---|
| `DO_API_TOKEN is not set` | `/etc/vpn-dns-sync.conf` is missing or not readable by root |
| `Interface tun0 has no IP yet` | VPN is not connected; the service will retrigger on the next routing change |
| `API response mismatch` | Token lacks DNS write scope, or `DOMAIN` / `RECORD_NAME` are wrong |

Also check unit status:

```bash
systemctl status vpn-dns-sync.path
systemctl status vpn-dns-sync.service
```

## Uninstall

```bash
systemctl disable --now vpn-dns-sync.path vpn-dns-sync.service
rm /etc/systemd/system/vpn-dns-sync.{service,path}
rm /usr/local/bin/vpn-dns-sync.sh
rm /etc/vpn-dns-sync.conf
rm -rf /var/lib/vpn-dns-sync
# Optional:
rm /etc/networkd-dispatcher/routable.d/50-vpn-dns-sync
rm /etc/openvpn/scripts/vpn-dns-sync-up.sh
systemctl daemon-reload
```
