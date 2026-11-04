-- 002-vlan-session-timeout.sql - default Session-Timeout for the VLAN groups
--
-- Owner: FreeRADIUS service (docker/freeradius/)
-- Purpose: give the VLAN groups a default one-hour session limit so that
--          clients cannot keep a session open for days. This is the value that
--          was applied by hand on radiuspro01 (2026-11-01) and that the
--          repository did not reproduce; without it, 003-interim-interval.sql
--          finds no group with Session-Timeout and does nothing on a fresh
--          deployment.
--
-- Scope: only the VLAN groups of this deployment. A group that does not exist
--        is NOT created: creating an orphan radgroupreply row for a group that
--        has no VLAN attributes would be worse than leaving it out. The
--        operator creates the groups in the daloRADIUS UI; this migration only
--        fills in the timeout for the ones that already exist.
--
-- Idempotent: a group that already has Session-Timeout (any value) is skipped,
--             so an operator override wins.
--
-- Applied by: docker/freeradius/init-freeradius.sh (apply_fork_migrations)
-- Order: *.sql is applied alphabetically, so this runs before
--        003-interim-interval.sql and 003 sees the rows created here.

DROP TEMPORARY TABLE IF EXISTS tmp_vlan_groups;

CREATE TEMPORARY TABLE tmp_vlan_groups (
    groupname VARCHAR(64) NOT NULL PRIMARY KEY
);

INSERT IGNORE INTO tmp_vlan_groups (groupname) VALUES
    ('VLAN10'),
    ('VLAN20'),
    ('VLAN40'),
    ('VLAN50'),
    ('VLAN110'),
    ('VLAN120');

-- Keep only the groups that actually exist in this database.
DELETE t
FROM tmp_vlan_groups AS t
WHERE NOT EXISTS (SELECT 1 FROM radgroupreply AS r WHERE r.groupname = t.groupname)
  AND NOT EXISTS (SELECT 1 FROM radgroupcheck AS c WHERE c.groupname = t.groupname);

INSERT INTO radgroupreply (groupname, attribute, op, value)
SELECT g.groupname, 'Session-Timeout', ':=', '3600'
FROM tmp_vlan_groups AS g
WHERE NOT EXISTS (
    SELECT 1
    FROM radgroupreply AS existing
    WHERE existing.groupname = g.groupname
      AND existing.attribute = 'Session-Timeout'
);

DROP TEMPORARY TABLE IF EXISTS tmp_vlan_groups;
