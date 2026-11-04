#!/bin/bash
# Close orphan RADIUS accounting sessions (Spec 012).
#
# A session is "orphan" when the NAS never sent Accounting-Stop: radacct has
# acctstoptime IS NULL. This script closes every orphan older than the
# configured window, using the DATABASE clock (never the container clock) and
# capping the end time at start + window so the accounting history stays
# consistent.
#
# Design notes (see Documentacion/daloradius/specs/012-limpieza-sesiones-reproducible/):
#   - Credentials come from the Docker secret /run/secrets/MYSQL_PASSWORD or
#     the MYSQL_PASSWORD env var. Never from a literal in the repository.
#   - A MariaDB advisory lock (GET_LOCK) prevents overlapping runs across
#     containers/replicas.
#   - Batched UPDATEs keep write locks short so authentication is not blocked.
#   - Every run writes exactly one log line: date, closed, duration, result.
#   - Any failure exits non-zero and leaves data untouched.
#
# Environment:
#   SESSION_CLEANUP_WINDOW_MINUTES   Session age that makes it orphan (default 60).
#   SESSION_CLEANUP_BATCH_SIZE       Rows per UPDATE (default 1000).
#   SESSION_CLEANUP_MAX_BATCHES      Safety cap per run (default 100).
#   SESSION_CLEANUP_LOG_FILE         Log target (default /var/log/freeradius/session-cleanup.log).
#   SESSION_CLEANUP_TERMINATE_CAUSE  acctterminatecause value (default Session-Timeout).
set -uo pipefail

WINDOW_MINUTES="${SESSION_CLEANUP_WINDOW_MINUTES:-60}"
BATCH_SIZE="${SESSION_CLEANUP_BATCH_SIZE:-1000}"
MAX_BATCHES="${SESSION_CLEANUP_MAX_BATCHES:-100}"
LOG_FILE="${SESSION_CLEANUP_LOG_FILE:-/var/log/freeradius/session-cleanup.log}"
TERMINATE_CAUSE="${SESSION_CLEANUP_TERMINATE_CAUSE:-Session-Timeout}"
MYSQL_DATABASE="${MYSQL_DATABASE:-radius}"

START_EPOCH=$(date +%s)
LOCK_NAME="daloradius_session_cleanup"

log_line() {
	local status="$1"
	local closed="$2"
	local detail="${3:-}"
	local elapsed=$(( $(date +%s) - START_EPOCH ))
	mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
	printf '%s status=%s closed=%s duration=%ss window=%smin %s\n' \
		"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$status" "$closed" "$elapsed" "$WINDOW_MINUTES" "$detail" \
		>> "$LOG_FILE" 2>/dev/null || true
}

fail() {
	echo "session-cleanup: $1" >&2
	log_line "error" "0" "$1"
	exit 1
}

is_positive_integer() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -gt 0 ]
}

# --- Validate configuration ------------------------------------------------
is_positive_integer "$WINDOW_MINUTES" || fail "invalid SESSION_CLEANUP_WINDOW_MINUTES='$WINDOW_MINUTES'"
is_positive_integer "$BATCH_SIZE" || fail "invalid SESSION_CLEANUP_BATCH_SIZE='$BATCH_SIZE'"
is_positive_integer "$MAX_BATCHES" || fail "invalid SESSION_CLEANUP_MAX_BATCHES='$MAX_BATCHES'"

# --- Resolve credentials (never echo them) --------------------------------
MYSQL_PASSWORD_VALUE=""
if [ -f /run/secrets/MYSQL_PASSWORD ]; then
	MYSQL_PASSWORD_VALUE="$(cat /run/secrets/MYSQL_PASSWORD)"
elif [ -n "${MYSQL_PASSWORD:-}" ]; then
	MYSQL_PASSWORD_VALUE="$MYSQL_PASSWORD"
fi

[ -n "$MYSQL_PASSWORD_VALUE" ] || fail "MYSQL_PASSWORD not available (secret or env); nothing modified"

MYSQL_HOST="${MYSQL_HOST:-radius-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-radius}"

