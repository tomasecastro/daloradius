#!/bin/sh
# Periodic logrotate runner for the FreeRADIUS container.
#
# Containers do not run a cron daemon, so the entrypoint starts this loop in
# the background. It rotates the logs described in /etc/logrotate.d/freeradius
# and keeps the state file on the persistent logs volume, so the "weekly"
# schedule survives container rebuilds.
#
# Environment:
#   LOGROTATE_INTERVAL_SECONDS  How often to evaluate the policy (default 3600).
#                               Set to 0 to disable the runner entirely.
#   LOGROTATE_STATE_FILE        State file (default /var/log/freeradius/.logrotate.status).
#   LOGROTATE_CONF_FILE         Policy file (default /etc/logrotate.d/freeradius).
set -u

INTERVAL="${LOGROTATE_INTERVAL_SECONDS:-3600}"
STATE_FILE="${LOGROTATE_STATE_FILE:-/var/log/freeradius/.logrotate.status}"
CONF_FILE="${LOGROTATE_CONF_FILE:-/etc/logrotate.d/freeradius}"
LOG_FILE="/var/log/freeradius/logrotate.log"

if [ "$INTERVAL" = "0" ]; then
	echo "logrotate runner disabled (LOGROTATE_INTERVAL_SECONDS=0)."
	exit 0
fi

case "$INTERVAL" in
	''|*[!0-9]*)
		echo "Invalid LOGROTATE_INTERVAL_SECONDS='$INTERVAL'; using 3600." >&2
		INTERVAL=3600
		;;
esac

if [ ! -f "$CONF_FILE" ]; then
	echo "logrotate policy $CONF_FILE not found; runner not started." >&2
	exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")"
touch "$LOG_FILE" 2>/dev/null || true

echo "logrotate runner started (interval ${INTERVAL}s, state $STATE_FILE)."

while true; do
	# Sleep first: the container may be rebuilt frequently and the previous
	# state file decides whether a rotation is due anyway.
	sleep "$INTERVAL"

	if logrotate --state "$STATE_FILE" "$CONF_FILE" >> "$LOG_FILE" 2>&1; then
		echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') logrotate ok" >> "$LOG_FILE"
	else
		echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') logrotate failed (see above)" >> "$LOG_FILE"
	fi
done
