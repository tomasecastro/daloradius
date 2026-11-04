#!/bin/bash
# Executable process script for the daloRADIUS web image (modular architecture).
# GitHub: https://github.com/lirantal/daloradius
# EOL: normalized to LF
#
# Fusion: modular architecture (docker/daloradius/) + Docker Secrets +
# operator authentication settings (local/LDAP, daloRADIUS 2.4) applied from
# environment variables on every container start.
#
# Database bootstrap, schema loading and evolutionary migrations are delegated
# to install-db.sh (see ADR-0005 in Documentacion/daloradius/arquitectura/adr/).
set -euo pipefail

DALORADIUS_PATH=/var/www/daloradius
DALORADIUS_CONF_PATH=/var/www/daloradius/app/common/includes/daloradius.conf.php

# ---------------------------------------------------------------------------
# Connection settings
# ---------------------------------------------------------------------------
MYSQL_HOST=${MYSQL_HOST:-radius-mysql}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_DATABASE=${MYSQL_DATABASE:-radius}
MYSQL_USER=${MYSQL_USER:-radius}
MYSQL_PASSWORD_ENV=${MYSQL_PASSWORD:-}
MYSQL_ROOT_PASSWORD_ENV=${MYSQL_ROOT_PASSWORD:-}

# ---------------------------------------------------------------------------
# Optional settings
# ---------------------------------------------------------------------------
PASSWORD_MIN_LENGTH=${PASSWORD_MIN_LENGTH:-}
PASSWORD_MAX_LENGTH=${PASSWORD_MAX_LENGTH:-}
DEFAULT_FREERADIUS_SERVER=${DEFAULT_FREERADIUS_SERVER:-radius}
DEFAULT_FREERADIUS_PORT=${DEFAULT_FREERADIUS_PORT:-}
DEFAULT_CLIENT_SECRET_ENV=${DEFAULT_CLIENT_SECRET:-}
MAIL_SMTPADDR=${MAIL_SMTPADDR:-}
MAIL_PORT=${MAIL_PORT:-}
MAIL_FROM=${MAIL_FROM:-}
MAIL_AUTH=${MAIL_AUTH:-}

# ---------------------------------------------------------------------------
# Operator authentication (daloRADIUS 2.4).
# Defaults keep LOCAL auth enabled and LDAP disabled, so a fresh deployment
# behaves like the 2.3 stack until an operator opts in through .env.
# ---------------------------------------------------------------------------
OPERATOR_AUTH_LOCAL_ENABLED=${DALORADIUS_OPERATOR_AUTH_LOCAL_ENABLED:-true}
OPERATOR_AUTH_LDAP_ENABLED=${DALORADIUS_OPERATOR_AUTH_LDAP_ENABLED:-false}
OPERATOR_AUTH_DEFAULT=${DALORADIUS_OPERATOR_AUTH_DEFAULT:-local}
LDAP_URI_JSON=${DALORADIUS_LDAP_URI:-[]}
LDAP_SECURITY=${DALORADIUS_LDAP_SECURITY:-starttls}
LDAP_TLS_VERIFY=${DALORADIUS_LDAP_TLS_VERIFY:-true}
LDAP_TLS_CA_FILE=${DALORADIUS_LDAP_TLS_CA_FILE:-}
LDAP_BASE_DN=${DALORADIUS_LDAP_BASE_DN:-}
LDAP_USER_BASE_DN=${DALORADIUS_LDAP_USER_BASE_DN:-}
LDAP_BIND_DN=${DALORADIUS_LDAP_BIND_DN:-}
LDAP_FILTER=${DALORADIUS_LDAP_FILTER:-}
LDAP_EXTERNAL_ID_ATTRIBUTE=${DALORADIUS_LDAP_EXTERNAL_ID_ATTRIBUTE:-}
LDAP_ALLOWED_GROUPS_JSON=${DALORADIUS_LDAP_ALLOWED_GROUPS:-[]}
LDAP_GROUP_ATTRIBUTE=${DALORADIUS_LDAP_GROUP_ATTRIBUTE:-memberOf}
LDAP_GROUP_MATCHING_RULE=${DALORADIUS_LDAP_GROUP_MATCHING_RULE:-}

