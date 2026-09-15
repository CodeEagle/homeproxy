# Tailscale subnet access

HomeProxy CE can run sing-box's userspace Tailscale endpoint. It is disabled
by default. When enabled, the endpoint advertises the configured LAN prefixes,
accepts no routes from other tailnet nodes, and sends only those advertised
prefixes to `direct-out`. Other connections arriving from Tailscale are
rejected before the normal HomeProxy routing rules. Existing DNS and client
traffic keep their current routing.

The shipped example advertises `192.168.6.0/24`. Replace it with the actual
LAN prefixes that this router should publish.

Enable it with UCI:

```sh
uci set homeproxy-ce.tailscale='homeproxy'
uci set homeproxy-ce.tailscale.enabled='1'
uci set homeproxy-ce.tailscale.hostname='immortalwrt-home'
uci -q delete homeproxy-ce.tailscale.advertise_routes
uci add_list homeproxy-ce.tailscale.advertise_routes='192.168.6.0/24'
uci set homeproxy-ce.config.log_level='info'
uci commit homeproxy-ce
/etc/init.d/homeproxy-ce restart
tail -f /var/run/homeproxy-ce/sing-box-c.log
```

The endpoint stores its identity in `/etc/homeproxy-ce/tailscale` with mode
`0700`. No auth key is stored. Sing-box logs an official Tailscale login URL
at `info` level in `/var/run/homeproxy-ce/sing-box-c.log`; open that URL and
approve the advertised subnet route separately in the Tailscale admin console.
After login, restore the normal log level:

```sh
uci set homeproxy-ce.config.log_level='warn'
uci commit homeproxy-ce
/etc/init.d/homeproxy-ce restart
```

The installed sing-box build must report the `with_tailscale` feature. If it
does not, generation fails with an actionable error instead of silently
starting without remote access.
