#!/bin/bash
# install-db.sh — Install the complete database for daloRADIUS
#
# Four-phase execution (see ADR-0005):
#
#   Phase 0 — Validate vars + build --defaults-extra-file (mktemp + chmod 600)
#     All MySQL commands use --defaults-extra-file. Passing -p"$PASS" on the
#     command line is PROHIBITED (password visible via `ps`).
#
#   Phase 1 — Base schemas (from contrib/db/) + create DB/user + collation fix
#     Only runs if the `dictionary` table does NOT exist (first install).
#     0. (subetapa) Create database + app user (uses root password, moved here
#        from init_database() of init-daloradius.sh — see ADR-0005)
#     1. contrib/db/fr3-mariadb-freeradius.sql  (FreeRADIUS schema)
#     2. contrib/db/mariadb-daloradius.sql       (daloRADIUS schema + dictionaries)
#     3. Collation fix: CONVERT all tables to utf8mb4_uca1400_ai_ci
#
#   Phase 2 — Evolutionary migrations
#     Always runs. Each migration is tracked in the _schema_migrations table;
#     already-applied files are skipped. Executed in deterministic order
#     (ADR-0004): oficiales first, personalizadas after.
#     Phase 2a — Official (contrib/db/migrations/*.sql)   prefix: official/
#     Phase 2b — Custom   (docker/daloradius/migrations/)  prefix: custom/
#
#   Phase 3 — Register/update version in _app_version (see ADR-0002)
#     Reads $DALORADIUS_PATH/app/common/includes/version.php, extracts
#     DALORADIUS_VERSION and DALORADIUS_DATE, and either INSERTs a new row
#     (fresh/upgrade) or UPDATEs updated_at (reinstall). The _app_version
#     table is created by the custom/000-app-version.sql migration in Phase 2b.
#
# Before any change, a full mariadb-dump backup is created at
# /data/backups/pre-migration-{YYYYMMDD-HHMMSS}.sql.
# Backups older than 30 days are pruned automatically.
#
# Usage:
#   bash docker/daloradius/install-db.sh
#
# Required environment variables:
#   MYSQL_PASSWORD  — Password for the daloRADIUS database user
#   MYSQL_HOST      — MariaDB hostname
#
# Optional environment variables:
#   MYSQL_USER      — Database user (default: radius)
#   MYSQL_PORT      — Database port (default: 3306)
#   MYSQL_DATABASE  — Database name (default: radius)
#   MYSQL_ROOT_PASSWORD  — Root password (required for create DB/user + backup via mariadb-dump)
#   BACKUP_DIR      — Backup directory (default: /data/backups)
#   BACKUP_RETENTION_DAYS — Days to keep backups (default: 30)
#   DALORADIUS_PATH — Path to daloRADIUS root (default: auto-detected)

set -euo pipefail

# ---- Logging helpers ----
log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_fatal() { log_error "$@"; exit 1; }

# ---- Docker Secret support ----
# Read a value from /run/secrets/<name> when available, falling back to env var.
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

# ---- SQL escape helper for single-quoted string context ----
# Escapes '\' -> '\\' and "'" -> "''" (SQL defensible single-quote doubling).
sql_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

# ---- Validate required vars ----
# MYSQL_PASSWORD may come from a Docker secret or env var.
MYSQL_PASSWORD="$(read_secret_or_env "MYSQL_PASSWORD" "MYSQL_PASSWORD")"
: "${MYSQL_PASSWORD:?FATAL: MYSQL_PASSWORD not set. Define it in .env or as a Docker secret.}"
: "${MYSQL_HOST:?FATAL: MYSQL_HOST not set.}"

# MYSQL_ROOT_PASSWORD may come from a Docker secret or env var (optional but
# required to create DB + user in Phase 1 subetapa and for mariadb-dump backup).
MYSQL_ROOT_PASSWORD="$(read_secret_or_env "MYSQL_ROOT_PASSWORD" "MYSQL_ROOT_PASSWORD")"

