#!/bin/sh
# Called by OpenVPN on connect. $dev is the tunnel interface name (e.g. tun0).
# Small delay lets the route settle before the sync runs.
sleep 2 && systemctl start "vpn-client-ip-dns-sync@${dev}.service" &
