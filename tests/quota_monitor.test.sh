#!/bin/sh
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/../root/etc/homeproxy-ce/scripts/quota_monitor.sh"
# Keep the isolated state on the host tmpfs.  The monitor deliberately relies
# on atomic rename, which can be obscured by a mounted developer cache volume.
TEST_ROOT=$(mktemp -d "${QUOTA_TEST_TMPDIR:-/tmp}/homeproxy-quota-test.XXXXXX")
export TEST_ROOT
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; esac; }
assert_equal() { [ "$1" = "$2" ] || fail "$3 (got: $1, want: $2)"; }
assert_not_equal() { [ "$1" != "$2" ] || fail "$3 (both: $1)"; }
assert_nonzero() { [ "$1" -ne 0 ] || fail "$2"; }

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/etc/homeproxy-ce" "$TEST_ROOT/run"
cp "$SOURCE" "$TEST_ROOT/quota_monitor.sh"
chmod 0755 "$TEST_ROOT/quota_monitor.sh"
printf '%s\n' \
	'https://example.test/rx1#RX78-1' \
	'https://example.test/rx2#RX78-2' \
	'https://example.test/rx4#RX78-4' > "$TEST_ROOT/subscriptions"

printf '%s\n' rx1 > "$TEST_ROOT/current-inner"
printf '%s\n' rx > "$TEST_ROOT/current-outer"

cat > "$TEST_ROOT/bin/curl" <<'EOF_CURL'
#!/bin/sh
set -eu
output=
headers=
request=GET
data=
proxy=
url=
code=200
body=
while [ "$#" -gt 0 ]; do
	case "$1" in
		--output|-o) output=$2; shift 2 ;;
		--dump-header|-D) headers=$2; shift 2 ;;
		--write-out|-w) shift 2 ;;
		--proxy) proxy=$2; shift 2 ;;
		--noproxy) shift 2 ;;
		--request|-X) request=$2; shift 2 ;;
		--data|--data-raw|--data-binary) data=$2; shift 2 ;;
		--) shift; url=$1; shift ;;
		*) url=$1; shift ;;
	esac
done
if printf '%s' "$url" | grep -Fq '/proxies/%E6%9C%80%E7%BB%88%E5%87%BA%E5%8F%A3'; then
	kind=outer
elif printf '%s' "$url" | grep -Fq '/proxies/%E4%BB%A3%E7%90%86%20%7C%20RX78'; then
	kind=inner
else
	kind=subscription
fi
if [ "$kind" != subscription ] && [ "${QUOTA_TEST_API_FAIL:-0}" = 1 ]; then
	exit 7
fi
if [ "$kind" != subscription ] && [ "$request" = PUT ] && [ "${QUOTA_TEST_API_SELECT_FAIL:-0}" = 1 ]; then
	exit 7
fi
if [ "$kind" = subscription ]; then
	alias=rx1
	printf '%s' "$url" | grep -Fq 'rx2' && alias=rx2
	printf '%s' "$url" | grep -Fq 'rx4' && alias=rx4
	if [ "$proxy" != '' ] && [ "${QUOTA_TEST_PROXY_FAIL:-0}" = 1 ]; then
		exit 28
	fi
	count_file="$TEST_ROOT/count-$alias"
	count=0
	[ -f "$count_file" ] && count=$(cat "$count_file")
	count=$((count + 1))
	printf '%s\n' "$count" > "$count_file"
	printf '%s\n' "$url" >> "$TEST_ROOT/urls-$alias"
	response=$(sed -n "${count}p" "$TEST_ROOT/$alias.responses" 2>/dev/null || true)
	[ -n "$response" ] || response=$(tail -n 1 "$TEST_ROOT/$alias.responses")
	case "$response" in
		timeout)
			exit 28
			;;
		exhausted)
			body='<html><title>Error 1027</title></html>'
			header='HTTP/1.1 403 Forbidden\nserver: cloudflare\ncf-ray: test\nContent-Type: text/html\n'
			;;
		proxy1027)
			if [ "$proxy" != '' ]; then
				body='<html><title>Error 1027</title></html>'
				header='HTTP/1.1 403 Forbidden\nserver: cloudflare\ncf-ray: test\nContent-Type: text/html\n'
			else
				body='dmxlc3M6Ly9ub2Rl'
				header='HTTP/1.1 200 OK\nContent-Type: text/plain\n'
			fi
			;;
		challenge)
			body='<html><title>challenge</title></html>'
			header='HTTP/1.1 200 OK\nserver: cloudflare\ncf-ray: test\nContent-Type: text/html\n'
			;;
		numeric)
			body='<html><title>code 1027</title></html>'
			header='HTTP/1.1 200 OK\nserver: cloudflare\ncf-ray: test\nContent-Type: text/html\n'
			;;
		*)
			body='dmxlc3M6Ly9ub2Rl'
			header='HTTP/1.1 200 OK\nContent-Type: text/plain\n'
			;;
	esac
	if [ "$alias" = rx4 ] && [ "${QUOTA_TEST_MANUAL_SWITCH:-0}" = 1 ]; then
		printf '%s\n' rx2 > "$TEST_ROOT/current-inner"
	fi
	if [ "$alias" = rx4 ] && [ "${QUOTA_TEST_MANUAL_OUTER:-0}" = 1 ]; then
		printf '%s\n' sspai > "$TEST_ROOT/current-outer"
	fi
