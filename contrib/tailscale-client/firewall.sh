#!/bin/sh
set -eu

TABLE=150
PREFIX=192.168.6.0/24
TUN=hpts0

guard() {
    # Replace only this table in one transaction; never flush the host ruleset.
    {
        if nft list table inet homeproxy_tailscale >/dev/null 2>&1; then
            echo 'delete table inet homeproxy_tailscale'
        fi
        cat <<'NFT'
table inet homeproxy_tailscale {
    set clients {
        type ipv4_addr . ether_addr
        elements = { 192.168.50.10 . 02:00:00:00:00:10, 192.168.50.11 . 02:00:00:00:00:11 }
    }
    chain select_mac {
        type filter hook prerouting priority -310; policy accept;
        ip daddr 192.168.6.0/24 iifname != "br-lan" counter drop
        iifname "br-lan" ip daddr 192.168.6.0/24 ip saddr . ether saddr != @clients counter drop
        # Keep only this selected LAN-to-home flow outside conntrack, fw4
        # flow offload, and the LAN-wide DNS redirect path.
        iifname "br-lan" ip saddr . ether saddr @clients ip daddr 192.168.6.0/24 counter notrack meta mark set 1050
        iifname "hpts0" ip saddr 192.168.6.0/24 ip daddr { 192.168.50.10, 192.168.50.11 } counter notrack
    }
    chain output {
        type route hook output priority -151; policy accept;
        udp sport 41642 counter meta mark set 100
        ip daddr 192.168.6.0/24 counter drop
    }
    chain forward_guard {
        type filter hook forward priority -1; policy accept;
        ip daddr 192.168.6.0/24 oifname != "hpts0" counter drop
        iifname "hpts0" ip daddr != { 192.168.50.10, 192.168.50.11 } counter drop
    }
}
NFT
    } | nft -f -

    # Keep a blackhole in the policy table when hpts0 is absent, preventing
    # the ordinary WAN default route from becoming a fallback.
    ip route replace blackhole default table "$TABLE" metric 42760
    if ! ip rule show | grep -q '^1050:.*fwmark 0x41a.*lookup 150'; then
        ip rule add priority 1050 fwmark 1050 table "$TABLE"
    fi
}

case "${1:-reload}" in
    up)
        guard
        attempts=0
        # hpts0 may exist while still DOWN after a procd start; retry the
        # route until the kernel accepts it or fail closed after 20 seconds.
        until ip route replace "$PREFIX" dev "$TUN" table "$TABLE" metric 10 2>/dev/null; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 20 ] || exit 1
            sleep 1
        done
        ;;
    down)
        guard
        ip route del "$PREFIX" dev "$TUN" table "$TABLE" metric 10 2>/dev/null || true
        ;;
    reload)
        guard
        if ip link show "$TUN" >/dev/null 2>&1; then
            ip route replace "$PREFIX" dev "$TUN" table "$TABLE" metric 10 2>/dev/null || true
        fi
        ;;
    *)
        exit 2
        ;;
esac
