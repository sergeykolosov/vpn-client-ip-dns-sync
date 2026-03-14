#!/usr/bin/env bash
# Run as root on the Ubuntu server.
#
# Usage: sudo bash install.sh [<iface>]
#
#   <iface>   VPN tunnel interface to enable (default: tun0)
#             e.g.: sudo bash install.sh wg0
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IFACE="${1:-tun0}"

echo "==> Installing dependencies"
apt-get install -y --no-install-recommends curl jq

echo "==> Copying main script"
install -m 755 "$SCRIPT_DIR/vpn-client-ip-dns-sync.sh" /usr/local/bin/vpn-client-ip-dns-sync.sh

echo "==> Creating state directory"
mkdir -p /var/lib/vpn-client-ip-dns-sync

echo "==> Installing config (skip if already present)"
if [[ ! -f /etc/vpn-client-ip-dns-sync.conf ]]; then
    install -m 600 "$SCRIPT_DIR/vpn-client-ip-dns-sync.conf.example" /etc/vpn-client-ip-dns-sync.conf
    echo "    Edit /etc/vpn-client-ip-dns-sync.conf and set your DO_API_TOKEN, DOMAIN, etc."
else
    echo "    /etc/vpn-client-ip-dns-sync.conf already exists — skipping."
fi

echo "==> Installing systemd template units"
install -m 644 "$SCRIPT_DIR/systemd/vpn-client-ip-dns-sync@.service" /etc/systemd/system/vpn-client-ip-dns-sync@.service
install -m 644 "$SCRIPT_DIR/systemd/vpn-client-ip-dns-sync@.path"    /etc/systemd/system/vpn-client-ip-dns-sync@.path

echo "==> Installing networkd-dispatcher hook"
mkdir -p /etc/networkd-dispatcher/routable.d
install -m 755 "$SCRIPT_DIR/systemd/networkd-dispatcher/50-vpn-client-ip-dns-sync" \
    /etc/networkd-dispatcher/routable.d/50-vpn-client-ip-dns-sync

echo "==> Installing OpenVPN up hook"
mkdir -p /etc/openvpn/scripts
install -m 755 "$SCRIPT_DIR/openvpn/vpn-client-ip-dns-sync-up.sh" /etc/openvpn/scripts/vpn-client-ip-dns-sync-up.sh
echo "    Add to your OpenVPN client config:  script-security 2"
echo "                                         up /etc/openvpn/scripts/vpn-client-ip-dns-sync-up.sh"

echo "==> Enabling and starting units for interface: $IFACE"
systemctl daemon-reload
systemctl enable --now "vpn-client-ip-dns-sync@${IFACE}.path"
systemctl enable "vpn-client-ip-dns-sync@${IFACE}.service"   # service is triggered, not started directly

echo ""
echo "==> Test run (dry-run on $IFACE):"
/usr/local/bin/vpn-client-ip-dns-sync.sh "$IFACE" --dry-run || true

echo ""
echo "All done. Monitor with:  journalctl -t vpn-client-ip-dns-sync -f"
echo "To enable for another interface:  systemctl enable --now vpn-client-ip-dns-sync@<iface>.path"