else
	if [ "$request" = PUT ]; then
		case "$data" in
			*'代理 | SSPAI'*) printf '%s\n' sspai > "$TEST_ROOT/current-outer" ;;
			*'代理 | RX78-1'*) printf '%s\n' rx1 > "$TEST_ROOT/current-inner" ;;
			*'代理 | RX78-2'*) printf '%s\n' rx2 > "$TEST_ROOT/current-inner" ;;
			*'代理 | RX78-4'*) printf '%s\n' rx4 > "$TEST_ROOT/current-inner" ;;
			*'代理 | RX78'*) printf '%s\n' rx > "$TEST_ROOT/current-outer" ;;
		esac
		code=204
	else
		if [ "$kind" = outer ]; then
			case "$(cat "$TEST_ROOT/current-outer")" in
				rx) body='{"now":"代理 | RX78"}' ;;
				sspai) body='{"now":"代理 | SSPAI"}' ;;
				*) body='{"now":"代理 | 美国"}' ;;
			esac
		else
			case "$(cat "$TEST_ROOT/current-inner")" in
				rx1) body='{"now":"代理 | RX78-1"}' ;;
				rx2) body='{"now":"代理 | RX78-2"}' ;;
				*) body='{"now":"代理 | RX78-4"}' ;;
			esac
		fi
		header='HTTP/1.1 200 OK\nContent-Type: application/json\n'
	fi
fi
[ -z "$headers" ] || printf '%b' "$header" > "$headers"
[ -z "$output" ] || printf '%s' "$body" > "$output"
printf '%s' "$code"
EOF_CURL
chmod 0755 "$TEST_ROOT/bin/curl"

run_monitor() {
	QUOTA_HP_ROOT="$TEST_ROOT/etc/homeproxy-ce" \
	QUOTA_RUN_ROOT="$TEST_ROOT/run" \
	QUOTA_STATE_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-state" \
	QUOTA_EVENT_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-events" \
	QUOTA_RUNTIME_FILE="$TEST_ROOT/run/quota-status" \
	QUOTA_REFRESH_LOCK="$TEST_ROOT/run/autopilot-refresh.lock" \
	QUOTA_CURL_BIN="$TEST_ROOT/bin/curl" \
	QUOTA_FLOCK_BIN="$(command -v flock)" \
	QUOTA_TEST_PROXY_FAIL="${QUOTA_TEST_PROXY_FAIL:-0}" \
	QUOTA_TEST_API_FAIL="${QUOTA_TEST_API_FAIL:-0}" \
	QUOTA_TEST_API_SELECT_FAIL="${QUOTA_TEST_API_SELECT_FAIL:-0}" \
	QUOTA_TEST_MANUAL_SWITCH="${QUOTA_TEST_MANUAL_SWITCH:-0}" \
	QUOTA_TEST_MANUAL_OUTER="${QUOTA_TEST_MANUAL_OUTER:-0}" \
	QUOTA_SUBSCRIPTIONS_FILE="$TEST_ROOT/subscriptions" \
	"$TEST_ROOT/quota_monitor.sh" --once
}

