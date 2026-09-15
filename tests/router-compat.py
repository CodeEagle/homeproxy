#!/usr/bin/env python3
"""Generate in an isolated router directory; never start a candidate service.

Usage: python3 tests/router-compat.py REMOTE_TMP [--baseline]
Requires an extracted 1.15 OpenWrt core at REMOTE_TMP/core/usr/bin/sing-box.
Only structure/counts are printed; real UCI configuration stays on the router.
"""
import argparse
import collections
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory')
parser.add_argument('--baseline', action='store_true')
parser.add_argument('--migrate', action='store_true', help='run package migration on a private UCI copy first')
parser.add_argument('--jump-host', default=os.environ.get('HOMEPROXY_TEST_JUMP_HOST'),
                    help='SSH jump host (or HOMEPROXY_TEST_JUMP_HOST)')
parser.add_argument('--router', default='root@192.168.6.1', help='SSH target reachable from the jump host')
args = parser.parse_args()
if not args.jump_host:
    parser.error('--jump-host or HOMEPROXY_TEST_JUMP_HOST is required')
if not re.fullmatch(r'/tmp/homeproxy-ce-compat\.[A-Za-z0-9]+', args.directory):
    parser.error('expected a dedicated /tmp/homeproxy-ce-compat.* directory')
repo = Path(__file__).resolve().parents[1]


def remote(command, data=None, check=True):
    result = subprocess.run([
        'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
        args.jump_host,
        'ssh -o BatchMode=yes ' + shlex.quote(args.router) + ' ' + shlex.quote(command),
    ], input=data, capture_output=True, text=True, timeout=45)
    if check and result.returncode:
        raise RuntimeError('remote operation failed: ' + result.stderr[-3000:])
    return result


def write(path, contents):
    remote('umask 077; cat > ' + shlex.quote(path), contents)


def normalize(value):
    if isinstance(value, dict):
        return {k: normalize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize(v) for v in value]
    if isinstance(value, str):
        return value.replace(args.directory + '/generated', '/var/run/homeproxy-ce')
    return value


source = (remote('cat /etc/homeproxy-ce/scripts/generate_client.uc').stdout
          if args.baseline else
          (repo / 'root/etc/homeproxy-ce/scripts/generate_client.uc').read_text())
assert 'HP_DIR, RUN_DIR' in source
source = source.replace('HP_DIR, RUN_DIR', 'HP_DIR', 1)
source = source.replace('const ubus = connect();',
                        'const RUN_DIR = ' + json.dumps(args.directory + '/generated') + ';\nconst ubus = connect();', 1)
needle = "const features = ubus.call('luci.homeproxyce', 'singbox_get_features', {}) || {};"
assert needle in source
if args.baseline:
    helper = remote('cat /etc/homeproxy-ce/scripts/homeproxy.uc').stdout
else:
    helper = (repo / 'root/etc/homeproxy-ce/scripts/homeproxy.uc').read_text()
write(args.directory + '/homeproxy.uc', helper)
if args.migrate:
    if args.baseline:
        parser.error('--migrate is for the candidate only')
    fixture = args.directory + '/uci'
    remote('umask 077; mkdir -p ' + shlex.quote(fixture) + '; cp /etc/config/homeproxy-ce ' +
           shlex.quote(fixture + '/homeproxy-ce'))
    migration = (repo / 'root/etc/homeproxy-ce/scripts/migrate_config.uc').read_text()
    assert 'const uci = cursor();' in migration
    migration = migration.replace('const uci = cursor();', 'const uci = cursor(' + json.dumps(fixture) + ');', 1)
    # This migration contains a historical crontab cleanup. Keep all writes in
    # the fixture; no system command from the migration may touch the router.
    migration = migration.replace('system(', 'test_system(')
    if migration.startswith('#!'):
        migration = migration.split('\n', 1)[1]
    migration = 'function test_system(command) { return 0; }\n' + migration
    write(args.directory + '/migrate.uc', migration)
    remote('ucode -L ' + shlex.quote(args.directory + '/*.uc') + ' -S ' +
           shlex.quote(args.directory + '/migrate.uc'))
    source = source.replace('const uci = cursor();', 'const uci = cursor(' + json.dumps(fixture) + ');', 1)
    print('package migration applied only to isolated UCI copy')
current = json.loads(remote('cat /var/run/homeproxy-ce/sing-box-c.json').stdout)
outputs = {}
failures = 0
for version, binary in [('1.12.13', '/usr/bin/sing-box'),
                        ('1.15.0-alpha.4', args.directory + '/core/usr/bin/sing-box')]:
    write(args.directory + '/generate.uc', source.replace(
        needle, needle + '\nfeatures.version = ' + json.dumps(version) + ';', 1))
    remote('umask 077; ucode -L ' + shlex.quote(args.directory + '/*.uc') +
           ' -S ' + shlex.quote(args.directory + '/generate.uc'))
    path = args.directory + '/generated/sing-box-c.json'
    config = json.loads(remote('cat ' + shlex.quote(path)).stdout)
    outputs[version] = normalize(config)
    env = 'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true '
    if not args.baseline:
        env += 'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true '
    result = remote(env + shlex.quote(binary) + ' check -c ' + shlex.quote(path), check=False)
    print(version, 'check exit:', result.returncode)
    if result.returncode:
        failures += 1
        errors = re.sub(r'\x1b\[[0-9;]*m', '', result.stderr)
        print('\n'.join(line for line in errors.splitlines() if 'FATAL' in line or 'ERROR' in line))
    print('inbound/outbound/DNS counts:', len(config.get('inbounds', [])),
          len(config.get('outbounds', [])), len(config.get('dns', {}).get('servers', [])))
    print('outbound DNS rules:', sum('outbound' in rule for rule in config['dns'].get('rules', [])))

old = outputs['1.12.13']
# WAN DHCP DNS is read dynamically by the unmodified generator. Compare the
# currently running snapshot after accounting for that single external input.
running_default = next(s for s in current['dns']['servers'] if s['tag'] == 'default-dns')
generated_default = next(s for s in old['dns']['servers'] if s['tag'] == 'default-dns')
wan_changed = running_default.get('address') != generated_default.get('address')
if wan_changed:
    print('WAN DNS changed since service start; normalizing only default-dns.address')
    running_default['address'] = generated_default['address']
unchanged = old == current
print('1.12 generated config equals running config:', unchanged)
if not unchanged:
    print('changed top-level keys:', [key for key in set(old) | set(current) if old.get(key) != current.get(key)])
    failures += 1
if not args.baseline:
    new = outputs['1.15.0-alpha.4']
    old_dns_rules = old['dns'].get('rules', [])
    new_dns_rules = new['dns'].get('rules', [])
    preserved = old_dns_rules == new_dns_rules
    print('all actual DNS rule conditions and ordering preserved:', preserved)
    if not preserved:
        failures += 1
    for name in ['outbounds', 'endpoints']:
        identical = old.get(name) == new.get(name)
        print(name, 'preserved:', identical)
        if not identical:
            failures += 1
    legacy_rules = old['route']['rules']
    new_rules = [rule for rule in new['route']['rules'] if rule.get('action') != 'sniff']
    print('routing decisions preserved:', legacy_rules == new_rules)
    if legacy_rules != new_rules:
        failures += 1
raise SystemExit(bool(failures))
