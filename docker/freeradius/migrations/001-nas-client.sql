-- 001-nas-client.sql — Docker NAS client auto-registration (FreeRADIUS)
--
-- Owner: FreeRADIUS service (docker/freeradius/)
-- Purpose: ensures the Docker subnet is registered as a RADIUS client (nas table)
--          so the container can authenticate against its own FreeRADIUS instance.
-- Idempotent: INSERT ... SELECT ... WHERE NOT EXISTS.
--
-- Applied by: docker/freeradius/init-freeradius.sh (init_database, post-lock)
-- NOTE: container_cidr and client_secret are substituted at runtime by the init
-- script (they depend on the container's network) — this file is the source of
-- truth template; the init reads it and replaces ${CONTAINER_CIDR}/${CLIENT_SECRET}
-- before execution, keeping SQL out of inline bash (ADR-0008).

INSERT INTO nas (nasname, shortname, type, ports, secret, server, community, description)
SELECT '${CONTAINER_CIDR}', 'DOCKER NET', 'other', 0, '${CLIENT_SECRET}', NULL, '', ''
WHERE NOT EXISTS (SELECT 1 FROM nas WHERE nasname = '${CONTAINER_CIDR}');