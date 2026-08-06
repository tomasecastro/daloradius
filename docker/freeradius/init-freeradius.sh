#!/bin/bash
# Executable process script for daloRADIUS FreeRADIUS docker image
# GitHub: https://github.com/lirantal/daloradius
#
# Decoupled: docker/freeradius/init-freeradius.sh (stage 3a)
# Base: upstream + Docker Secrets helpers (stage 3a). Evolutivos: 3b (SQL profiles/groups),
# 3c (VLAN post-auth), 3d (EAP certs), 3e (security hardening) - ver plan 19.
set -euo pipefail

RADIUS_PATH=/etc/freeradius
# Directory with fork SQL artifacts (mounted from docker/freeradius/migrations)
RADIUS_ARTIFACTS_DIR=/app/migrations
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_DATABASE=${MYSQL_DATABASE:-raddb}
MYSQL_USER=${MYSQL_USER:-raduser}
MYSQL_WAIT_INTERVAL=${MYSQL_WAIT_INTERVAL:-5}
FREERADIUS_SQL_TLS=${FREERADIUS_SQL_TLS:-disabled}

# ---------------------------------------------------------------------------
# Docker Secrets helper
# ---------------------------------------------------------------------------
read_secret_or_env() {
	local secret_name="$1"
	local env_name="$2"
	local default="${3:-}"
	local secret_file="/run/secrets/${secret_name}"

	if [ -f "$secret_file" ]; then
		cat "$secret_file"
	elif [ -n "${!env_name:-}" ]; then
		echo "${!env_name}"
	else
		echo "$default"
	fi
}

# Resolve sensitive values: secret file > env var (NO hardcoded fallback - must come from .env or Docker secrets)
MYSQL_PASSWORD="$(read_secret_or_env "MYSQL_PASSWORD" "MYSQL_PASSWORD")"
[ -z "$MYSQL_PASSWORD" ] && { echo "FATAL: MYSQL_PASSWORD not set. Define it in .env or as a Docker secret." >&2; exit 1; }

DEFAULT_CLIENT_SECRET="$(read_secret_or_env "DEFAULT_CLIENT_SECRET" "DEFAULT_CLIENT_SECRET")"
[ -z "$DEFAULT_CLIENT_SECRET" ] && { echo "FATAL: DEFAULT_CLIENT_SECRET not set. Define it in .env or as a Docker secret." >&2; exit 1; }

MYSQL_DEFAULTS_FILE=""

function cleanup_mysql_defaults {
	if [ -n "$MYSQL_DEFAULTS_FILE" ]; then
		rm -f "$MYSQL_DEFAULTS_FILE"
	fi
}
trap cleanup_mysql_defaults EXIT

function create_mysql_defaults_file {
	MYSQL_DEFAULTS_FILE=$(mktemp)
	chmod 600 "$MYSQL_DEFAULTS_FILE"
	{
		printf '[client]\n'
		printf 'host=%s\n' "$MYSQL_HOST"
		printf 'port=%s\n' "$MYSQL_PORT"
		printf 'user=%s\n' "$MYSQL_USER"
		printf 'password=%s\n' "$MYSQL_PASSWORD"
	} > "$MYSQL_DEFAULTS_FILE"
}

function escape_sed_replacement {
	printf '%s' "$1" | sed -e 's/[\/&|\\]/\\&/g'
}