MYSQL_USER="${MYSQL_USER:-radius}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_DATABASE="${MYSQL_DATABASE:-radius}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# ---- Determine paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DALORADIUS_PATH="${DALORADIUS_PATH:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CONTRIB_DB_DIR="$DALORADIUS_PATH/contrib/db"
MIGRATIONS_DIR="$SCRIPT_DIR/migrations"

# ---- Build defaults-extra-file for mysql client ----
build_defaults_file() {
	local user="$1" password="$2"
	local f
	f=$(mktemp)
	chmod 600 "$f"
	{
		printf '[client]\n'
		printf 'host=%s\n' "$MYSQL_HOST"
		printf 'port=%s\n' "$MYSQL_PORT"
		printf 'user=%s\n' "$user"
		printf 'password=%s\n' "$password"
	} > "$f"
	echo "$f"
}

# Build app user defaults file (exported as DEFAULTS_FILE for reuse in Phase 3)
app_defaults_file=$(build_defaults_file "$MYSQL_USER" "$MYSQL_PASSWORD")
DEFAULTS_FILE="$app_defaults_file"
export DEFAULTS_FILE

# Build root defaults file (if root password available)
root_defaults_file=""
if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
	root_defaults_file=$(build_defaults_file "root" "$MYSQL_ROOT_PASSWORD")
fi

cleanup() {
	rm -f "$app_defaults_file" "${root_defaults_file:-}"
}
trap cleanup EXIT

# ---- MySQL helper ----
mysql_cmd() {
	local defaults="$1"; shift
	mysql --defaults-extra-file="$defaults" --skip-ssl "$MYSQL_DATABASE" "$@"
}

# ---- Backup ----
backup_database() {
	local backup_dir="$BACKUP_DIR"
	local timestamp
	timestamp=$(date +%Y%m%d-%H%M%S)
	local backup_file="$backup_dir/pre-migration-${timestamp}.sql"

	mkdir -p "$backup_dir"

	if [ -z "${root_defaults_file:-}" ]; then
		log_warn "MYSQL_ROOT_PASSWORD not set — attempting backup with app user (may miss routines/events)."
	fi

	local dump_defaults="${root_defaults_file:-$app_defaults_file}"

	log_info "Creating backup: $backup_file ..."

	# Use full backup — all databases or just the target one
	if mariadb-dump --defaults-extra-file="$dump_defaults" --skip-ssl \
		--databases "$MYSQL_DATABASE" \
		--routines --events --triggers --single-transaction --quick \
		> "$backup_file" 2>/dev/null; then
		local size
		size=$(stat --format=%s "$backup_file" 2>/dev/null || echo "0")
		log_info "Backup created: $backup_file ($size bytes)."
	else
		log_fatal "Backup FAILED — aborting to protect data. Check connectivity and permissions."
	fi
}

prune_old_backups() {
	local backup_dir="$BACKUP_DIR"
	if [ ! -d "$backup_dir" ]; then
		return
	fi

	local count
	count=$(find "$backup_dir" -name 'pre-migration-*.sql' -type f -mtime "+${BACKUP_RETENTION_DAYS}" -delete -print 2>/dev/null | wc -l)
	if [ "$count" -gt 0 ]; then
		log_info "Cleaned up $count backup(s) older than ${BACKUP_RETENTION_DAYS} days."
	fi
}

