# FreeRADIUS — daloRADIUS Docker

Standalone FreeRADIUS service for daloRADIUS, decoupled from the root
`docker-compose.yml` into its own directory (modular architecture, stage 3a).

## Quick start

```bash
# From the project root (path resolution is relative to this file's directory)
docker compose -f docker/freeradius/docker-compose.yml up -d
```

This compose file **includes MariaDB automatically** (`include: ../mariadb/docker-compose.yml`).
To use an external database instead, set `MYSQL_HOST` (see Environment variables below).

> **Note**: Do NOT use `--project-directory` with these files — it changes path
> resolution and breaks the volume mounts. All relative paths use the `../../`
> prefix resolved from `docker/freeradius/` to the project root.

## Features (stage 3a — base)

The init script (`init-freeradius.sh`) configures FreeRADIUS on first start:

| Feature | Detail |
|---------|--------|
| **Docker Secrets** | Credentials read from `/run/secrets/*` first, falling back to env vars (`read_secret_or_env()`) — no hardcoded values, FATAL if missing |
| **SQL backend** | MySQL driver enabled, dialect mysql, read_clients + SQL counter + ippool linked |
| **Max-All-Session** | `noresetcounter` enforced in authorize |
| **SQL session tracking** | Simultaneous-Use limits (`sql_session_start`) |
| **Group NAS restrictions** | `radgroupcheck` enforcement with reject policy |
| **NAS auto-register** | Docker subnet client registered idempotently |
| **Logs** | Auth logging (`auth = yes`), status site enabled, log tailing via `docker logs radius` |
| **Graceful shutdown** | SIGTERM/SIGINT trap with clean FreeRADIUS stop |

## Roadmap — evolutivos (commits siguientes)

> Estos evolutivos llegan en commits posteriores del plan de desacoplamiento:

| Stage | Feature | Estado |
|-------|---------|:---:|
| 3b | SQL `read_profiles` + `read_groups` + TLS `enabled` (oportunístico) | ⏳ pendiente |
| 3c | Dynamic VLAN post-auth + default Session-Timeout 3600 | ⏳ pendiente |
| 3d | EAP/TLS certs: auto-generación + externos (`cert_ext`/`private_ext`) + snakeoil | ⏳ pendiente |
| 3e | Security hardening (SQL escapes, code-review fixes) | ⏳ pendiente |

## TLS / EAP certificates

Certificate management (auto-generation and external certificates via
`ssl/cert_ext` and `ssl/private_ext` bind mounts) arrives in **stage 3d**.
The mount directories exist already (`.gitkeep` placeholders) so the volume
wiring in `docker-compose.yml` is ready.

> Full certificate management documentation lives in
> `Documentacion/daloradius/agents/api-developer/19-freeradius-evolutivos-certificados.md`
> (internal) and `doc/setup/docker-compose.md` (public, added later).

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TZ` | `Europe/Vienna` | Container timezone |
| `MYSQL_HOST` | `radius-mysql` | DB host (set for external DB) |
| `MYSQL_PORT` | `3306` | DB port |
| `MYSQL_DATABASE` | `radius` | DB name |
| `MYSQL_USER` | `radius` | DB user |
| `MYSQL_PASSWORD` | *(secret)* | DB password — **secret file `secrets/db/mysql_password` wins** |
| `DEFAULT_CLIENT_SECRET` | *(secret)* | NAS shared secret — **secret file `secrets/daloradius/daloradius_client_secret` wins** |
| `FREERADIUS_SQL_TLS` | `disabled` | Set `enabled`/`require` for TLS to MariaDB (full support in 3b) |

> Credentials are declared as env vars in `docker-compose.yml` **for documentation
> only** — the real source is the Docker Secret at `/run/secrets/*`, which
> `read_secret_or_env()` reads first. The env vars are never used when secrets are
> mounted (never exposed via `docker inspect`).

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| `1812` | UDP | RADIUS authentication |
| `1813` | UDP | RADIUS accounting |

## Healthcheck

Validates FreeRADIUS status via `radclient` against the status server on
`127.0.0.1:18121`, with a 30s start period before failure.

## Files

- `Dockerfile` — based on `freeradius/freeradius-server:3.2.8`, adds `ipcalc`, `tzdata`, `net-tools`, `mariadb-client`
- `init-freeradius.sh` — entrypoint: configures SQL, sessions, groups, then runs FreeRADIUS
- `docker-compose.yml` — service definition (includes MariaDB, mounts secrets and cert volumes)
- `ssl/cert_ext/`, `ssl/private_ext/` — bind-mount targets for external certificates (`.gitkeep` placeholders, used in 3d)