function sql_escape {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

function mysql_radius {
	mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" "$MYSQL_DATABASE" "$@"
}

function table_exists {
	local table_name="$1"
	local escaped_table_name
	local count

	escaped_table_name=$(printf '%s' "$table_name" | sed -e "s/'/''/g")
	count=$(mysql_radius --batch --skip-column-names <<EOSQL
SELECT COUNT(*)
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name = '$escaped_table_name';
EOSQL
)

	test "$count" -gt 0
}

function tables_exist {
	local table_name

	for table_name in "$@"; do
		table_exists "$table_name" || return 1
	done
}

function sql_config_set {
	local key="$1"
	local value
	value=$(escape_sed_replacement "$2")
	sed -i "s|^#\s*$key = .*|$key = \"$value\"|" "$RADIUS_PATH/mods-available/sql"
}

function configure_sql_tls {
	case "$FREERADIUS_SQL_TLS" in
		disabled)
			sed -i 's|ca_file = "/etc/ssl/certs/my_ca.crt"|#ca_file = "/etc/ssl/certs/my_ca.crt"|' "$RADIUS_PATH/mods-available/sql"
			sed -i 's|ca_path = "/etc/ssl/certs/"|#ca_path = "/etc/ssl/certs/"|' "$RADIUS_PATH/mods-available/sql"
			sed -i 's|certificate_file = "/etc/ssl/certs/private/client.crt"|#certificate_file = "/etc/ssl/certs/private/client.crt"|' "$RADIUS_PATH/mods-available/sql"
			sed -i 's|private_key_file = "/etc/ssl/certs/private/client.key"|#private_key_file = "/etc/ssl/certs/private/client.key"|' "$RADIUS_PATH/mods-available/sql"
			sed -i 's|tls_required = yes|tls_required = no|' "$RADIUS_PATH/mods-available/sql"
			;;
		require)
			;;
		*)
			echo "Invalid FREERADIUS_SQL_TLS value '$FREERADIUS_SQL_TLS'. Use 'disabled' or 'require'." >&2
			exit 1
			;;
	esac
}

function prepare_freeradius_logs {
	mkdir -p /var/log/freeradius
	chown -R freerad:33 /var/log/freeradius
	find /var/log/freeradius -type d -exec chmod 2750 {} +
	find /var/log/freeradius -type f -exec chmod 0640 {} +
}

function init_freeradius {
	# Enable SQL in freeradius
	sed -i 's|driver = "rlm_sql_null"|driver = "rlm_sql_mysql"|' "$RADIUS_PATH/mods-available/sql"
	sed -i 's|dialect = "sqlite"|dialect = "mysql"|' "$RADIUS_PATH/mods-available/sql"
	sed -i 's|dialect = ${modules.sql.dialect}|dialect = "mysql"|' "$RADIUS_PATH/mods-available/sqlcounter" # avoid instantiation error
	configure_sql_tls
	sed -i 's|#\s*read_clients = yes|read_clients = yes|' "$RADIUS_PATH/mods-available/sql"
	ln -sf "$RADIUS_PATH/mods-available/sql" "$RADIUS_PATH/mods-enabled/sql"
	ln -sf "$RADIUS_PATH/mods-available/sqlcounter" "$RADIUS_PATH/mods-enabled/sqlcounter"
	ln -sf "$RADIUS_PATH/mods-available/sqlippool" "$RADIUS_PATH/mods-enabled/sqlippool"
	enable_noresetcounter
	sed -i 's|instantiate {|instantiate {\nsql|' "$RADIUS_PATH/radiusd.conf" # mods-enabled does not ensure the right order

	

	# Log authentication request in radius-log file
	sed -i 's|auth = no|auth = yes|' "$RADIUS_PATH/radiusd.conf"
	# Sane default log setings for authentication
	sed -i 's|#\s*msg_goodpass =.*|msg_goodpass = "authenticationtype:\\"%{control:Auth-Type}\\";nasipv4address:\\"%{request:NAS-IP-Address}\\";nasipv6address:\\"%{request:NAS-IPv6-Address}\\";nasid:\\"%{request:NAS-Identifier}\\";srcipaddress:\\"%{request:Packet-Src-IP-Address}\\";nasport:\\"%{request:NAS-Port-Id}\\";nasporttype:\\"%{request:NAS-Port-Type}\\";vlan:\\"%{reply:Tunnel-Private-Group-Id}\\";calledstationid:\\"%{request:Called-Station-Id}\\";callingstationid:\\"%{request:Calling-Station-Id}\\";session_timeout:\\"%{reply:Session-Timeout}\\""|' \
	"$RADIUS_PATH/radiusd.conf"
	sed -i 's|#\s*msg_badpass =.*|msg_badpass = "authenticationtype:\\"%{control:Auth-Type}\\";nasipv4address:\\"%{request:NAS-IP-Address}\\";nasipv6address:\\"%{request:NAS-IPv6-Address}\\";nasid:\\"%{request:NAS-Identifier}\\";srcipaddress:\\"%{request:Packet-Src-IP-Address}\\";nasport:\\"%{request:NAS-Port-Id}\\";nasporttype:\\"%{request:NAS-Port-Type}\\";calledstationid:\\"%{request:Called-Station-Id}\\";callingstationid:\\"%{request:Calling-Station-Id}\\""|' \
	"$RADIUS_PATH/radiusd.conf"

	# Enable status in freeadius
	ln -sf "$RADIUS_PATH/sites-available/status" "$RADIUS_PATH/sites-enabled/status"

	# Set Database connection
	sql_config_set "server" "$MYSQL_HOST"
	sql_config_set "port" "$MYSQL_PORT"
	sed -i "1,\$s/radius_db.*/radius_db=\"$(escape_sed_replacement "$MYSQL_DATABASE")\"/g" "$RADIUS_PATH/mods-available/sql"
	sql_config_set "password" "$MYSQL_PASSWORD"
	sql_config_set "login" "$MYSQL_USER"

	if [ -n "$DEFAULT_CLIENT_SECRET" ]; then
		sed -i "s|testing123|$(escape_sed_replacement "$DEFAULT_CLIENT_SECRET")|" "$RADIUS_PATH/mods-available/sql"
	fi

	chown root:freerad "$RADIUS_PATH/mods-available/sql"
	chmod 0640 "$RADIUS_PATH/mods-available/sql"
	echo "freeradius initialization completed."
}

