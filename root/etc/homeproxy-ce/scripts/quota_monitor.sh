#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Monitor RX78 subscription endpoints and change selector choices through the
# loopback Clash API. It never rebuilds or restarts sing-box.

set -u
umask 077

HP_ROOT=${QUOTA_HP_ROOT:-/etc/homeproxy-ce}
RUN_ROOT=${QUOTA_RUN_ROOT:-/var/run/homeproxy-ce}
STATE_FILE=${QUOTA_STATE_FILE:-$HP_ROOT/quota-state}
EVENT_FILE=${QUOTA_EVENT_FILE:-$HP_ROOT/quota-events}
RUNTIME_FILE=${QUOTA_RUNTIME_FILE:-$RUN_ROOT/quota-status}
LOCK_FILE=${QUOTA_REFRESH_LOCK:-$RUN_ROOT/autopilot-refresh.lock}
UCI_BIN=${QUOTA_UCI_BIN:-/sbin/uci}
CURL_BIN=${QUOTA_CURL_BIN:-/usr/bin/curl}
FLOCK_BIN=${QUOTA_FLOCK_BIN:-/usr/bin/flock}

API_BASE='http://127.0.0.1:9090'
PROXY_PORT=${QUOTA_PROXY_PORT:-5330}
USER_AGENT='HomeProxy-Quota-Monitor/1.0'

OUTER_PATH='%E6%9C%80%E7%BB%88%E5%87%BA%E5%8F%A3'
RX_PATH='%E4%BB%A3%E7%90%86%20%7C%20RX78'
RX_SELECTOR_NAME='代理 | RX78'
SSPAI_NAME='代理 | SSPAI'
ALIAS_RX78_1='代理 | RX78-1'
ALIAS_RX78_2='代理 | RX78-2'
ALIAS_RX78_4='代理 | RX78-4'
ALIASES='RX78-1 RX78-2 RX78-4'

enabled=0
owned=0
mode=idle
active_account=unknown
cycle=''
exhausted=''
last_event=''
runtime_status=''
runtime_account=''
RESET_PENDING=0
PROBE_SERIAL=0

state_load() {
	local key value
	[ -f "$STATE_FILE" ] || return 0
	while IFS='=' read -r key value; do
		case "$key" in
			enabled) enabled=$value ;;
			owned) owned=$value ;;
			mode) mode=$value ;;
			active_account) active_account=$value ;;
			cycle) cycle=$value ;;
			exhausted) exhausted=$value ;;
			last_event) last_event=$value ;;
		esac
	done < "$STATE_FILE"
	case "$enabled" in 0|1) ;; *) enabled=0 ;; esac
	case "$owned" in 0|1) ;; *) owned=0 ;; esac
	case "$active_account" in RX78-1|RX78-2|RX78-4|SSPAI|manual|unknown) ;; *) active_account=unknown ;; esac
	case "$mode" in idle|monitoring|switched|fallback|manual|disabled|unavailable) ;; *) mode=idle ;; esac
}

state_snapshot() {
	printf '%s\n' \
		"enabled=$enabled" \
		"owned=$owned" \
		"mode=$mode" \
		"active_account=$active_account" \
		"cycle=$cycle" \
		"exhausted=$exhausted" \
		"last_event=$last_event"
}

state_save() {
	local new old tmp
	[ -d "$HP_ROOT" ] || mkdir -p "$HP_ROOT"
	[ -d "$RUN_ROOT" ] || mkdir -p "$RUN_ROOT"
	new=$(state_snapshot)
	old=$(cat "$STATE_FILE" 2>/dev/null || true)
	[ "$new" = "$old" ] && return 0
	tmp="$HP_ROOT/.quota-state.$$"
	printf '%s\n' "$new" > "$tmp" || return 1
	chmod 0600 "$tmp"
	mv -f "$tmp" "$STATE_FILE"
}

