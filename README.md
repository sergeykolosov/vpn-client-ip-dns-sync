# vpn-client-ip-dns-sync

A vibe-coded solution to sync a *private network* VPN client IP to a public DNS record.

Keeps a DigitalOcean DNS A record in sync with the current IP of a VPN tunnel interface on Ubuntu. Whenever the VPN reconnects and gets a new IP, the DNS record is updated automatically.

Uses systemd [template units](https://www.freedesktop.org/software/systemd/man/systemd.unit.html#Description), so the interface name is a parameter — just like `wg-quick@wg0` or `wpa_supplicant@wlan0`:

```bash
systemctl enable --now vpn-client-ip-dns-sync@tun0.path
```

## How it works

Three complementary triggers ensure no reconnect is ever missed:

| Trigger | What it catches |
| --- | --- |
| `vpn-client-ip-dns-sync@<iface>.path` (systemd) | Any IPv4 address add/remove (kernel rewrites `/proc/net/fib_trie`) |
| `networkd-dispatcher` hook | Interface going from "configuring" → "routable" |
| OpenVPN `up` script | Explicit VPN connect/reconnect event |

Each trigger starts `vpn-client-ip-dns-sync@<iface>.service`, which runs `vpn-client-ip-dns-sync.sh <iface>`:

1. Reads the current IP from the interface (`ip -4 addr show dev <iface>`)
2. Compares it to the last-known IP stored in `/var/lib/vpn-client-ip-dns-sync/<iface>.last_ip`
3. If changed, calls the DigitalOcean v2 DNS API to PUT (update) or POST (create) an A record with TTL 60s
4. Writes the new IP to the state file

If the IP hasn't changed, the script exits immediately — safe to trigger frequently.

## Requirements

- Ubuntu with systemd and `networkd-dispatcher`
- `curl` and `jq` (installed automatically by `install.sh`)
- A DigitalOcean personal access token with DNS write scope (`domain:create` + `domain:update`)
- The domain must already be managed in DigitalOcean DNS

## Repository layout

```text
vpn-client-ip-dns-sync/
├── install.sh                               # Installer — run as root on the target server
├── vpn-client-ip-dns-sync.sh                          # Main sync script
├── vpn-client-ip-dns-sync.conf.example                # Config template — copy to /etc/vpn-client-ip-dns-sync.conf
├── systemd/
│   ├── vpn-client-ip-dns-sync@.service                # Template service unit
│   ├── vpn-client-ip-dns-sync@.path                   # Template path unit (watches /proc/net/fib_trie)
│   └── networkd-dispatcher/
│       └── 50-vpn-client-ip-dns-sync                  # Hook: fires when any interface becomes routable
└── openvpn/
    └── vpn-client-ip-dns-sync-up.sh                   # Hook: fires on OpenVPN connect/reconnect
```

## Installation

```bash
# 1. Clone onto the target Ubuntu server
git clone <repo-url> vpn-client-ip-dns-sync
cd vpn-client-ip-dns-sync

# 2. Create and edit the config
sudo cp vpn-client-ip-dns-sync.conf.example /etc/vpn-client-ip-dns-sync.conf
sudo nano /etc/vpn-client-ip-dns-sync.conf   # fill in DO_API_TOKEN, DOMAIN, RECORD_NAME

# 3. Run the installer (default interface: tun0)
sudo bash install.sh

# For a different interface:
sudo bash install.sh wg0
```

After install, verify the path unit is active:

```bash
systemctl status vpn-client-ip-dns-sync@tun0.path
```

To enable for an additional interface later:

```bash
systemctl enable --now vpn-client-ip-dns-sync@tun1.path
```

## Configuration reference

Configured in `/etc/vpn-client-ip-dns-sync.conf` (sourced by the script as shell variables):

| Variable | Default | Description |
| --- | --- | --- |
| `DO_API_TOKEN` | *(required)* | DigitalOcean personal access token |
| `DOMAIN` | `example.com` | DNS zone as registered in DigitalOcean (e.g. `example.com`) |
| `RECORD_NAME` | `ubuntu-server.home.internal` | Subdomain stored in DO — everything left of the zone (e.g. for `ubuntu-server.home.internal.example.com` use `ubuntu-server.home.internal`) |

The interface is set by the systemd instance name (e.g. `@tun0`) — not in the config file. You can optionally override `STATE_FILE` in the config if you need a non-default path.

A scoped token (`domain:create` + `domain:update`) is safer than a full-access one.

## OpenVPN integration (optional)

To also trigger on OpenVPN connect/reconnect events, add these two lines to your client `.ovpn` or `.conf`:

```text
script-security 2
up /etc/openvpn/scripts/vpn-client-ip-dns-sync-up.sh
```

The hook uses OpenVPN's `$dev` variable (the tunnel interface name) to start the correct service instance automatically.

## Testing

```bash
# Safe dry-run — no API call, no state written
sudo /usr/local/bin/vpn-client-ip-dns-sync.sh tun0 --dry-run

# Force a real run (remove state file so the IP is seen as "changed")
sudo rm /var/lib/vpn-client-ip-dns-sync/tun0.last_ip
sudo /usr/local/bin/vpn-client-ip-dns-sync.sh tun0

# Watch live logs
journalctl -t vpn-client-ip-dns-sync -f
```

## Troubleshooting

| Message | Cause / Fix |
| --- | --- |
| `DO_API_TOKEN is not set` | `/etc/vpn-client-ip-dns-sync.conf` is missing or not readable by root |
| `Interface tun0 has no IP yet` | VPN is not connected; the service will retrigger on the next routing change |
| `API response mismatch` | Token lacks DNS write scope, or `DOMAIN` / `RECORD_NAME` are wrong |

Also check unit status:

```bash
systemctl status vpn-client-ip-dns-sync@tun0.path
systemctl status vpn-client-ip-dns-sync@tun0.service
```

## Uninstall

```bash
systemctl disable --now vpn-client-ip-dns-sync@tun0.path vpn-client-ip-dns-sync@tun0.service
rm /etc/systemd/system/vpn-client-ip-dns-sync@.{service,path}
rm /usr/local/bin/vpn-client-ip-dns-sync.sh
rm /etc/vpn-client-ip-dns-sync.conf
rm -rf /var/lib/vpn-client-ip-dns-sync
# Optional:
rm /etc/networkd-dispatcher/routable.d/50-vpn-client-ip-dns-sync
rm /etc/openvpn/scripts/vpn-client-ip-dns-sync-up.sh
systemctl daemon-reload
```