function normalize_ldap_timeout {
	local value="$1"

	case "$value" in
		''|*[!0-9]*)
			echo "Invalid integer value for CONFIG_OPERATOR_AUTH_LDAP_TIMEOUT." >&2
			return 1
			;;
	esac

	# PHP interprets an unquoted leading-zero integer as octal. Canonicalize
	# the decimal string before writing it to daloradius.conf.php.
	while [ "${#value}" -gt 1 ] && [ "${value:0:1}" = 0 ]; do
		value="${value:1}"
	done

	if [ "${#value}" -gt 2 ] || { [ "${#value}" -eq 2 ] && [ "$value" -gt 30 ]; }; then
		value=30
	fi
	if [ "$value" -lt 1 ]; then
		value=1
	fi
	printf '%s' "$value"
}

LDAP_TIMEOUT=$(normalize_ldap_timeout "${DALORADIUS_LDAP_TIMEOUT:-5}")

# ---------------------------------------------------------------------------
# Helper: read a value from a Docker secret file or env var
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

# ---------------------------------------------------------------------------
# Helper: write config values into daloradius.conf.php
# ---------------------------------------------------------------------------
function escape_sed_replacement {
	printf '%s' "$1" | sed -e 's/[\/&|\\]/\\&/g'
}

function php_escape {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"
}

function php_config_set {
	local key="$1"
	local value
	value=$(escape_sed_replacement "$(php_escape "$2")")
	sed -i "s|\$configValues\['$key'\] = .*;|\$configValues['$key'] = '$value';|" "$DALORADIUS_CONF_PATH"
}

function php_config_set_boolean {
	local key="$1"
	local raw="$2"
	local value
	case "${raw,,}" in
		1|true|yes|on) value=true ;;
		0|false|no|off) value=false ;;
		*)
			echo "Invalid boolean value for ${key}." >&2
			exit 1
			;;
	esac
	sed -i "s|\$configValues\['$key'\] = .*;|\$configValues['$key'] = $value;|" "$DALORADIUS_CONF_PATH"
}

function php_config_set_integer {
	local key="$1"
	local value="$2"
	case "$value" in
		''|*[!0-9]*)
			echo "Invalid integer value for ${key}." >&2
			exit 1
			;;
	esac
	sed -i "s|\$configValues\['$key'\] = .*;|\$configValues['$key'] = $value;|" "$DALORADIUS_CONF_PATH"
}

function php_config_set_array {
	local key="$1"
	local json="$2"
	local value

	# JSON is used instead of delimiter splitting so commas, spaces and DN
	# punctuation remain data. The value is validated before touching config.
	value=$(php -r '$value = json_decode($argv[1], true); if (!is_array($value) || json_last_error() !== JSON_ERROR_NONE) { exit(1); } echo var_export($value, true);' "$json" | tr -d '\n') || {
		echo "Invalid JSON array value for ${key}." >&2
		exit 1
	}
	value=$(escape_sed_replacement "$value")
	sed -i "s|\$configValues\['$key'\] = .*;|\$configValues['$key'] = $value;|" "$DALORADIUS_CONF_PATH"
}

