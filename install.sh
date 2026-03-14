#!/usr/bin/env bash
# Run as root on the Ubuntu server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing dependencies"
apt-get install -y --no-install-recommends curl jq

echo "==> Copying main script"
install -m 755 "$SCRIPT_DIR/vpn-dns-sync.sh" /usr/local/bin/vpn-dns-sync.sh

echo "==> Creating state directory"
mkdir -p /var/lib/vpn-dns-sync

echo "==> Installing config (skip if already present)"
if [[ ! -f /etc/vpn-dns-sync.conf ]]; then
    install -m 600 "$SCRIPT_DIR/vpn-dns-sync.conf.example" /etc/vpn-dns-sync.conf
    echo "    Edit /etc/vpn-dns-sync.conf and set your DO_API_TOKEN, DOMAIN, etc."
else
    echo "    /etc/vpn-dns-sync.conf already exists — skipping."
fi

echo "==> Installing systemd units"
install -m 644 "$SCRIPT_DIR/systemd/vpn-dns-sync.service" /etc/systemd/system/vpn-dns-sync.service
install -m 644 "$SCRIPT_DIR/systemd/vpn-dns-sync.path"    /etc/systemd/system/vpn-dns-sync.path

echo "==> Installing networkd-dispatcher hook (fires on tun0 reconnect)"
mkdir -p /etc/networkd-dispatcher/routable.d
install -m 755 "$SCRIPT_DIR/systemd/networkd-dispatcher/50-vpn-dns-sync" \
    /etc/networkd-dispatcher/routable.d/50-vpn-dns-sync

echo "==> Installing OpenVPN up/down hooks"
mkdir -p /etc/openvpn/scripts
install -m 755 "$SCRIPT_DIR/openvpn/vpn-dns-sync-up.sh" /etc/openvpn/scripts/vpn-dns-sync-up.sh
echo "    Add to your OpenVPN client config:  script-security 2"
echo "                                         up /etc/openvpn/scripts/vpn-dns-sync-up.sh"

echo "==> Enabling and starting units"
systemctl daemon-reload
systemctl enable --now vpn-dns-sync.path
systemctl enable vpn-dns-sync.service   # service is triggered, not started directly

echo ""
echo "==> Test run (dry-run):"
/usr/local/bin/vpn-dns-sync.sh --dry-run || true

echo ""
echo "All done. Monitor with:  journalctl -t vpn-dns-sync -f"