function enable_noresetcounter {
	local freeradius_default_tmp
	freeradius_default_tmp=$(mktemp) || {
		echo "Failed to create temporary file."
		exit 1
	}

	# Enforce Max-All-Session limits through FreeRADIUS sqlcounter.
	# The sqlcounter module must run in authorize; enabling mods-enabled/sqlcounter alone is not enough.
	if grep -q "^[[:space:]]*noresetcounter[[:space:]]*$" "$RADIUS_PATH/sites-available/default"; then
		rm -f "$freeradius_default_tmp"
		return
	fi

	if ! awk '
		BEGIN { in_authorize = 0; added = 0 }
		/^authorize[[:space:]]*[{]/ { in_authorize = 1 }
		in_authorize && !added && /^[[:space:]]*-sql$/ {
			print
			print "\tnoresetcounter"
			added = 1
			next
		}
		/^authenticate[[:space:]]*[{]/ { in_authorize = 0 }
		{ print }
		END { exit added ? 0 : 1 }
	' "$RADIUS_PATH/sites-available/default" > "$freeradius_default_tmp"; then
		rm -f "$freeradius_default_tmp"
		echo "Failed to add noresetcounter to FreeRADIUS authorize section."
		exit 1
	fi
	mv "$freeradius_default_tmp" "$RADIUS_PATH/sites-available/default"
}
function enable_sql_session_tracking {
	local freeradius_default_tmp
	freeradius_default_tmp=$(mktemp) || {
		echo "Failed to create temporary file."
		exit 1
	}

	# Enforce Simultaneous-Use limits with SQL-backed session tracking.
	# The SQL module must run in the session section; enabling mods-enabled/sql
	# alone is not enough. sql_session_start creates an accounting row at
	# Access-Accept time to reduce the race before Accounting-Start arrives.
	if ! awk '
		BEGIN { in_session = 0; in_post_auth = 0; session_sql = 0; sql_session_start = 0 }
		/^session[[:space:]]*[{]/ { in_session = 1 }
		in_session && /^[[:space:]]*#[[:space:]]*sql[[:space:]]*$/ {
			print "	sql"
			session_sql = 1
			next
		}
		in_session && /^[[:space:]]*sql[[:space:]]*$/ { session_sql = 1 }
		in_session && /^}/ { in_session = 0 }

		/^post-auth[[:space:]]*[{]/ { in_post_auth = 1 }
		in_post_auth && /^[[:space:]]*#[[:space:]]*sql_session_start[[:space:]]*$/ {
			print "	sql_session_start"
			sql_session_start = 1
			next
		}
		in_post_auth && /^[[:space:]]*sql_session_start[[:space:]]*$/ { sql_session_start = 1 }
		in_post_auth && /^}/ { in_post_auth = 0 }

		{ print }
		END { exit (session_sql && sql_session_start) ? 0 : 1 }
	' "$RADIUS_PATH/sites-available/default" > "$freeradius_default_tmp"; then
		rm -f "$freeradius_default_tmp"
		echo "Failed to enable SQL session tracking in FreeRADIUS."
		exit 1
	fi
	mv "$freeradius_default_tmp" "$RADIUS_PATH/sites-available/default"
}


