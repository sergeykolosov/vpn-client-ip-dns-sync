#!/usr/bin/env bash
# vpn-client-ip-dns-sync.sh — Update a DigitalOcean DNS record when the VPN IP changes.
#
# Usage: vpn-client-ip-dns-sync.sh <iface> [--dry-run]
#
#   <iface>    VPN tunnel interface name (required, e.g. tun0)
#
# Install:
#   1. Copy to /usr/local/bin/vpn-client-ip-dns-sync.sh && chmod +x /usr/local/bin/vpn-client-ip-dns-sync.sh
#   2. Create /etc/vpn-client-ip-dns-sync.conf (see config section below)
#   3. Install the systemd template units: vpn-client-ip-dns-sync@.service / vpn-client-ip-dns-sync@.path
#   4. Enable per-interface: systemctl enable --now vpn-client-ip-dns-sync@tun0.path

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
CONF="/etc/vpn-client-ip-dns-sync.conf"
[[ -f "$CONF" ]] && source "$CONF"

DO_API_TOKEN="${DO_API_TOKEN:-}"
DOMAIN="${DOMAIN:-}"
RECORD_NAME="${RECORD_NAME:-}"
LOG_TAG="vpn-client-ip-dns-sync"

# ─── Parse args ───────────────────────────────────────────────────────────────
DRY_RUN=false
VPN_IFACE=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --*)       echo "Unknown option: $arg" >&2; exit 1 ;;
        *)         VPN_IFACE="$arg" ;;
    esac
done
[[ -z "$VPN_IFACE" ]] && { echo "Usage: $(basename "$0") <iface> [--dry-run]" >&2; exit 1; }

STATE_FILE="${STATE_FILE:-/var/lib/vpn-client-ip-dns-sync/${VPN_IFACE}.last_ip}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { logger -t "$LOG_TAG" "$*"; echo "$(date -Is) $*"; }
die()  { log "ERROR: $*"; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1"; }
require_cmd curl
require_cmd ip
require_cmd jq

[[ -z "$DO_API_TOKEN" ]] && die "DO_API_TOKEN is not set. Check $CONF"
[[ -z "$DOMAIN" ]]       && die "DOMAIN is not set. Check $CONF"
[[ -z "$RECORD_NAME" ]]  && die "RECORD_NAME is not set. Check $CONF"

# ─── Detect current VPN IP ───────────────────────────────────────────────────
get_vpn_ip() {
    # Extract the 'src' address for the VPN interface link route
    ip -4 addr show dev "$VPN_IFACE" 2>/dev/null \
        | awk '/inet / { split($2, a, "/"); print a[1]; exit }'
}

CURRENT_IP=$(get_vpn_ip)
if [[ -z "$CURRENT_IP" ]]; then
    log "Interface $VPN_IFACE has no IP yet — nothing to do."
    exit 0
fi

# ─── Check if IP has changed ──────────────────────────────────────────────────
mkdir -p "$(dirname "$STATE_FILE")"
LAST_IP=$(cat "$STATE_FILE" 2>/dev/null || true)

if [[ "$CURRENT_IP" == "$LAST_IP" ]]; then
    log "IP unchanged ($CURRENT_IP) — no update needed."
    exit 0
fi

log "IP changed: $LAST_IP -> $CURRENT_IP"

# ─── DigitalOcean API helpers ─────────────────────────────────────────────────
DO_API="https://api.digitalocean.com/v2"
AUTH_HEADER="Authorization: Bearer $DO_API_TOKEN"

do_get()  { curl -fsSL -H "$AUTH_HEADER" -H "Content-Type: application/json" "$DO_API/$1"; }
do_put()  { curl -fsSL -X PUT  -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$2" "$DO_API/$1"; }
do_post() { curl -fsSL -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$2" "$DO_API/$1"; }

# ─── Find or create the DNS record ───────────────────────────────────────────
log "Fetching DNS records for domain: $DOMAIN"
RECORDS=$(do_get "domains/${DOMAIN}/records?type=A&per_page=200")

RECORD_ID=$(echo "$RECORDS" | jq -r --arg name "$RECORD_NAME" \
    '.domain_records[] | select(.type=="A" and .name==$name) | .id' | head -1)

if $DRY_RUN; then
    log "[DRY-RUN] Would set $RECORD_NAME.$DOMAIN → $CURRENT_IP (record_id=${RECORD_ID:-NEW})"
    echo "$CURRENT_IP" > "$STATE_FILE"
    exit 0
fi

PAYLOAD=$(jq -nc --arg ip "$CURRENT_IP" --arg name "$RECORD_NAME" \
    '{"type":"A","name":$name,"data":$ip,"ttl":60}')

if [[ -n "$RECORD_ID" ]]; then
    log "Updating existing record $RECORD_ID → $CURRENT_IP"
    RESULT=$(do_put "domains/${DOMAIN}/records/${RECORD_ID}" "$PAYLOAD")
else
    log "Creating new A record $RECORD_NAME → $CURRENT_IP"
    RESULT=$(do_post "domains/${DOMAIN}/records" "$PAYLOAD")
fi

# Verify the API accepted it
UPDATED_IP=$(echo "$RESULT" | jq -r '.domain_record.data // empty')
if [[ "$UPDATED_IP" != "$CURRENT_IP" ]]; then
    die "API response mismatch — expected $CURRENT_IP, got: $UPDATED_IP"
fi

echo "$CURRENT_IP" > "$STATE_FILE"
log "Done. $RECORD_NAME.$DOMAIN → $CURRENT_IP"