# ---- Phase 1: Base schemas ----
# Subetapa 0: Create database + app user (moved from init_database() of
# init-daloradius.sh — see ADR-0005). Uses root defaults file. Idempotent
# (CREATE DATABASE IF NOT EXISTS / CREATE USER IF NOT EXISTS).
ensure_database_and_user() {
	if [ -z "${root_defaults_file:-}" ]; then
		log_warn "MYSQL_ROOT_PASSWORD not set — cannot ensure database/user exist. Assuming they already do."
		return 0
	fi

	log_info "Phase 1.0: Ensuring database + app user exist ..."

	local esc_db esc_user esc_pass
	esc_db=$(sql_escape "$MYSQL_DATABASE")
	esc_user=$(sql_escape "$MYSQL_USER")
	esc_pass=$(sql_escape "$MYSQL_PASSWORD")

	# Create database if not exists
	mysql --defaults-extra-file="$root_defaults_file" --skip-ssl \
		-e "CREATE DATABASE IF NOT EXISTS \`$esc_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci;"

	# Create user for any host '%' and grant privileges
	mysql --defaults-extra-file="$root_defaults_file" --skip-ssl \
		-e "CREATE USER IF NOT EXISTS '$esc_user'@'%' IDENTIFIED BY '$esc_pass';"
	mysql --defaults-extra-file="$root_defaults_file" --skip-ssl \
		-e "GRANT ALL PRIVILEGES ON \`$esc_db\`.* TO '$esc_user'@'%'; FLUSH PRIVILEGES;"

	log_info "Database + app user ensured."
}

# Collation fix — CONVERT all tables in the target DB to utf8mb4_uca1400_ai_ci
# (moved from init_database() of init-daloradius.sh; uses root defaults file).
fix_collations() {
	if [ -z "${root_defaults_file:-}" ]; then
		log_warn "MYSQL_ROOT_PASSWORD not set — skipping collation fix."
		return 0
	fi

	local esc_db
	esc_db=$(sql_escape "$MYSQL_DATABASE")

	local tables
	tables=$(mysql --defaults-extra-file="$root_defaults_file" --skip-ssl -N -e \
		"SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$esc_db' AND TABLE_TYPE='BASE TABLE';" "$esc_db" 2>/dev/null || echo "")

	for table in $tables; do
		mysql --defaults-extra-file="$root_defaults_file" --skip-ssl "$esc_db" \
			-e "ALTER TABLE \`$table\` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci;" 2>/dev/null || true
	done
}

