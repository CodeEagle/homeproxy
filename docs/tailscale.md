# Tailscale subnet access

## Two deployment roles

The built-in CE integration below publishes a router's LAN to its tailnet.
It is configured through UCI; this change does not add a LuCI Tailscale form.
It requires a sing-box binary compiled with `with_tailscale`.

For a second router that should let selected local devices access that remote
LAN, see the [restricted client example](../contrib/tailscale-client/README.md).
That example runs a separate sing-box instance alongside an existing HomeProxy
installation. It accepts the remote subnet route, publishes no local subnet,
and checks exact client IP/MAC pairs before forwarding traffic to a dedicated
TUN. Ordinary HomeProxy configuration and its running core are preserved.

## Publish a LAN from CE

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
On sing-box 1.14 and newer, the endpoint listens on UDP port `41641` by
default (`homeproxy-ce.tailscale.listen_port`). The value must be a numeric
port from 1 through 65535. When Tailscale is enabled, CE exempts UDP packets
from that source port before its own output transparent-proxy rules; this is
needed for direct Tailscale transport.
After login, restore the normal log level:

```sh
uci set homeproxy-ce.config.log_level='warn'
uci commit homeproxy-ce
/etc/init.d/homeproxy-ce restart
```

The installed sing-box build must report the `with_tailscale` feature. If it
does not, generation fails with an actionable error instead of silently
starting without remote access.

## Relay configuration and diagnosis

Custom DERP relays are configured in the Tailscale control plane's `derpMap`.
The official clients and the embedded endpoint receive that map from the same
tailnet. There is no phone JSON import step, and `relay_server_port` describes
peer relay service rather than a custom DERP map.

Check actual DERP connectivity in addition to STUN latency. In the tested
deployment, official STUN probes succeeded while the selected region's TCP
443 connection timed out repeatedly. Custom nodes configured with
`STUNPort: -1` were absent from STUN latency results. With successful STUN
results elsewhere, the client's HTTPS fallback measurement did not run.
Restricting that deployment to its verified custom DERP regions triggered
HTTPS measurement and restored a working home relay.

`OmitDefaultRegions: true` removes official DERP candidates from the whole
tailnet. Use it only as an intentional deployment choice after verifying the
custom relays. A working custom STUN service can allow latency measurement
while retaining official regions. No third-party relay addresses or tailnet
policy are installed by CE or the restricted client example.

Sources: [DERP configuration](https://tailscale.com/docs/reference/derp-servers),
[netcheck implementation](https://github.com/tailscale/tailscale/blob/main/net/netcheck/netcheck.go).
