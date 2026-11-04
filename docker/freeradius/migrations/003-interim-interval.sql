-- 003-interim-interval.sql — accounting granularity for roaming clients (Spec 013)
--
-- Owner: FreeRADIUS service (docker/freeradius/)
-- Purpose: ask every VLAN group that already enforces Session-Timeout to send
--          Acct-Interim-Interval updates every 5 minutes. Without interim
--          updates a client that roams between access points can keep a stale
--          open session for hours, because the NAS never sends Accounting-Stop.
--
-- Scope: only groups that already have a Session-Timeout row are touched, so
--        deployments that never configured time limits are left untouched.
--        The rows themselves are created by 002-vlan-session-timeout.sql,
--        which runs first (alphabetical order); without it this migration is a
--        silent no-op on a fresh deployment.
--        Simultaneous-Use is deliberately NOT enforced globally: doing so would
--        disconnect legitimate multi-device users. It stays an opt-in per
--        user/group decision (see the spec).
--
-- Idempotent: a group that already has Acct-Interim-Interval is skipped.
--
-- Applied by: docker/freeradius/init-freeradius.sh (apply_fork_migrations)

DROP TEMPORARY TABLE IF EXISTS tmp_interim_groups;

CREATE TEMPORARY TABLE tmp_interim_groups AS
SELECT DISTINCT groupname
FROM radgroupreply
WHERE attribute = 'Session-Timeout';

INSERT INTO radgroupreply (groupname, attribute, op, value)
SELECT g.groupname, 'Acct-Interim-Interval', ':=', '300'
FROM tmp_interim_groups AS g
WHERE NOT EXISTS (
    SELECT 1
    FROM radgroupreply AS existing
    WHERE existing.groupname = g.groupname
      AND existing.attribute = 'Acct-Interim-Interval'
);

DROP TEMPORARY TABLE IF EXISTS tmp_interim_groups;