run_base_schemas() {
	log_info "--- Phase 1: Base schemas ---"

	# Subetapa 0 — ensure DB + user exist (needs root)
	ensure_database_and_user

	# Check if dictionary table exists (signal that DB is already initialized)
	local dict_count
	dict_count=$(mysql_cmd "$app_defaults_file" \
		--batch --skip-column-names \
		-e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE' AND table_name='dictionary';" 2>/dev/null || echo "0")

	if [ "$dict_count" != "0" ]; then
		log_info "Table 'dictionary' already exists — skipping base schemas."
		# Even on update, run collation fix to keep tables consistent
		fix_collations
		return 0
	fi

	log_info "First install detected — applying base schemas."

	# 1. FreeRADIUS schema (idempotent via CREATE TABLE IF NOT EXISTS)
	local fr_schema="$CONTRIB_DB_DIR/fr3-mariadb-freeradius.sql"
	if [ -f "$fr_schema" ]; then
		log_info "Applying FreeRADIUS schema: $fr_schema ..."
		mysql_cmd "$app_defaults_file" < "$fr_schema" 2>/dev/null || {
			log_warn "FreeRADIUS schema had non-fatal errors (tables may already exist)."
		}
	else
		log_warn "FreeRADIUS schema not found: $fr_schema — skipping."
	fi

	# 2. daloRADIUS schema
	local dr_schema="$CONTRIB_DB_DIR/mariadb-daloradius.sql"
	if [ -f "$dr_schema" ]; then
		log_info "Applying daloRADIUS schema: $dr_schema ..."
		mysql_cmd "$app_defaults_file" < "$dr_schema" 2>/dev/null || {
			log_warn "daloRADIUS schema had non-fatal errors (tables may already exist)."
		}
	else
		log_warn "daloRADIUS schema not found: $dr_schema — skipping."
	fi

	# 3. Collation fix on all tables
	fix_collations

	log_info "Phase 1 complete."
}

# ---- Phase 2: Evolutionary migrations ----
# Apply a single migration if not already recorded in _schema_migrations.
# Args: $1 = migration key (with prefix, e.g. "custom/000-app-version.sql")
#       $2 = path to .sql file on disk
apply_migration_if_needed() {
	local key="$1"
	local migration="$2"

	# Check if already applied
	local already
	already=$(mysql_cmd "$app_defaults_file" \
		--batch --skip-column-names \
		-e "SELECT COUNT(*) FROM _schema_migrations WHERE filename = '$key';" 2>/dev/null || echo "0")

	if [ "$already" != "0" ]; then
		log_info "Skipping $key (already applied)."
		echo "skipped"
		return 0
	fi

	log_info "Applying migration: $key ..."
	if mysql_cmd "$app_defaults_file" < "$migration" 2>/dev/null; then
		# Record as applied
		mysql_cmd "$app_defaults_file" \
			-e "INSERT IGNORE INTO _schema_migrations (filename) VALUES ('$key');" 2>/dev/null || true
		log_info "Migration $key applied successfully."
		echo "applied"
	else
		log_warn "Migration $key FAILED — skipping (non-fatal)."
		echo "failed"
	fi
}

run_migrations() {
	log_info "--- Phase 2: Evolutionary migrations ---"
	local OFFICIAL_MIGRATIONS_DIR="$CONTRIB_DB_DIR/migrations"

	# Ensure _schema_migrations tracking table exists
	mysql_cmd "$app_defaults_file" \
		-e "CREATE TABLE IF NOT EXISTS _schema_migrations (
			filename VARCHAR(255) NOT NULL PRIMARY KEY,
			applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;" 2>/dev/null || {
		log_fatal "Could not create _schema_migrations table. Aborting."
	}

	local count_applied=0
	local count_skipped=0
	local count_failed=0
	local result

	# ---- Phase 2a: Official migrations (contrib/db/migrations/*.sql) ----
	log_info "--- Phase 2a: Official migrations ---"
	if [ -d "$OFFICIAL_MIGRATIONS_DIR" ]; then
		for migration in "$OFFICIAL_MIGRATIONS_DIR"/*.sql; do
			[ -f "$migration" ] || continue
			local filename="official/$(basename "$migration")"
			result=$(apply_migration_if_needed "$filename" "$migration")
			case "$result" in
				applied) count_applied=$((count_applied + 1)) ;;
				skipped) count_skipped=$((count_skipped + 1)) ;;
				failed)  count_failed=$((count_failed + 1)) ;;
			esac
		done
	else
		log_info "Official migrations directory not found: $OFFICIAL_MIGRATIONS_DIR — skipping Phase 2a."
	fi

	# ---- Phase 2b: Custom migrations (docker/daloradius/migrations/*.sql) ----
	log_info "--- Phase 2b: Custom migrations ---"
	if [ -d "$MIGRATIONS_DIR" ]; then
		for migration in "$MIGRATIONS_DIR"/*.sql; do
			[ -f "$migration" ] || continue
			local basename_fn
			basename_fn=$(basename "$migration")
			# Skip .gitkeep / non-sql helpers
			[ "$basename_fn" = ".gitkeep" ] && continue
			local filename="custom/$basename_fn"
			result=$(apply_migration_if_needed "$filename" "$migration")
			case "$result" in
				applied) count_applied=$((count_applied + 1)) ;;
				skipped) count_skipped=$((count_skipped + 1)) ;;
				failed)  count_failed=$((count_failed + 1)) ;;
			esac
		done
	else
		log_info "Custom migrations directory not found: $MIGRATIONS_DIR — skipping Phase 2b."
	fi

	log_info "Migrations summary: $count_applied applied, $count_skipped skipped, $count_failed failed."
}

# ---- Phase 3: Register/update version in _app_version (ADR-0002, ADR-0005) ----
register_app_version() {
	log_info "--- Phase 3: Register app version in _app_version ---"
	local version_file="$DALORADIUS_PATH/app/common/includes/version.php"
	if [ ! -f "$version_file" ]; then
		log_warn "version.php not found at $version_file — skipping version registration."
		return 0
	fi

	local code_version code_date
	code_version=$(grep -oP "\$configValues\['DALORADIUS_VERSION'\]\s*=\s*'\K[^']+" "$version_file" 2>/dev/null || true)
	code_date=$(grep -oP "\$configValues\['DALORADIUS_DATE'\]\s*=\s*'\K[^']+" "$version_file" 2>/dev/null || true)

	if [ -z "$code_version" ] || [ -z "$code_date" ]; then
		log_warn "Could not extract version from version.php — skipping registration."
		return 0
	fi

	# Reuse the app defaults file built in Phase 0 (exported as DEFAULTS_FILE).
	local defaults_file="$DEFAULTS_FILE"

	# Escape values interpolated into SQL (anti SQL-injection — ADR-0002, spec 001 §4.4)
	local esc_db esc_version esc_date
	esc_db=$(sql_escape "$MYSQL_DATABASE")
	esc_version=$(sql_escape "$code_version")
	esc_date=$(sql_escape "$code_date")

	# Check if _app_version exists (created by custom/000-app-version.sql in Phase 2b)
	local table_exists
	table_exists=$(mysql --defaults-extra-file="$defaults_file" --skip-ssl --batch --skip-column-names \
		-e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$esc_db' AND table_name='_app_version';" \
		"$MYSQL_DATABASE" 2>/dev/null || echo "0")

	if [ "$table_exists" = "0" ]; then
		log_warn "_app_version table does not exist (custom/000-app-version.sql not applied) — skipping version registration."
		return 0
	fi

	local count
	count=$(mysql --defaults-extra-file="$defaults_file" --skip-ssl --batch --skip-column-names \
		-e "SELECT COUNT(*) FROM \`$esc_db\`._app_version WHERE version = '$esc_version';" \
		"$MYSQL_DATABASE" 2>/dev/null || echo "0")

	if [ "$count" = "0" ]; then
		log_info "Phase 3: registering version $code_version ($code_date) — INSERT"
		mysql --defaults-extra-file="$defaults_file" --skip-ssl \
			-e "INSERT INTO \`$esc_db\`._app_version (version, version_date, notes)
			    VALUES ('$esc_version', '$esc_date', 'Fresh install');" \
			"$MYSQL_DATABASE" 2>/dev/null || {
			log_warn "Phase 3: INSERT failed."
			return 1
		}
	else
		log_info "Phase 3: version $code_version already registered — UPDATE updated_at"
		mysql --defaults-extra-file="$defaults_file" --skip-ssl \
			-e "UPDATE \`$esc_db\`._app_version SET updated_at = NOW()
			    WHERE version = '$esc_version';" \
			"$MYSQL_DATABASE" 2>/dev/null || {
			log_warn "Phase 3: UPDATE failed."
			return 1
		}
	fi

	log_info "Phase 3 complete."
}

# ======================================================================
# Main
# ======================================================================
log_info "=== daloRADIUS install-db tool ==="
log_info "Host: $MYSQL_HOST:$MYSQL_PORT | Database: $MYSQL_DATABASE | User: $MYSQL_USER"

# Step 1: Backup
backup_database

# Step 2: Prune old backups
prune_old_backups

# Step 3: Phase 1 — Base schemas (incl. create DB/user + collation fix)
run_base_schemas

# Step 4: Phase 2 — Evolutionary migrations (2a official + 2b custom)
run_migrations

# Step 5: Phase 3 — Register/update version in _app_version
register_app_version

log_info "=== All phases completed successfully ==="