DEFAULTS_FILE="$(mktemp)" || fail "could not create temporary defaults file"
cleanup_defaults() { rm -f "$DEFAULTS_FILE"; }
trap cleanup_defaults EXIT
chmod 600 "$DEFAULTS_FILE"
{
	printf '[client]\n'
	printf 'host=%s\n' "$MYSQL_HOST"
	printf 'port=%s\n' "$MYSQL_PORT"
	printf 'user=%s\n' "$MYSQL_USER"
	printf 'password=%s\n' "$MYSQL_PASSWORD_VALUE"
} > "$DEFAULTS_FILE"

mysql_run() {
	mariadb --defaults-extra-file="$DEFAULTS_FILE" --batch --skip-column-names "$@"
}

# --- Preflight: table and required columns must exist (FR-011) -------------
SCHEMA_STATE="$(mysql_run "$MYSQL_DATABASE" 2>/dev/null <<'EOSQL'
SELECT CONCAT(
    (SELECT COUNT(*) FROM information_schema.tables
      WHERE table_schema = DATABASE() AND table_name = 'radacct'), ':',
    (SELECT COUNT(*) FROM information_schema.columns
      WHERE table_schema = DATABASE() AND table_name = 'radacct'
        AND column_name IN ('acctstarttime', 'acctstoptime', 'acctterminatecause'))
);
EOSQL
)" || fail "database not reachable or query failed"

if [ "$SCHEMA_STATE" != "1:3" ]; then
	fail "radacct schema not as expected (expected 1:3, got '${SCHEMA_STATE:-<empty>}')"
fi

# --- Build the batched update ---------------------------------------------
# A single MariaDB session holds the advisory lock for the whole run, so
# concurrent invocations see GET_LOCK() = 0 and skip without touching data.
SQL_FILE="$(mktemp)" || fail "could not create temporary SQL file"
cleanup_sql() { rm -f "$SQL_FILE"; }
trap 'cleanup_defaults; cleanup_sql' EXIT

{
	printf "SET @got := GET_LOCK('%s', 0);\n" "$LOCK_NAME"
	printf 'SET @closed := 0;\n'
	for _ in $(seq 1 "$MAX_BATCHES"); do
		printf 'UPDATE radacct\n'
		printf '   SET acctstoptime = DATE_ADD(acctstarttime, INTERVAL %s MINUTE),\n' "$WINDOW_MINUTES"
		printf "       acctterminatecause = '%s'\n" "$TERMINATE_CAUSE"
		printf ' WHERE @got = 1\n'
		printf '   AND acctstoptime IS NULL\n'
		printf '   AND acctstarttime < DATE_SUB(NOW(), INTERVAL %s MINUTE)\n' "$WINDOW_MINUTES"
		printf ' ORDER BY acctstarttime ASC\n'
		printf ' LIMIT %s;\n' "$BATCH_SIZE"
		printf 'SET @closed := @closed + ROW_COUNT();\n'
	done
	printf "DO RELEASE_LOCK('%s');\n" "$LOCK_NAME"
	printf "SELECT CONCAT(@got, ':', @closed);\n"
} > "$SQL_FILE"

ERROR_FILE="$(mktemp)" || fail "could not create temporary error file"
trap 'cleanup_defaults; cleanup_sql; rm -f "$ERROR_FILE"' EXIT

if ! RESULT="$(mysql_run "$MYSQL_DATABASE" < "$SQL_FILE" 2> "$ERROR_FILE")"; then
	fail "update failed: $(tail -n 1 "$ERROR_FILE" 2>/dev/null)"
fi

GOT_LOCK="${RESULT%%:*}"
CLOSED="${RESULT##*:}"

case "$GOT_LOCK" in
	1)
		case "$CLOSED" in
			''|*[!0-9]*) fail "unexpected result from database: '$RESULT'" ;;
		esac
		log_line "ok" "$CLOSED"
		echo "session-cleanup: closed $CLOSED orphan session(s) older than ${WINDOW_MINUTES}min"
		exit 0
		;;
	0)
		# Another run is in progress: record it and exit successfully.
		log_line "skipped" "0" "another run holds the lock"
		echo "session-cleanup: another run is in progress, skipping"
		exit 0
		;;
	*)
		fail "unexpected lock result: '$RESULT'"
		;;
esac
