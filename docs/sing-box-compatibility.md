# sing-box compatibility

This CE update has been validated with sing-box **1.12.13** and
**1.15.0-alpha.4** on ImmortalWrt 24.10.4 / aarch64_generic. The latter is a
prerelease. Validation of a generated configuration is not a promise that
every node type or optional server feature works on every intermediate core.

## Changes

- Below 1.13, keep the existing DNS and inbound sniff configuration.
- From 1.13, use route `sniff` actions scoped to the proxy inbounds. The DNS
  inbound is excluded. The removed `sniff_override_destination` option has no
  exact equivalent in the new action; it remains effective only on old cores.
- From 1.14, move remote rule-set download routing from `download_detour`
  to `http_client.detour`, preserving the selected outbound. The tested 1.15
  core rejects the old field during startup even when `sing-box check` passes.
- Do not generate the invalid modern `rcode` DNS transport. DNS rules using
  the built-in `block-dns` server become `predefined` / `NXDOMAIN` rules.
  Using `block-dns` as a default or outbound resolver requires an explicit
  configuration change and produces a clear error instead of an invalid tag.
- Preserve outbound DNS rules and all additional match conditions during
  package migration. Do not silently turn a conditional rule into a resolver
  applying to all traffic from that outbound.
- Set `ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true` for both configuration
  validation and the procd-managed process. This is a deliberate compatibility
  bridge supported by the tested core; future cores may remove it.

Official HomeProxy master `edece28a0085f36d469ec82c8d45f562f602db53` still
generates legacy inbound sniff fields. Its automatic outbound DNS migration
can discard extra conditions, so that migration is not suitable for CE's
existing conditional rules.

## Validation

```sh
node --test tests/*.test.js
```

`tests/router-compat.py` runs real ucode generation and core `check` commands
without starting a candidate service. Prepare a private directory matching
`/tmp/homeproxy-ce-compat.*` on the router and extract the target OpenWrt IPK
under `core/` first. The 1.12 core must be installed at `/usr/bin/sing-box`.

```sh
python3 tests/router-compat.py /tmp/homeproxy-ce-compat.EXAMPLE \
  --jump-host user@jump-host --router root@router-address --migrate
```

The migration runs against a separate UCI directory with system cleanup
commands disabled. Tests compare current and regenerated configuration,
outbounds, DNS match conditions and routing decisions. Only the dynamically
discovered WAN DNS address is normalized when comparing with an older running
snapshot. Real configuration remains on the router; only counts and comparison
results are printed. Remove the temporary directory when finished.

Also validate actual startup and DNS, TCP and UDP traffic on isolated ports
before replacing a running core. Configuration checks alone do not exercise
all startup-time compatibility checks.

## Upstream references

- [HomeProxy source](https://github.com/immortalwrt/homeproxy/tree/edece28a0085f36d469ec82c8d45f562f602db53)
- [sing-box migration guide](https://sing-box.sagernet.org/migration/)
- [sing-box 1.15.0-alpha.4](https://github.com/SagerNet/sing-box/releases/tag/v1.15.0-alpha.4)