status_monitor() {
	QUOTA_HP_ROOT="$TEST_ROOT/etc/homeproxy-ce" \
	QUOTA_RUN_ROOT="$TEST_ROOT/run" \
	QUOTA_STATE_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-state" \
	QUOTA_EVENT_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-events" \
	QUOTA_RUNTIME_FILE="$TEST_ROOT/run/quota-status" \
	"$TEST_ROOT/quota_monitor.sh" --status
}

control_monitor() {
	QUOTA_HP_ROOT="$TEST_ROOT/etc/homeproxy-ce" \
	QUOTA_RUN_ROOT="$TEST_ROOT/run" \
	QUOTA_STATE_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-state" \
	QUOTA_EVENT_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-events" \
	QUOTA_RUNTIME_FILE="$TEST_ROOT/run/quota-status" \
	QUOTA_REFRESH_LOCK="$TEST_ROOT/run/autopilot-refresh.lock" \
	QUOTA_FLOCK_BIN="$(command -v flock)" \
	"$TEST_ROOT/quota_monitor.sh" "$1"
}

write_responses() {
	printf '%s\n' "$2" > "$TEST_ROOT/$1.responses"
}

write_responses rx1 healthy
write_responses rx2 healthy
write_responses rx4 healthy
QUOTA_HP_ROOT="$TEST_ROOT/etc/homeproxy-ce" QUOTA_RUN_ROOT="$TEST_ROOT/run" QUOTA_STATE_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-state" QUOTA_EVENT_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-events" QUOTA_RUNTIME_FILE="$TEST_ROOT/run/quota-status" QUOTA_FLOCK_BIN="$(command -v flock)" "$TEST_ROOT/quota_monitor.sh" --enable >/dev/null
run_monitor
output=$(status_monitor)
assert_contains "$output" '"status":"monitoring"' 'healthy subscription should be monitored'
assert_contains "$output" '"active_account":"RX78-1"' 'current account should be reported'

# A normal proxy/TLS failure is retried directly but never marks quota used.
printf '%s\n' timeout > "$TEST_ROOT/rx1.responses"
set +e
QUOTA_TEST_PROXY_FAIL=1 run_monitor
QUOTA_TEST_PROXY_FAIL=0
set -e
status=$(status_monitor)
assert_not_contains "$status" '"state":"exhausted"' 'transport failure must not exhaust an account'
assert_contains "$status" '"status":"unavailable"' 'transport failure should be visible as unavailable'

# A proxy-side failure may recover through the direct IPv4 fallback.
printf '%s\n' healthy > "$TEST_ROOT/rx1.responses"
QUOTA_TEST_PROXY_FAIL=1 run_monitor
QUOTA_TEST_PROXY_FAIL=0
status=$(status_monitor)
assert_contains "$status" '"status":"monitoring"' 'direct fallback should preserve a healthy account'

# A proxy-side Cloudflare 1027 page must be confirmed directly before it can
# exhaust an account.
printf '%s\n' proxy1027 > "$TEST_ROOT/rx1.responses"
rm -f "$TEST_ROOT/count-rx1"
run_monitor
status=$(status_monitor)
assert_contains "$status" '"status":"monitoring"' 'direct healthy confirmation should reject proxy 1027'
assert_not_contains "$status" '"alias":"RX78-1","state":"exhausted"' 'proxy-only 1027 must not exhaust an account'

# Two explicit 1027 Cloudflare pages switch to RX78-2.
printf '%s\n' exhausted exhausted > "$TEST_ROOT/rx1.responses"
printf '%s\n' healthy > "$TEST_ROOT/rx2.responses"
rm -f "$TEST_ROOT/count-rx1" "$TEST_ROOT/urls-rx1"
run_monitor
output=$(status_monitor)
assert_contains "$output" '"status":"switched"' 'confirmed 1027 should switch account'
assert_contains "$output" '"active_account":"RX78-2"' 'switch should target RX78-2'
assert_contains "$output" 'quota_exhausted' 'quota event should be retained'
first_probe=$(sed -n '1p' "$TEST_ROOT/urls-rx1")
second_probe=$(sed -n '2p' "$TEST_ROOT/urls-rx1")
assert_not_equal "$first_probe" "$second_probe" 'quota confirmations must use distinct cache-busting URLs'