runtime_save() {
	local tmp
	[ -d "$RUN_ROOT" ] || mkdir -p "$RUN_ROOT"
	tmp="$RUN_ROOT/.quota-status.$$"
	printf 'status=%s\naccount=%s\n' "$runtime_status" "$runtime_account" > "$tmp" || return 1
	chmod 0600 "$tmp"
	mv -f "$tmp" "$RUNTIME_FILE"
}

set_runtime() {
	runtime_status=$1
	runtime_account=${2:-$active_account}
	runtime_save || true
}

append_event() {
	local event=$1 account=${2:-$active_account} stamp tmp
	stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	last_event="$stamp|$event|$account"
	[ -d "$HP_ROOT" ] || mkdir -p "$HP_ROOT"
	[ -d "$RUN_ROOT" ] || mkdir -p "$RUN_ROOT"
	tmp="$HP_ROOT/.quota-events.$$"
	{
		[ -f "$EVENT_FILE" ] && tail -n 19 "$EVENT_FILE"
		printf '%s\n' "$last_event"
	} > "$tmp" || return 1
	chmod 0600 "$tmp"
	mv -f "$tmp" "$EVENT_FILE"
}

set_exhausted() {
	case ",$exhausted," in
		*,"$1",*) return 0 ;;
	esac
	if [ -n "$exhausted" ]; then
		exhausted="$exhausted,$1"
	else
		exhausted=$1
	fi
}

is_exhausted() {
	case ",$exhausted," in *,"$1",*) return 0 ;; esac
	return 1
}

all_exhausted() {
	is_exhausted RX78-1 && is_exhausted RX78-2 && is_exhausted RX78-4
}

alias_name() {
	case "$1" in
		RX78-1) printf '%s\n' "$ALIAS_RX78_1" ;;
		RX78-2) printf '%s\n' "$ALIAS_RX78_2" ;;
		RX78-4) printf '%s\n' "$ALIAS_RX78_4" ;;
		*) return 1 ;;
	esac
}

alias_from_name() {
	case "$1" in
		"$ALIAS_RX78_1") printf 'RX78-1\n' ;;
		"$ALIAS_RX78_2") printf 'RX78-2\n' ;;
		"$ALIAS_RX78_4") printf 'RX78-4\n' ;;
		*) return 1 ;;
	esac
}

next_alias() {
	case "$1" in
		RX78-1) printf 'RX78-2 RX78-4\n' ;;
		RX78-2) printf 'RX78-4 RX78-1\n' ;;
		RX78-4) printf 'RX78-1 RX78-2\n' ;;
		*) printf '%s\n' "$ALIASES" ;;
	esac
}

subscription_lines() {
	if [ -n "${QUOTA_SUBSCRIPTIONS_FILE:-}" ] && [ -f "$QUOTA_SUBSCRIPTIONS_FILE" ]; then
		cat "$QUOTA_SUBSCRIPTIONS_FILE"
		return 0
	fi
	"$UCI_BIN" -q show homeproxy-ce.subscription 2>/dev/null |
		sed "s/^.*subscription_url=//; s/' '/\\n/g; s/^'//; s/'$//"
}