function enable_group_nas_restrictions {
	local freeradius_default_tmp
	freeradius_default_tmp=$(mktemp) || {
		echo "Failed to create temporary file."
		exit 1
	}

	# Enforce daloRADIUS group/profile NAS restrictions stored in radgroupcheck.
	# FreeRADIUS uses radgroupcheck to decide whether group reply items apply; it
	# does not automatically reject a user who already authenticated via radcheck.
	# This policy rejects users when their SQL group has NAS-IP-Address == rows
	# and the request NAS-IP-Address does not match any of those allowed values.
	if grep -q "daloRADIUS group NAS restriction policy" "$RADIUS_PATH/sites-available/default"; then
		rm -f "$freeradius_default_tmp"
		return
	fi

	if ! awk '
		BEGIN { added = 0 }
		{
			print
			if (!added && /^[[:space:]]*noresetcounter[[:space:]]*$/) {
				print ""
				print "\t\t# daloRADIUS group NAS restriction policy"
				print "\t\t# Enforce radgroupcheck NAS-IP-Address == restrictions as an"
				print "\t\t# authentication deny rule for users assigned to SQL groups."
				print "\t\tif (&request:NAS-IP-Address) {"
				print "\t\t\tif (\"%{sql:SELECT COUNT(*) FROM radusergroup ug JOIN radgroupcheck gc ON gc.groupname = ug.groupname WHERE ug.username = '\''%{User-Name}'\'' AND gc.attribute = '\''NAS-IP-Address'\'' AND gc.op = '\''=='\''}\" != \"0\") {"
				print "\t\t\t\tif (\"%{sql:SELECT COUNT(*) FROM radusergroup ug JOIN radgroupcheck gc ON gc.groupname = ug.groupname WHERE ug.username = '\''%{User-Name}'\'' AND gc.attribute = '\''NAS-IP-Address'\'' AND gc.op = '\''=='\'' AND gc.value = '\''%{NAS-IP-Address}'\''}\" == \"0\") {"
				print "\t\t\t\t\treject"
				print "\t\t\t\t}"
				print "\t\t\t}"
				print "\t\t}"
				added = 1
			}
		}
		END { exit added ? 0 : 1 }
	' "$RADIUS_PATH/sites-available/default" > "$freeradius_default_tmp"; then
		rm -f "$freeradius_default_tmp"
		echo "Failed to add daloRADIUS group NAS restriction policy to FreeRADIUS authorize section."
		exit 1
	fi
	mv "$freeradius_default_tmp" "$RADIUS_PATH/sites-available/default"
}

