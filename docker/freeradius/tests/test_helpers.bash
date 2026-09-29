#!/usr/bin/env bash
# Shared helpers for BATS tests of init-freeradius.sh
#
# These helpers source the init script in a controlled way so we can test its
# pure functions without executing the full entrypoint (which would try to
# connect to MySQL and start FreeRADIUS).
#
# Strategy: source the script but short-circuit the main flow. The script's
# top-level code (create_mysql_defaults_file, wait_for_mysql, etc.) runs on
# source, so we must guard it. We do this by defining a fake `main` guard:
# the script has no main() wrapper, so instead we source only up to the
# function definitions by extracting them, OR we set env vars that make the
# top-level code a no-op.
#
# Simplest robust approach: source the script with a trap that exits before
# the top-level execution reaches MySQL. We use `set -e` semantics carefully.
#
# NOTE: This relies on the script's structure. If the entrypoint changes, the
# guard below must be updated.

# Path to the init script under test (relative to this file)
INIT_SCRIPT="${BATS_TEST_DIRNAME}/../init-freeradius.sh"

# Guard: the real script calls `wait_for_mysql` and `create_mysql_defaults_file`
# at top level. We override them to no-ops so sourcing is safe, then source the
# script, then restore nothing (we only need the functions).
wait_for_mysql() { :; }
create_mysql_defaults_file() { :; }
mysql_radius() { :; }
mysqladmin() { :; }
ifconfig() { :; }
ipcalc() { :; }

# Source the init script to load its function definitions.
# shellcheck source=../init-freeradius.sh
source "$INIT_SCRIPT"

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

# Create a temp dir with a fake FreeRADIUS config tree and fake snakeoil certs.
# Usage: setup_freeradius_fixture <dest_dir>
setup_freeradius_fixture() {
	local dest="$1"
	mkdir -p "$dest/mods-available"
	mkdir -p "$dest/mods-config/sql/main/mysql"
	mkdir -p "$dest/sites-available"
	mkdir -p "$dest/sites-enabled"
	mkdir -p "$dest/certs"

	# Fake EAP config with the default FreeRADIUS cert paths
	cat > "$dest/mods-available/eap" <<'EOF'
eap {
	default_eap_type = peap
	tls-config tls-common {
		private_key_file = ${certdir}/server.pem
		certificate_file = ${certdir}/server.pem
		ca_file = ${cadir}/ca.pem
	}
}
EOF

	# Fake queries.conf with IPv6-first priority (the bug)
	cat > "$dest/mods-config/sql/main/mysql/queries.conf" <<'EOF'
post-auth {
	query = "INSERT INTO radpostauth (...) VALUES ('%{%{NAS-IPv6-Address}:-%{NAS-IP-Address}}', ...)"
}
EOF

	# Fake sites-available/default
	cat > "$dest/sites-available/default" <<'EOF'
authorize {
	-sql
}
authenticate {
}
session {
	# sql
}
post-auth {
	# sql_session_start
}
EOF

	# Fake snakeoil certs
	mkdir -p /etc/ssl/certs /etc/ssl/private 2>/dev/null || true
	touch /etc/ssl/certs/ssl-cert-snakeoil.pem 2>/dev/null || true
	touch /etc/ssl/private/ssl-cert-snakeoil.key 2>/dev/null || true
}

# Point RADIUS_PATH at a fixture dir and export it for the functions under test.
# Usage: use_fixture <fixture_dir>
use_fixture() {
	export RADIUS_PATH="$1"
}
