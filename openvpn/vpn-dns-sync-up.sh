#!/bin/sh
# Sourced by OpenVPN with env vars set. Small delay lets the route settle.
sleep 2 && /usr/local/bin/vpn-dns-sync.sh &