# ---------------------------------------------------------------------------
# Fork evolutives are applied via SQL artifacts (ADR-0008 - init only calls):
#   - docker/freeradius/migrations/001-nas-client.sql    (NAS auto-register, owner: FreeRADIUS)
#   - docker/daloradius/migrations/NNN-radhuntgroup.sql  (daloRADIUS table, owner: daloRADIUS, commit 4d)
# The init reads each artifact, substitutes runtime variables, and executes it.
# ---------------------------------------------------------------------------
function apply_fork_migrations {
	local migrations_dir="$1"
	[ -d "$migrations_dir" ] || return 0

	for sql_file in "$migrations_dir"/*.sql; do
		[ -f "$sql_file" ] || continue
		echo "Applying fork migration: $(basename "$sql_file")"

		local tmpfile
		tmpfile=$(mktemp) || { echo "Failed to create temp file." >&2; exit 1; }
		sed -e "s|\${CONTAINER_CIDR}|$(escape_sed_replacement "${container_cidr:-}")|g" \
		    -e "s|\${CLIENT_SECRET}|$(escape_sed_replacement "$DEFAULT_CLIENT_SECRET")|g" \
		    "$sql_file" > "$tmpfile"
		mysql_radius < "$tmpfile"
		rm -f "$tmpfile"
	done
}

function init_database {
	# Standard FreeRADIUS schemas (upstream) - keep them pristine.
	mysql_radius < "$RADIUS_PATH/mods-config/sql/main/mysql/schema.sql"
	mysql_radius < "$RADIUS_PATH/mods-config/sql/ippool/mysql/schema.sql"

	# Fork evolutives as SQL artifacts (ADR-0008 - init only calls):
	#   - docker/freeradius/migrations/001-nas-client.sql (NAS auto-register)
	apply_fork_migrations "$RADIUS_ARTIFACTS_DIR"

	echo "Database initialization for freeradius completed."
}

function wait_for_mysql {
	while ! mysqladmin --defaults-extra-file="$MYSQL_DEFAULTS_FILE" ping --silent; do
		echo "Waiting for mysql ($MYSQL_HOST)..."
		sleep "$MYSQL_WAIT_INTERVAL"
	done
}

echo "Starting freeradius..."
create_mysql_defaults_file
wait_for_mysql

# Container network info (needed by the NAS client artifact)
container_ip_address=$(ifconfig eth0 2>/dev/null | awk '/inet /{ print $2; exit }')
container_netmask=$(ifconfig eth0 2>/dev/null | awk '/netmask/{ print $4; exit }')
container_cidr=$(ipcalc "$container_ip_address" "$container_netmask" 2>/dev/null | awk '/Network/{ print $2; exit }')

INIT_LOCK=/data/.freeradius_init_done
if test -f "$INIT_LOCK"; then
	# Lock file exists, but verify that FreeRADIUS is actually configured
	# This handles the case where containers are recreated but volumes persist
	if test -L "$RADIUS_PATH/mods-enabled/sql" && grep -q "rlm_sql_mysql" "$RADIUS_PATH/mods-available/sql" 2>/dev/null; then
		enable_noresetcounter
		ln -sf "$RADIUS_PATH/sites-available/status" "$RADIUS_PATH/sites-enabled/status"
		echo "Init lock file exists and FreeRADIUS is properly configured, skipping initial setup."
	else
		echo "Init lock file exists but FreeRADIUS configuration is missing, reinitializing..."
		rm -f "$INIT_LOCK"
		init_freeradius
		date > "$INIT_LOCK"
	fi
else
	init_freeradius
	date > "$INIT_LOCK"
fi

# Ensure Max-All-Session is enforced before FreeRADIUS starts, including after
# lock-file and reinitialization paths.
if test -L "$RADIUS_PATH/mods-enabled/sqlcounter"; then
	enable_noresetcounter
fi

if test -L "$RADIUS_PATH/mods-enabled/sql"; then
	enable_sql_session_tracking
	enable_group_nas_restrictions
fi

DB_LOCK=/data/.db_init_done
if test -f "$DB_LOCK"; then
	echo "Database lock file exists, skipping initial setup of mysql database."
	# Always apply fork migrations (idempotent) so new artifacts apply after upgrades.
	apply_fork_migrations "$RADIUS_ARTIFACTS_DIR"
else
	if tables_exist "radcheck" "radacct" "nas"; then
		echo "Existing FreeRADIUS database schema detected, skipping initial setup of mysql database."
		apply_fork_migrations "$RADIUS_ARTIFACTS_DIR"
	else
		init_database
	fi
	date > "$DB_LOCK"
fi

prepare_freeradius_logs

# start freeradius in foreground mode
freeradius -f "$@" &
RADIUS_PID=$!

tail -F /var/log/freeradius/radius.log &
TAIL_PID=$!

# trap SIGINT/SIGTERM and forward to both processes
_term() {
  echo "Caught signal - shutting down..."
  kill -TERM "$RADIUS_PID" 2>/dev/null
  kill -TERM "$TAIL_PID" 2>/dev/null
  wait "$RADIUS_PID"
  wait "$TAIL_PID"
  exit 0
}
trap _term INT TERM

set +e
wait "$RADIUS_PID"
RADIUS_STATUS=$?
set -e
# if freeradius dies, kill the tail and exit with its code
kill -TERM "$TAIL_PID" 2>/dev/null
wait "$TAIL_PID" 2>/dev/null
exit "$RADIUS_STATUS"