subscription_url() {
	local wanted=$1 url fragment base
	while IFS= read -r url; do
		[ -n "$url" ] || continue
		fragment=${url#*#}
		[ "$fragment" = "$wanted" ] || continue
		base=${url%%#*}
		printf '%s\n' "$base"
		return 0
	done <<EOF
$(subscription_lines)
EOF
	return 1
}

probe_url() {
	local url=$1 nonce nonce_path
	PROBE_SERIAL=$((PROBE_SERIAL + 1))
	nonce=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
	if [ -z "$nonce" ]; then
		nonce=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
	fi
	if [ -z "$nonce" ]; then
		nonce_path=$(mktemp "$RUN_ROOT/.quota-nonce.XXXXXX" 2>/dev/null || true)
		nonce=${nonce_path##*/}
		[ -z "$nonce_path" ] || rm -f "$nonce_path"
	fi
	[ -n "$nonce" ] || nonce="$(date -u '+%s')-$$-$PROBE_SERIAL"
	case "$url" in
		*\?*) printf '%s&__hp_quota_probe=%s-%s\n' "$url" "$nonce" "$PROBE_SERIAL" ;;
		*) printf '%s?__hp_quota_probe=%s-%s\n' "$url" "$nonce" "$PROBE_SERIAL" ;;
	esac
}

curl_common() {
	"$CURL_BIN" --silent --show-error --location --compressed \
		--connect-timeout 4 --max-time 10 \
		--user-agent "$USER_AGENT" \
		--header 'Cache-Control: no-cache' \
		--header 'Pragma: no-cache' \
		--header 'If-None-Match:' "$@"
}

fetch_subscription() {
	local url=$1 body=$2 headers=$3 code curl_rc
	url=$(probe_url "$url")
	: > "$body"
	: > "$headers"
	code=$(curl_common --proxy "http://127.0.0.1:$PROXY_PORT" \
		--dump-header "$headers" --output "$body" --write-out '%{http_code}' \
		-- "$url" 2>/dev/null)
	curl_rc=$?
	if [ "$curl_rc" -ne 0 ]; then
		: > "$body"
		: > "$headers"
		code=$(curl_common --ipv4 --noproxy '*' \
			--dump-header "$headers" --output "$body" --write-out '%{http_code}' \
			-- "$url" 2>/dev/null)
		curl_rc=$?
	elif is_cloudflare_1027 "$body" "$headers"; then
		# A proxy can return its own Cloudflare error page.  Confirm the
		# subscription directly before counting the account as exhausted.
		url=$(probe_url "$url")
		: > "$body"
		: > "$headers"
		code=$(curl_common --ipv4 --noproxy '*' \
			--dump-header "$headers" --output "$body" --write-out '%{http_code}' \
			-- "$url" 2>/dev/null)
		curl_rc=$?
	fi
	case "$code" in
		*[!0-9]*|'') return 1 ;;
	esac
	[ "$curl_rc" -eq 0 ] || return 1
	printf '%s\n' "$code"
}

is_cloudflare_1027() {
	local body=$1 headers=$2
	grep -Eiq '<!doctype[[:space:]]+html|<html([[:space:]>])|<title([[:space:]>])|<body([[:space:]>])' "$body" 2>/dev/null || return 1
	grep -Eiq 'error[[:space:]_-]*(code[[:space:]_-]*)?[[:space:]:#=]*1027' "$body" 2>/dev/null || return 1
	grep -Eiq '(^|[[:space:]])(server:[[:space:]]*cloudflare|cf-ray:|cf-cache-status:)' "$headers" 2>/dev/null || return 1
	return 0
}

probe_account() {
	local alias=$1 url body headers code
	PROBE_RESULT=unknown
	url=$(subscription_url "$alias" 2>/dev/null || true)
	[ -n "$url" ] || return 0
	body="$RUN_ROOT/.quota-body.$$"
	headers="$RUN_ROOT/.quota-headers.$$"
	code=$(fetch_subscription "$url" "$body" "$headers" 2>/dev/null || true)
	if [ -n "$code" ] && is_cloudflare_1027 "$body" "$headers"; then
		PROBE_RESULT=exhausted
	elif [ -n "$code" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ] 2>/dev/null; then
		if grep -Eiq '<!doctype[[:space:]]+html|<html([[:space:]>])|<title([[:space:]>])|<body([[:space:]>])' "$body" 2>/dev/null; then
			PROBE_RESULT=unknown
		else
			PROBE_RESULT=healthy
		fi
	fi
	rm -f "$body" "$headers"
}

api_get() {
	local path=$1 output=$2 code
	code=$(curl_common --noproxy '*' --connect-timeout 2 --max-time 4 \
		--output "$output" --write-out '%{http_code}' \
		"$API_BASE/proxies/$path" 2>/dev/null)
	[ "$code" = 200 ] && [ -s "$output" ]
}

