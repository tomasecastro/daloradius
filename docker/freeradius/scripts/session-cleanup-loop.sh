#!/bin/sh
# Hourly runner for the orphan-session cleanup (Spec 012).
#
# Containers do not run a cron daemon, so the FreeRADIUS entrypoint starts this
# loop in the background. Every tick it calls limpiar-sesiones-radius.sh, which
# is idempotent and protected by a database advisory lock.
#
# Environment:
#   SESSION_CLEANUP_INTERVAL_SECONDS  Tick interval (default 3600).
#                                     Set to 0 to disable the runner.
set -u

INTERVAL="${SESSION_CLEANUP_INTERVAL_SECONDS:-3600}"
SCRIPT="/app/scripts/limpiar-sesiones-radius.sh"
LOG_FILE="/var/log/freeradius/session-cleanup-runner.log"

if [ "$INTERVAL" = "0" ]; then
	echo "session cleanup runner disabled (SESSION_CLEANUP_INTERVAL_SECONDS=0)."
	exit 0
fi

case "$INTERVAL" in
	''|*[!0-9]*)
		echo "Invalid SESSION_CLEANUP_INTERVAL_SECONDS='$INTERVAL'; using 3600." >&2
		INTERVAL=3600
		;;
esac

if [ ! -x "$SCRIPT" ]; then
	echo "session cleanup script $SCRIPT not found or not executable; runner not started." >&2
	exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

echo "session cleanup runner started (interval ${INTERVAL}s)."

while true; do
	# Run once shortly after boot, then every INTERVAL seconds: orphan
	# sessions can already exist when a rebuilt stack comes back up.
	sleep 30
	"$SCRIPT" >> "$LOG_FILE" 2>&1 || true
	sleep "$INTERVAL"
done