function init_daloradius {
	if ! test -f "$DALORADIUS_CONF_PATH" || ! test -s "$DALORADIUS_CONF_PATH"; then
		cp "$DALORADIUS_CONF_PATH.sample" "$DALORADIUS_CONF_PATH"
	fi

	local MYSQL_PASSWORD DEFAULT_CLIENT_SECRET
	MYSQL_PASSWORD=$(read_secret_or_env "MYSQL_PASSWORD" "MYSQL_PASSWORD" "$MYSQL_PASSWORD_ENV")
	[ -z "$MYSQL_PASSWORD" ] && { echo "FATAL: MYSQL_PASSWORD not set. Define it in .env or as a Docker secret." >&2; exit 1; }
	DEFAULT_CLIENT_SECRET=$(read_secret_or_env "DEFAULT_CLIENT_SECRET" "DEFAULT_CLIENT_SECRET" "$DEFAULT_CLIENT_SECRET_ENV")
	[ -z "$DEFAULT_CLIENT_SECRET" ] && { echo "FATAL: DEFAULT_CLIENT_SECRET not set. Define it in .env or as a Docker secret." >&2; exit 1; }

	php_config_set "CONFIG_DB_HOST" "$MYSQL_HOST"
	php_config_set "CONFIG_DB_PORT" "$MYSQL_PORT"
	php_config_set "CONFIG_DB_PASS" "$MYSQL_PASSWORD"
	php_config_set "CONFIG_DB_USER" "$MYSQL_USER"
	php_config_set "CONFIG_DB_NAME" "$MYSQL_DATABASE"
	php_config_set "FREERADIUS_VERSION" "3"
	php_config_set "CONFIG_DB_PASSWORD_ENCRYPTION" "no"

	[ -n "$PASSWORD_MIN_LENGTH" ] && php_config_set "CONFIG_DB_PASSWORD_MIN_LENGTH" "$PASSWORD_MIN_LENGTH"
	[ -n "$PASSWORD_MAX_LENGTH" ] && php_config_set "CONFIG_DB_PASSWORD_MAX_LENGTH" "$PASSWORD_MAX_LENGTH"

	php_config_set "CONFIG_MAINT_TEST_USER_RADIUSSERVER" "$DEFAULT_FREERADIUS_SERVER"
	[ -n "$DEFAULT_FREERADIUS_PORT" ] && php_config_set "CONFIG_MAINT_TEST_USER_RADIUSPORT" "$DEFAULT_FREERADIUS_PORT"
	php_config_set "CONFIG_MAINT_TEST_USER_RADIUSSECRET" "$DEFAULT_CLIENT_SECRET"

	[ -n "$MAIL_SMTPADDR" ] && php_config_set "CONFIG_MAIL_SMTPADDR" "$MAIL_SMTPADDR"
	[ -n "$MAIL_PORT" ] && php_config_set "CONFIG_MAIL_SMTPPORT" "$MAIL_PORT"
	[ -n "$MAIL_FROM" ] && php_config_set "CONFIG_MAIL_SMTPFROM" "$MAIL_FROM"
	[ -n "$MAIL_AUTH" ] && php_config_set "CONFIG_MAIL_SMTPAUTH" "$MAIL_AUTH"

	php_config_set "CONFIG_LOG_FILE" "/var/www/daloradius/var/log/daloradius.log"

	chown www-data:www-data "$DALORADIUS_CONF_PATH"
	chmod 0600 "$DALORADIUS_CONF_PATH"

	echo "daloRADIUS initialization completed."
}

function refresh_operator_auth_config {
	if [ ! -s "$DALORADIUS_CONF_PATH" ]; then
		return
	fi

	# Operator-auth settings are runtime deployment settings: apply them on
	# every container start, not only while creating the data volume.
	php_config_set_boolean "CONFIG_OPERATOR_AUTH_LOCAL_ENABLED" "$OPERATOR_AUTH_LOCAL_ENABLED"
	php_config_set_boolean "CONFIG_OPERATOR_AUTH_LDAP_ENABLED" "$OPERATOR_AUTH_LDAP_ENABLED"
	php_config_set "CONFIG_OPERATOR_AUTH_DEFAULT" "$OPERATOR_AUTH_DEFAULT"
	php_config_set_array "CONFIG_OPERATOR_AUTH_LDAP_URI" "$LDAP_URI_JSON"
	php_config_set "CONFIG_OPERATOR_AUTH_LDAP_SECURITY" "$LDAP_SECURITY"
	php_config_set_boolean "CONFIG_OPERATOR_AUTH_LDAP_TLS_VERIFY" "$LDAP_TLS_VERIFY"
	[ -n "$LDAP_TLS_CA_FILE" ] && php_config_set "CONFIG_OPERATOR_AUTH_LDAP_TLS_CA_FILE" "$LDAP_TLS_CA_FILE"
	[ -n "$LDAP_BASE_DN" ] && php_config_set "CONFIG_OPERATOR_AUTH_LDAP_BASE_DN" "$LDAP_BASE_DN"
	[ -n "$LDAP_USER_BASE_DN" ] && php_config_set "CONFIG_OPERATOR_AUTH_LDAP_USER_BASE_DN" "$LDAP_USER_BASE_DN"
	[ -n "$LDAP_BIND_DN" ] && php_config_set "CONFIG_OPERATOR_AUTH_LDAP_BIND_DN" "$LDAP_BIND_DN"
	[ -n "$LDAP_FILTER" ] && php_config_set "CONFIG_OPERATOR_AUTH_LDAP_FILTER" "$LDAP_FILTER"
	[ -n "$LDAP_EXTERNAL_ID_ATTRIBUTE" ] && php_config_set "CONFIG_OPERATOR_AUTH_LDAP_EXTERNAL_ID_ATTRIBUTE" "$LDAP_EXTERNAL_ID_ATTRIBUTE"
	php_config_set_integer "CONFIG_OPERATOR_AUTH_LDAP_TIMEOUT" "$LDAP_TIMEOUT"
	php_config_set_array "CONFIG_OPERATOR_AUTH_LDAP_ALLOWED_GROUPS" "$LDAP_ALLOWED_GROUPS_JSON"
	php_config_set "CONFIG_OPERATOR_AUTH_LDAP_GROUP_ATTRIBUTE" "$LDAP_GROUP_ATTRIBUTE"
	[ -n "$LDAP_GROUP_MATCHING_RULE" ] && php_config_set "CONFIG_OPERATOR_AUTH_LDAP_GROUP_MATCHING_RULE" "$LDAP_GROUP_MATCHING_RULE"

	chown www-data:www-data "$DALORADIUS_CONF_PATH"
	chmod 0600 "$DALORADIUS_CONF_PATH"
	return 0
}