api_current() {
	local path=$1 output=$2 value
	: > "$output"
	api_get "$path" "$output" || return 1
	value=$(sed -n 's/.*"now"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$output" | head -n 1)
	[ -n "$value" ] || return 1
	printf '%s\n' "$value"
}

api_select() {
	local path=$1 name=$2 output code
	output="$RUN_ROOT/.quota-api.$$"
	code=$(curl_common --noproxy '*' --connect-timeout 2 --max-time 4 \
		-X PUT -H 'Content-Type: application/json' \
		--data "{\"name\":\"$name\"}" \
		--output "$output" --write-out '%{http_code}' \
		"$API_BASE/proxies/$path" 2>/dev/null)
	rm -f "$output"
	[ "$code" = 204 ] || [ "$code" = 200 ]
}

cycle_key() {
	local day
	day=$(date -u '+%F')
	printf '%s\n' "$day"
}

maybe_reset_cycle() {
	local wanted
	wanted=$(cycle_key)
	[ -n "$cycle" ] || { cycle=$wanted; return 0; }
	[ "$cycle" = "$wanted" ] && return 0
	cycle=$wanted
	exhausted=''
	RESET_PENDING=0
	[ "$owned" = 1 ] && [ "$mode" = fallback ] && RESET_PENDING=1
}

state_from_runtime() {
	local key value
	if [ -f "$RUNTIME_FILE" ]; then
		while IFS='=' read -r key value; do
			case "$key" in
				status) runtime_status=$value ;;
				account) runtime_account=$value ;;
			esac
		done < "$RUNTIME_FILE"
	fi
}

json_events() {
	local stamp event account first=1
	printf '['
	if [ -f "$EVENT_FILE" ]; then
		while IFS='|' read -r stamp event account; do
			[ -n "$stamp" ] || continue
			[ "$first" -eq 1 ] || printf ','
			printf '{"at":"%s","event":"%s","account":"%s"}' "$stamp" "$event" "$account"
			first=0
		done < "$EVENT_FILE"
	fi
	printf ']'
}

json_account() {
	local alias=$1 state=unknown
	if is_exhausted "$alias"; then
		state=exhausted
	elif [ "$active_account" = "$alias" ] && [ "${runtime_status:-$mode}" != unavailable ]; then
		state=healthy
	fi
	printf '{"alias":"%s","state":"%s"}' "$alias" "$state"
}

print_status() {
	state_load
	state_from_runtime
	local status=${runtime_status:-$mode} account=${runtime_account:-$active_account} enabled_json
	case "$enabled" in
		1) enabled_json=true ;;
		*) enabled_json=false ;;
	esac
	printf '{"status":"%s","enabled":%s,"active_account":"%s","accounts":[' "$status" "$enabled_json" "$account"
	json_account RX78-1
	printf ','
	json_account RX78-2
	printf ','
	json_account RX78-4
	printf '],"events":'
	json_events
	printf '}\n'
}

acquire_refresh_lock() {
	[ -x "$FLOCK_BIN" ] || return 1
	[ -d "$RUN_ROOT" ] || mkdir -p "$RUN_ROOT"
	exec 9>"$LOCK_FILE" || return 1
	"$FLOCK_BIN" -n 9 >/dev/null 2>&1
}

control_state() {
	if ! acquire_refresh_lock; then
		printf '{"status":"busy"}\n'
		return 1
	fi
	state_load
	case "$1" in
		enable)
			enabled=1
			[ "$mode" = disabled ] && mode=idle
			set_runtime idle "$active_account"
			state_save || return 1
			;;
		disable)
			enabled=0
			mode=disabled
			owned=0
			set_runtime disabled "$active_account"
			state_save || return 1
			;;
		*) return 2 ;;
	esac
	print_status
}