# A challenge HTML page without 1027 must remain unknown and cannot switch.
printf '%s\n' challenge challenge > "$TEST_ROOT/rx2.responses"
run_monitor
output=$(status_monitor)
assert_contains "$output" '"status":"unavailable"' 'challenge HTML should be unknown'
assert_contains "$output" '"active_account":"RX78-2"' 'unknown response must preserve account'

# A generic HTML page containing only "code 1027" is not a quota marker.
printf '%s\n' numeric > "$TEST_ROOT/rx2.responses"
run_monitor
output=$(status_monitor)
assert_contains "$output" '"status":"unavailable"' 'generic 1027 HTML should be unknown'
assert_not_contains "$output" '"alias":"RX78-2","state":"exhausted"' 'generic 1027 HTML must not exhaust an account'

# An unknown next candidate must not prevent a later healthy candidate from being used.
printf '%s\n' rx > "$TEST_ROOT/current-outer"
printf '%s\n' rx1 > "$TEST_ROOT/current-inner"
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=1/; s/^active_account=.*/active_account=RX78-1/; s/^exhausted=.*/exhausted=/; s/^cycle=.*/cycle=/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n%s\n' exhausted exhausted > "$TEST_ROOT/rx1.responses"
printf '%s\n' challenge > "$TEST_ROOT/rx2.responses"
printf '%s\n' healthy > "$TEST_ROOT/rx4.responses"
rm -f "$TEST_ROOT/count-rx1" "$TEST_ROOT/count-rx2" "$TEST_ROOT/count-rx4"
run_monitor
output=$(status_monitor)
assert_contains "$output" '"active_account":"RX78-4"' 'later healthy account should be selected'
assert_contains "$output" '"alias":"RX78-2","state":"unknown"' 'unknown candidate should remain unknown'
assert_contains "$output" '"event":"account_switch","account":"RX78-4"' 'later healthy account should be the switch target'
assert_equal "$(cat "$TEST_ROOT/current-inner")" rx4 'later healthy account should be selected in the selector'
case "$output" in
	*'"status":"switched"'*|*'"status":"monitoring"'*) ;;
	*) fail 'successful rotation should report switched or monitoring' ;;
esac

# A manual inner-selector change during probing must be preserved.
printf '%s\n' rx > "$TEST_ROOT/current-outer"
printf '%s\n' rx1 > "$TEST_ROOT/current-inner"
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=1/; s/^active_account=.*/active_account=RX78-1/; s/^exhausted=.*/exhausted=/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n%s\n' exhausted exhausted > "$TEST_ROOT/rx1.responses"
printf '%s\n' exhausted > "$TEST_ROOT/rx2.responses"
printf '%s\n' healthy > "$TEST_ROOT/rx4.responses"
rm -f "$TEST_ROOT/count-rx1" "$TEST_ROOT/count-rx2" "$TEST_ROOT/count-rx4"
QUOTA_TEST_MANUAL_SWITCH=1 run_monitor
QUOTA_TEST_MANUAL_SWITCH=0
output=$(status_monitor)
assert_contains "$output" '"status":"manual"' 'manual inner change should be reported'
assert_equal "$(cat "$TEST_ROOT/current-inner")" rx2 'manual inner change must be preserved'

# The same guard protects a manual outer-selector change.
printf '%s\n' rx > "$TEST_ROOT/current-outer"
printf '%s\n' rx1 > "$TEST_ROOT/current-inner"
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=1/; s/^active_account=.*/active_account=RX78-1/; s/^exhausted=.*/exhausted=/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
rm -f "$TEST_ROOT/count-rx1" "$TEST_ROOT/count-rx2" "$TEST_ROOT/count-rx4"
QUOTA_TEST_MANUAL_SWITCH=0 QUOTA_TEST_MANUAL_OUTER=1 run_monitor
QUOTA_TEST_MANUAL_SWITCH=0
QUOTA_TEST_MANUAL_OUTER=0
output=$(status_monitor)
assert_contains "$output" '"status":"manual"' 'manual outer change should be reported'
assert_equal "$(cat "$TEST_ROOT/current-outer")" sspai 'manual outer change must be preserved'
assert_equal "$(cat "$TEST_ROOT/current-inner")" rx1 'manual outer change must preserve inner selector'

