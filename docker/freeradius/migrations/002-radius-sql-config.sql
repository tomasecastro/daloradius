-- 002-radius-sql-config.sql — SQL module configuration for FreeRADIUS
--
-- Owner: FreeRADIUS service (docker/freeradius/)
-- Purpose: enables read_profiles, read_groups, and use_tunneled_reply in the
--          radcheck table. These settings are required for daloRADIUS web UI
--          to manage users and groups, and to support tunneled reply attributes
--          (general, not only UniFi).
-- Idempotent: INSERT ... SELECT ... WHERE NOT EXISTS.
--
-- Applied by: docker/freeradius/init-freeradius.sh (apply_fork_migrations)

INSERT INTO radcheck (username, attribute, op, value)
SELECT 'DEFAULT', 'read_profiles', ':=', 'yes'
WHERE NOT EXISTS (SELECT 1 FROM radcheck WHERE username = 'DEFAULT' AND attribute = 'read_profiles');

INSERT INTO radcheck (username, attribute, op, value)
SELECT 'DEFAULT', 'read_groups', ':=', 'yes'
WHERE NOT EXISTS (SELECT 1 FROM radcheck WHERE username = 'DEFAULT' AND attribute = 'read_groups');

INSERT INTO radcheck (username, attribute, op, value)
SELECT 'DEFAULT', 'use_tunneled_reply', ':=', 'yes'
WHERE NOT EXISTS (SELECT 1 FROM radcheck WHERE username = 'DEFAULT' AND attribute = 'use_tunneled_reply');