run_once() (
	local outer inner alias result next name
	local outer_file="$RUN_ROOT/.quota-outer.$$"
	local inner_file="$RUN_ROOT/.quota-inner.$$"
	[ -x "$FLOCK_BIN" ] || { set_runtime unavailable unknown; return 0; }
	[ -x "$CURL_BIN" ] || { set_runtime unavailable unknown; return 0; }
	[ -d "$RUN_ROOT" ] || mkdir -p "$RUN_ROOT"
	if ! acquire_refresh_lock; then
		set_runtime unavailable unknown
		return 0
	fi
	state_load
	maybe_reset_cycle
	if [ "$enabled" != 1 ]; then
		mode=disabled
		set_runtime disabled "$active_account"
		state_save || true
		return 0
	fi

	outer=$(api_current "$OUTER_PATH" "$outer_file" 2>/dev/null || true)
	if [ -z "$outer" ]; then
		set_runtime unavailable unknown
		rm -f "$outer_file" "$inner_file"
		return 0
	fi
	if [ "$outer" = "$SSPAI_NAME" ] && [ "$mode" != fallback ]; then
		owned=0
		mode=manual
		active_account=SSPAI
		set_runtime manual SSPAI
		state_save || true
		rm -f "$outer_file" "$inner_file"
		return 0
	fi
	if [ "$outer" != "$RX_SELECTOR_NAME" ] && [ "$mode" != fallback ]; then
		owned=0
		mode=manual
		active_account=manual
		set_runtime manual manual
		state_save || true
		rm -f "$outer_file" "$inner_file"
		return 0
	fi
	if [ "$mode" = fallback ] && [ "$outer" != "$SSPAI_NAME" ]; then
		owned=0
		mode=manual
		active_account=manual
		set_runtime manual manual
		state_save || true
		rm -f "$outer_file" "$inner_file"
		return 0
	fi
	if [ "$mode" = fallback ] && [ "$outer" = "$SSPAI_NAME" ] && [ "$RESET_PENDING" -eq 0 ]; then
		set_runtime fallback SSPAI
		state_save || true
		rm -f "$outer_file" "$inner_file"
		return 0
	fi
	if [ "$RESET_PENDING" -eq 1 ]; then
		# A user may have changed the outer selector while the monitor was
		# waiting for the daily reset.  Do not take that choice back.
		if [ "$outer" != "$SSPAI_NAME" ]; then
			owned=0
			mode=manual
			active_account=manual
			set_runtime manual manual
			state_save || true
			rm -f "$outer_file" "$inner_file"
			return 0
		fi
		probe_account RX78-1
		if [ "$PROBE_RESULT" != healthy ]; then
			set_runtime unavailable SSPAI
			rm -f "$outer_file" "$inner_file"
			return 0
		fi
		if api_select "$RX_PATH" "$ALIAS_RX78_1" && \
			inner=$(api_current "$RX_PATH" "$inner_file" 2>/dev/null || true) && \
			[ "$inner" = "$ALIAS_RX78_1" ]; then
			outer=$(api_current "$OUTER_PATH" "$outer_file" 2>/dev/null || true)
			if [ "$outer" = "$SSPAI_NAME" ] && \
				api_select "$OUTER_PATH" "$RX_SELECTOR_NAME" && \
				outer=$(api_current "$OUTER_PATH" "$outer_file" 2>/dev/null || true) && \
				[ "$outer" = "$RX_SELECTOR_NAME" ]; then
				owned=1
				mode=monitoring
				active_account=RX78-1
				append_event day_reset RX78-1 || true
				append_event cycle_restore RX78-1 || true
				set_runtime monitoring RX78-1
				state_save || true
			else
				set_runtime unavailable SSPAI
			fi
		else
			set_runtime unavailable SSPAI
		fi
		rm -f "$outer_file" "$inner_file"
		return 0
	fi

	inner=$(api_current "$RX_PATH" "$inner_file" 2>/dev/null || true)
	alias=$(alias_from_name "$inner" 2>/dev/null || true)
	if [ -z "$alias" ]; then
		set_runtime unavailable unknown
		rm -f "$outer_file" "$inner_file"
		return 0
	fi
	owned=1
	active_account=$alias
	mode=monitoring
	if is_exhausted "$alias"; then
		# A confirmed exhaustion is durable for the UTC quota cycle.  Continue
		# with the next candidate, even if the endpoint is temporarily down.
		result=exhausted
	else
		probe_account "$alias"
		result=$PROBE_RESULT
	fi
	if [ "$result" = healthy ]; then
		set_runtime monitoring "$alias"
		state_save || true
		rm -f "$outer_file" "$inner_file"
		return 0
	fi
	if [ "$result" != exhausted ]; then
		set_runtime unavailable "$alias"
		state_save || true
		rm -f "$outer_file" "$inner_file"
		return 0
	fi

	if ! is_exhausted "$alias"; then
		probe_account "$alias"
		[ "$PROBE_RESULT" = exhausted ] || {
			set_runtime unavailable "$alias"
			rm -f "$outer_file" "$inner_file"
			return 0
		}
	fi
	if ! is_exhausted "$alias"; then
		set_exhausted "$alias"
		append_event quota_exhausted "$alias" || true
	fi

	for next in $(next_alias "$alias"); do
		is_exhausted "$next" && continue
		[ -n "$(subscription_url "$next" 2>/dev/null || true)" ] || {
			set_runtime unavailable "$alias"
			continue
		}
		probe_account "$next"
		result=$PROBE_RESULT
		if [ "$result" = healthy ]; then
			name=$(alias_name "$next")
			# Re-read both selectors after the network probe.  A user may have
			# changed either selector while the probe was running; preserve that
			# choice instead of overwriting it with a delayed rotation.
			outer=$(api_current "$OUTER_PATH" "$outer_file" 2>/dev/null || true)
			if [ -z "$outer" ]; then
				set_runtime unavailable "$alias"
				break
			fi
			if [ "$outer" != "$RX_SELECTOR_NAME" ]; then
				owned=0
				mode=manual
				[ "$outer" = "$SSPAI_NAME" ] && active_account=SSPAI || active_account=manual
				set_runtime manual "$active_account"
				state_save || true
				break
			fi
			inner=$(api_current "$RX_PATH" "$inner_file" 2>/dev/null || true)
			if [ -z "$inner" ]; then
				set_runtime unavailable "$alias"
				break
			fi
			if [ "$inner" != "$(alias_name "$alias")" ]; then
				owned=0
				mode=manual
				active_account=manual
				set_runtime manual manual
				state_save || true
				break
			fi
			if api_select "$RX_PATH" "$name"; then
				inner=$(api_current "$RX_PATH" "$inner_file" 2>/dev/null || true)
				if [ "$inner" = "$name" ]; then
					active_account=$next
					mode=switched
					append_event account_switch "$next" || true
					set_runtime switched "$next"
				else
					set_runtime unavailable "$alias"
				fi
			else
				set_runtime unavailable "$alias"
			fi
			break
		fi
		if [ "$result" != exhausted ]; then
			set_runtime unavailable "$alias"
			continue
		fi
		probe_account "$next"
		if [ "$PROBE_RESULT" != exhausted ]; then
			set_runtime unavailable "$alias"
			continue
		fi
		set_exhausted "$next"
		append_event quota_exhausted "$next" || true
	done

	if all_exhausted; then
		outer=$(api_current "$OUTER_PATH" "$outer_file" 2>/dev/null || true)
		if [ "$outer" = "$RX_SELECTOR_NAME" ] && api_select "$OUTER_PATH" "$SSPAI_NAME"; then
			outer=$(api_current "$OUTER_PATH" "$outer_file" 2>/dev/null || true)
			if [ "$outer" = "$SSPAI_NAME" ]; then
				owned=1
				mode=fallback
				active_account=SSPAI
				append_event fallback SSPAI || true
				set_runtime fallback SSPAI
			else
				set_runtime unavailable "$alias"
			fi
		else
			set_runtime unavailable "$alias"
		fi
	fi

	state_save || true
	rm -f "$outer_file" "$inner_file"
)

case "${1:-run}" in
	--once) run_once ;;
	--status) print_status ;;
	--enable) control_state enable ;;
	--disable) control_state disable ;;
	*) while :; do run_once; sleep 60; done ;;
esac