# If all three accounts confirm 1027, the outer selector falls back to SSPAI.
printf '%s\n' rx > "$TEST_ROOT/current-outer"
printf '%s\n' rx4 > "$TEST_ROOT/current-inner"
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=1/; s/^active_account=.*/active_account=RX78-4/; s/^exhausted=.*/exhausted=RX78-1,RX78-2/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n%s\n' exhausted exhausted > "$TEST_ROOT/rx4.responses"
rm -f "$TEST_ROOT/count-rx4"
run_monitor
output=$(status_monitor)
assert_contains "$output" '"status":"fallback"' 'all accounts exhausted should fall back'
assert_contains "$output" '"active_account":"SSPAI"' 'fallback account should be SSPAI'
assert_contains "$output" '"event":"fallback"' 'fallback event should be retained'

# A failed fallback PUT is retried from durable exhaustion without probing a
# known exhausted endpoint again.
printf '%s\n' rx > "$TEST_ROOT/current-outer"
printf '%s\n' rx4 > "$TEST_ROOT/current-inner"
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=1/; s/^active_account=.*/active_account=RX78-4/; s/^exhausted=.*/exhausted=RX78-1,RX78-2,RX78-4/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n' timeout > "$TEST_ROOT/rx4.responses"
rm -f "$TEST_ROOT/count-rx4" "$TEST_ROOT/urls-rx4"
QUOTA_TEST_API_SELECT_FAIL=1 run_monitor
QUOTA_TEST_API_SELECT_FAIL=0
output=$(status_monitor)
assert_contains "$output" '"status":"unavailable"' 'failed fallback PUT should be unavailable'
assert_equal "$(cat "$TEST_ROOT/current-outer")" rx 'failed fallback PUT must preserve RX78 outer'
probe_count=0
[ -f "$TEST_ROOT/urls-rx4" ] && probe_count=$(wc -l < "$TEST_ROOT/urls-rx4")
assert_equal "$probe_count" 0 'known exhausted account should not be reprobed after fallback failure'
run_monitor
output=$(status_monitor)
assert_contains "$output" '"status":"fallback"' 'fallback should retry after an API error'
assert_equal "$(cat "$TEST_ROOT/current-outer")" sspai 'retry should select SSPAI'

# A UTC day change probes RX78-1 before restoring the inner and outer selectors.
printf '%s\n' rx1 > "$TEST_ROOT/current-inner"
sed 's/^mode=.*/mode=fallback/; s/^owned=.*/owned=1/; s/^active_account=.*/active_account=SSPAI/; s/^cycle=.*/cycle=2000-01-01/; s/^exhausted=.*/exhausted=RX78-1,RX78-2,RX78-4/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n' healthy > "$TEST_ROOT/rx1.responses"
rm -f "$TEST_ROOT/count-rx1"
before_cycle=$(sed -n 's/^cycle=//p' "$TEST_ROOT/etc/homeproxy-ce/quota-state")
QUOTA_TEST_API_FAIL=1 run_monitor
QUOTA_TEST_API_FAIL=0
assert_equal "$(sed -n 's/^cycle=//p' "$TEST_ROOT/etc/homeproxy-ce/quota-state")" "$before_cycle" 'failed daily reset must retain the old cycle for retry'
run_monitor
output=$(status_monitor)
assert_contains "$output" '"status":"monitoring"' 'daily reset should restore monitoring'
assert_contains "$output" '"active_account":"RX78-1"' 'daily reset should restore RX78-1'
assert_equal "$(cat "$TEST_ROOT/current-outer")" rx 'daily reset should restore the outer RX78 selector'
assert_equal "$(cat "$TEST_ROOT/current-inner")" rx1 'daily reset should restore the inner RX78-1 selector'
assert_contains "$output" '"event":"cycle_restore"' 'daily reset should retain a restore event'

# A manually selected SSPAI outer selector is never taken over.
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=0/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n' sspai > "$TEST_ROOT/current-outer"
before=$(cat "$TEST_ROOT/current-inner")
output=$(run_monitor; status_monitor)
assert_contains "$output" '"status":"manual"' 'manual SSPAI selection should be reported'
assert_equal "$(cat "$TEST_ROOT/current-inner")" "$before" 'manual SSPAI must not change RX78 selector'