echo "Starting daloRADIUS..."

INIT_LOCK=/data/.init_done
if test -f "$INIT_LOCK"; then
	if ! test -f "$DALORADIUS_CONF_PATH" || ! test -s "$DALORADIUS_CONF_PATH"; then
		echo "Init lock file exists but config file does not exist or is 0 bytes, performing initial setup of daloRADIUS."
		init_daloradius
	fi
	echo "Init lock file exists and config file exists, skipping initial setup of daloRADIUS."
else
	init_daloradius
	date > "$INIT_LOCK"
fi

# Operator auth (local/LDAP) is applied on every start, so changing .env and
# restarting the container is enough to switch providers.
refresh_operator_auth_config

# Wait for MariaDB to accept connections (credentials never exposed in argv).
MYSQL_ROOT_PASSWORD=$(read_secret_or_env "MYSQL_ROOT_PASSWORD" "MYSQL_ROOT_PASSWORD" "$MYSQL_ROOT_PASSWORD_ENV")
[ -z "$MYSQL_ROOT_PASSWORD" ] && { echo "FATAL: MYSQL_ROOT_PASSWORD not set. Define it in .env or as a Docker secret." >&2; exit 1; }

echo -n "Waiting for mysql ($MYSQL_HOST)..."
ping_defaults_file=$(mktemp)
chmod 600 "$ping_defaults_file"
{
	printf '[client]\n'
	printf 'host=%s\n' "$MYSQL_HOST"
	printf 'user=root\n'
	printf 'password=%s\n' "$MYSQL_ROOT_PASSWORD"
} > "$ping_defaults_file"
while ! mysqladmin --defaults-extra-file="$ping_defaults_file" ping --skip-ssl --silent; do
	sleep "${MYSQL_WAIT_INTERVAL:-5}"
done
rm -f "$ping_defaults_file"
echo "ok"

DB_LOCK=/data/.db_init_done
if test -f "$DB_LOCK"; then
	echo "Database lock file exists, install-db.sh will run idempotently."
fi
# Database setup (DB creation, schemas, migrations, version registration)
# is delegated to install-db.sh (see ADR-0005). The script is idempotent.
bash "$DALORADIUS_PATH/docker/daloradius/install-db.sh" 2>/dev/null || true

# Suppress Apache FQDN warning (guard against duplicate on restart)
grep -qxF 'ServerName radius-web' /etc/apache2/apache2.conf || echo 'ServerName radius-web' >> /etc/apache2/apache2.conf

# Start Apache2 in the foreground
exec /usr/sbin/apachectl -DFOREGROUND -k start
