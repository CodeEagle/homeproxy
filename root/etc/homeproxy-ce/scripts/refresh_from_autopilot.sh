#!/bin/sh
#
# Run a subscription refresh from the restricted SSH key used by Autopilot.
# The command is deliberately a small, fixed interface: callers may ask for
# a readiness check or a refresh, and receive one JSON status line either way.
#

set -u
umask 077

HP_ROOT=/etc/homeproxy-ce
RUN_ROOT=/var/run/homeproxy-ce
SCRIPT_DIR="$HP_ROOT/scripts"
UPDATER="$SCRIPT_DIR/update_subscriptions.uc"
LOG_FILE="$RUN_ROOT/homeproxy.log"
CONFIG_FILE="$RUN_ROOT/sing-box-c.json"
LOCK_FILE="$RUN_ROOT/autopilot-refresh.lock"
FLOCK=/usr/bin/flock
SING_BOX=/usr/bin/sing-box
SERVICE_INIT=/etc/init.d/homeproxy-ce
TIMEOUT_SECONDS=75

LOCK_HELD=0
TMP_DIR=
WATCHDOG_PID=
UPDATER_PID=

print_status() {
	printf '{"status":"%s"}\n' "$1"
}

cleanup() {
	if [ -n "$UPDATER_PID" ]; then
		kill "$UPDATER_PID" 2>/dev/null || true
		wait "$UPDATER_PID" 2>/dev/null || true
		UPDATER_PID=
	fi
	if [ -n "$WATCHDOG_PID" ]; then
		kill "$WATCHDOG_PID" 2>/dev/null || true
		wait "$WATCHDOG_PID" 2>/dev/null || true
		WATCHDOG_PID=
	fi
	if [ -n "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR" 2>/dev/null || true
	fi
	if [ "$LOCK_HELD" -eq 1 ]; then
		"$FLOCK" -u 9 >/dev/null 2>&1 || true
		LOCK_HELD=0
	fi
}

on_signal() {
	exit 143
}

trap cleanup EXIT
trap on_signal HUP INT TERM

# The readiness command is intentionally independent of the router state.  It
# is used by a monitor to verify that the forced command is reachable without
# causing a subscription update or a service restart.
if [ "${SSH_ORIGINAL_COMMAND-}" = check ]; then
	print_status ready
	exit 0
fi

# Do not interpret, log, or execute arbitrary SSH_ORIGINAL_COMMAND values.
if [ "${SSH_ORIGINAL_COMMAND-}" != refresh ]; then
	print_status failed
	exit 2
fi

if ! mkdir -p "$RUN_ROOT" 2>/dev/null; then
	print_status failed
	exit 1
fi

if [ ! -x "$FLOCK" ]; then
	print_status failed
	exit 1
fi

# Open the lock before running any work.  The kernel releases this advisory
# lock when the wrapper exits, including an SSH disconnect, so no PID/stale
# directory protocol is needed and the mkdir-to-PID race cannot occur.
if ! exec 9>"$LOCK_FILE" 2>/dev/null; then
	print_status failed
	exit 1
fi
if ! "$FLOCK" -n 9 >/dev/null 2>&1; then
	print_status busy
	exit 1
fi
LOCK_HELD=1

TMP_DIR="$RUN_ROOT/.autopilot-refresh.$$"
rm -rf "$TMP_DIR" 2>/dev/null || true
if ! mkdir "$TMP_DIR" 2>/dev/null; then
	print_status failed
	exit 1
fi

line_count() {
	line_count_value=0
	if [ -f "$LOG_FILE" ]; then
		line_count_value=$(wc -l < "$LOG_FILE" 2>/dev/null || true)
		line_count_value=${line_count_value##* }
	fi
	case "$line_count_value" in
		''|*[!0-9]*) printf '0\n' ;;
		*) printf '%s\n' "$line_count_value" ;;
	esac
}

run_updater() {
	# Do not pass the lock descriptor into the updater or the service it
	# restarts.  Otherwise sing-box could inherit the descriptor and keep the
	# advisory lock after this wrapper exits.
	(
		exec 9>&-
		exec "$UPDATER" >"$TMP_DIR/updater.stdout" 2>"$TMP_DIR/updater.stderr"
	) &
	UPDATER_PID=$!
	timeout_marker="$TMP_DIR/timeout"
	(
		sleep "$TIMEOUT_SECONDS"
		if kill -0 "$UPDATER_PID" 2>/dev/null; then
			: > "$timeout_marker"
			kill "$UPDATER_PID" 2>/dev/null || true
		fi
	) >/dev/null 2>&1 &
	WATCHDOG_PID=$!
	wait "$UPDATER_PID"
	updater_rc=$?
	kill "$WATCHDOG_PID" 2>/dev/null || true
	wait "$WATCHDOG_PID" 2>/dev/null || true
	WATCHDOG_PID=
	UPDATER_PID=
	if [ -f "$timeout_marker" ]; then
		return 124
	fi
	return "$updater_rc"
}

before_lines=$(line_count)
run_updater
updater_rc=$?
after_lines=$(line_count)

success_marker=0
source_failure=0
if [ "$after_lines" -gt "$before_lines" ] && [ -f "$LOG_FILE" ]; then
	sed -n "$((before_lines + 1)),${after_lines}p" "$LOG_FILE" >"$TMP_DIR/new-log" 2>/dev/null || true
	if grep -Fq -e 'Failed to fetch resources' -e 'No valid node found' \
		"$TMP_DIR/new-log" 2>/dev/null; then
		source_failure=1
	fi
	if grep -Fq 'Successfully updated subscriptions.' "$TMP_DIR/new-log" 2>/dev/null; then
		success_marker=1
	fi
fi

service_rc=1
service_running=0
if [ -x "$SERVICE_INIT" ]; then
	"$SERVICE_INIT" status >"$TMP_DIR/service.status" 2>&1
	service_rc=$?
	if [ "$service_rc" -eq 0 ] && grep -Eiq '(^|[^[:alpha:]])running([^[:alpha:]]|$)' \
		"$TMP_DIR/service.status" 2>/dev/null; then
		service_running=1
	fi
fi

singbox_rc=1
if [ -s "$CONFIG_FILE" ] && [ -x "$SING_BOX" ]; then
	ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true \
		"$SING_BOX" check --config "$CONFIG_FILE" >"$TMP_DIR/sing-box-check" 2>&1
	singbox_rc=$?
fi

if [ "$updater_rc" -eq 0 ] \
	&& [ "$success_marker" -eq 1 ] \
	&& [ "$source_failure" -eq 0 ] \
	&& [ "$service_running" -eq 1 ] \
	&& [ "$singbox_rc" -eq 0 ]; then
	print_status updated
	exit 0
fi

print_status failed
exit 1