# A manually selected non-RX78 outer selector is also left alone.
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=1/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n' other > "$TEST_ROOT/current-outer"
before=$(cat "$TEST_ROOT/current-inner")
output=$(run_monitor; status_monitor)
assert_contains "$output" '"status":"manual"' 'manual non-RX78 selection should be reported'
assert_contains "$output" '"active_account":"manual"' 'manual non-RX78 selection should be identified'
assert_equal "$(cat "$TEST_ROOT/current-inner")" "$before" 'manual non-RX78 must not change RX78 selector'

# An API failure must not persist ownership or selection changes.
printf '%s\n' rx > "$TEST_ROOT/current-outer"
printf '%s\n' rx1 > "$TEST_ROOT/current-inner"
sed 's/^mode=.*/mode=monitoring/; s/^owned=.*/owned=1/; s/^active_account=.*/active_account=RX78-1/; s/^exhausted=.*/exhausted=/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
printf '%s\n' healthy > "$TEST_ROOT/rx1.responses"
rm -f "$TEST_ROOT/count-rx1"
before=$(cat "$TEST_ROOT/etc/homeproxy-ce/quota-state")
QUOTA_TEST_API_FAIL=1 run_monitor
QUOTA_TEST_API_FAIL=0
after=$(cat "$TEST_ROOT/etc/homeproxy-ce/quota-state")
assert_equal "$after" "$before" 'API failure must not change durable state'
assert_equal "$(cat "$TEST_ROOT/current-outer")" rx 'API failure must not change outer selection'
assert_equal "$(cat "$TEST_ROOT/current-inner")" rx1 'API failure must not change inner selection'

# Refresh contention returns busy and leaves durable state untouched.
exec 8>"$TEST_ROOT/run/autopilot-refresh.lock"
flock -n 8
before=$(cat "$TEST_ROOT/etc/homeproxy-ce/quota-state")
set +e
output=$(control_monitor --enable)
rc=$?
set -e
assert_nonzero "$rc" 'quota-enable should fail while refresh lock is held'
assert_equal "$output" '{"status":"busy"}' 'quota-enable lock contention response'
output=$(run_monitor; status_monitor)
after=$(cat "$TEST_ROOT/etc/homeproxy-ce/quota-state")
flock -u 8
exec 8>&-
assert_equal "$after" "$before" 'refresh lock contention must not change durable state'
assert_contains "$output" '"status":"unavailable"' 'refresh lock contention should be visible as unavailable'

# The state survives a new process and quota-disable/enabling is fixed.
output=$(status_monitor)
assert_contains "$output" '"enabled":true' 'state should persist across process'
output=$(QUOTA_HP_ROOT="$TEST_ROOT/etc/homeproxy-ce" QUOTA_RUN_ROOT="$TEST_ROOT/run" QUOTA_STATE_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-state" QUOTA_EVENT_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-events" QUOTA_RUNTIME_FILE="$TEST_ROOT/run/quota-status" QUOTA_FLOCK_BIN="$(command -v flock)" "$TEST_ROOT/quota_monitor.sh" --disable)
assert_contains "$output" '"enabled":false' 'quota-disable should be reported'
sed 's/^enabled=.*/enabled=corrupt/' "$TEST_ROOT/etc/homeproxy-ce/quota-state" > "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp"
mv "$TEST_ROOT/etc/homeproxy-ce/quota-state.tmp" "$TEST_ROOT/etc/homeproxy-ce/quota-state"
output=$(status_monitor)
assert_contains "$output" '"enabled":false' 'corrupt state must fail closed disabled'
output=$(QUOTA_HP_ROOT="$TEST_ROOT/etc/homeproxy-ce" QUOTA_RUN_ROOT="$TEST_ROOT/run" QUOTA_STATE_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-state" QUOTA_EVENT_FILE="$TEST_ROOT/etc/homeproxy-ce/quota-events" QUOTA_RUNTIME_FILE="$TEST_ROOT/run/quota-status" QUOTA_FLOCK_BIN="$(command -v flock)" "$TEST_ROOT/quota_monitor.sh" --enable)
assert_contains "$output" '"enabled":true' 'quota-enable should be reported'

printf 'PASS: quota monitor shell behavior\n'
