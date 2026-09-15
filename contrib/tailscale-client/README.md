# Tailscale client sidecar example

This directory is an anonymized, tested sidecar layout. It is a deployment
template, not a general installer. Before deployment, replace every example
device pair, remote subnet, LAN bridge name, persistent mount path, hostname,
and binary path in `config.example.json`, `firewall.sh`, `forward.nft`, and
`init-homeproxy-tailscale` with the values for the target router. Keep the
same source-IP/source-MAC pairs in all three policy files. Do not copy a
state directory, token, or complete user configuration into this example.

## Scope and prerequisites

The example permits only `192.168.50.10`/`02:00:00:00:00:10` and
`192.168.50.11`/`02:00:00:00:00:11` to reach `192.168.6.0/24`. Other LAN
devices and other destinations are rejected. `notrack` applies only to those
two flows and their replies; the global DNS hijack and flow-offload settings
are left unchanged. The policy uses table 150, fwmark 1050, rule priority
1050, and UDP source port 41642 marked 100 so the sidecar control traffic
does not enter the existing proxy path.

The layout was validated with sing-box 1.15.0-alpha.4 (a prerelease). Check
configuration and runtime behavior when selecting another version. Use a
binary built for the router's OpenWrt architecture, with `with_tailscale`
and TUN support, at the configured binary path. Verify that table 150,
priority 1050, mark 1050, TUN name `hpts0` and UDP port 41642 are available.
The existing HomeProxy must exempt mark 100 from its self-proxy rules.
The persistent filesystem must be mounted
at the chosen data path before the service starts; configure the real UUID or
device in `/etc/config/fstab` and enable that mount. No credentials are
included here; authorize the endpoint after the state directory is mounted.
The mount entry must be equivalent to the following, with the target UUID or
device substituted and `enabled` set to `1`:

```uci
config mount 'homeproxy_ts_data'
        option target '/mnt/data'
        option uuid '<target-filesystem-uuid>'
        option fstype 'ext4'
        option enabled '1'
```

## Staging

After substituting target values, stage the files as follows (the commands
are examples and must be reviewed for the target router):

```sh
umask 077
mkdir -p /etc/homeproxy-tailscale /mnt/data/homeproxy-tailscale/state
mkdir -p /etc/hotplug.d/net /lib/upgrade/keep.d
cp config.example.json /etc/homeproxy-tailscale/config.json
cp firewall.sh forward.nft /etc/homeproxy-tailscale/
cp init-homeproxy-tailscale /etc/init.d/homeproxy-tailscale
cp 95-homeproxy-tailscale /etc/hotplug.d/net/95-homeproxy-tailscale
cp keep.d /lib/upgrade/keep.d/homeproxy-tailscale
chmod 700 /etc/homeproxy-tailscale /etc/homeproxy-tailscale/firewall.sh
chmod 600 /etc/homeproxy-tailscale/config.json /etc/homeproxy-tailscale/forward.nft
chmod 755 /etc/init.d/homeproxy-tailscale /etc/hotplug.d/net/95-homeproxy-tailscale
chmod 700 /mnt/data/homeproxy-tailscale /mnt/data/homeproxy-tailscale/state
```

Add the forward include before enabling the service. The include is placed in
fw4's `forward` chain-pre so the precise accepts run before its general
established-flow rule. The raw-prerouting `notrack` rules exclude these
specific flows from offload and NAT; chain-pre alone does not do that.
The script include restores the guard and route policy on firewall reload:

```sh
uci set firewall.homeproxy_tailscale_forward=include
uci set firewall.homeproxy_tailscale_forward.type=nftables
uci set firewall.homeproxy_tailscale_forward.path=/etc/homeproxy-tailscale/forward.nft
uci set firewall.homeproxy_tailscale_forward.position=chain-pre
uci set firewall.homeproxy_tailscale_forward.chain=forward
uci set firewall.homeproxy_tailscale_reload=include
uci set firewall.homeproxy_tailscale_reload.type=script
uci set firewall.homeproxy_tailscale_reload.path=/etc/homeproxy-tailscale/firewall.sh
uci set firewall.homeproxy_tailscale_reload.fw4_compatible=1
/etc/homeproxy-tailscale/firewall.sh reload
fw4 check
uci commit firewall
fw4 reload
```

Check the substituted configuration with the staged 1.15 binary, then enable
the service only after the data mount is enabled:

```sh
/mnt/data/homeproxy-tailscale/sing-box check -c /etc/homeproxy-tailscale/config.json
/etc/init.d/homeproxy-tailscale enable
/etc/init.d/homeproxy-tailscale start
```

Follow the login URL in `logread` to authorize this node in the same tailnet
as the remote subnet router. The remote router must already advertise the
target subnet with approval in the Tailscale console. Preserve the endpoint's
state directory and do not publish the local LAN. Test HTTP, UDP DNS and
ICMP from an allowed device, a denied-device case, and service stop/restart.

The service's `down` action deliberately leaves the mark rule and blackhole
route in place, so stopping the sidecar fails closed instead of falling back
to WAN. The hotplug hook restores the policy route after a TUN recreation;
`firewall.sh up` retries briefly when hpts0 exists but is still DOWN.

## Rollback

Save the target configuration and state metadata under a root-owned backup
directory before staging, for example `/root/homeproxy-tailscale-backup`.
To roll back, stop the service, remove the UCI include, reload fw4, and verify
that no authorized flow remains. Only then remove the sidecar nft table and
the priority-1050 rule/table, and remove the init and hotplug files. Preserve
the state backup unless the endpoint should also be logged out:

```sh
/etc/init.d/homeproxy-tailscale stop
/etc/init.d/homeproxy-tailscale disable
rm -f /etc/hotplug.d/net/95-homeproxy-tailscale
uci -q delete firewall.homeproxy_tailscale_forward
uci -q delete firewall.homeproxy_tailscale_reload
uci commit firewall
fw4 reload
nft delete table inet homeproxy_tailscale 2>/dev/null || true
ip rule del priority 1050 fwmark 1050 table 150 2>/dev/null || true
ip route flush table 150 2>/dev/null || true
```

Restore any mount settings you changed from the backup. Removing these
policies restores the router's previous routing behavior for the target
subnet; the rollback does not revoke the Tailscale node's identity.
