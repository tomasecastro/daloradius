# FreeRADIUS — daloRADIUS Docker

Standalone FreeRADIUS service for daloRADIUS, decoupled from the root
`docker-compose.yml` into its own directory (ADR-0001 modular architecture).

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

## Features

The init script (`init-freeradius.sh`) configures FreeRADIUS on first start:

| Feature | Detail |
|---------|--------|
| **Docker Secrets** | Credentials read from `/run/secrets/*` first, falling back to env vars (`read_secret_or_env()`) — no hardcoded values |
| **Graceful shutdown** | SIGTERM/SIGINT trap with clean FreeRADIUS stop |
| **Log tailing** | `tail -F` on radius log so `docker logs radius` works |
| **EAP/TLS certificates** | Auto-generated on first start (or if expired); external certs via volumes supported |
| **Dynamic VLAN post-auth** | VLAN assignment from `radgroupreply`; default Session-Timeout 3600s (1h) when unset |
| **SQL session tracking** | Simultaneous-Use limits (`simul_count_query` + `sql_session_start`) |
| **Group NAS restrictions** | `radgroupcheck` enforcement with reject policy |
| **noresetcounter** | Enforce `Max-All-Session` in authorize |
| **SQL read_clients/profiles/groups** | Enabled via `use_tunneled_reply` |
| **Auto-register NAS client** | Registers the Docker subnet client idempotently |

## TLS / EAP certificates

Certificates are auto-generated on first run (or when expired) with 10 years
validity. To use **external certificates** (Let's Encrypt, custom CA, snakeoil),
bind-mount them via the volumes already defined in `docker-compose.yml`:

```
docker/freeradius/ssl/cert_ext/    → /etc/freeradius/certs/cert_ext
docker/freeradius/ssl/private_ext/ → /etc/freeradius/certs/private_ext
```

External certs are **never overwritten** by the auto-generation logic.

> Full certificate management documentation (both workflows: auto-generated and
> external) lives in `Documentacion/daloradius/agents/api-developer/16-certificados-eap-freeradius.md`
> (internal) and `doc/setup/docker-compose.md` (public).

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
| `FREERADIUS_SQL_TLS` | `disabled` | Set `enabled` for opportunistic TLS to MariaDB |

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
- `init-freeradius.sh` — entrypoint: configures TLS, SQL, VLAN, sessions, then runs FreeRADIUS
- `docker-compose.yml` — service definition (includes MariaDB, mounts secrets and cert volumes)
- `ssl/cert_ext/`, `ssl/private_ext/` — bind-mount targets for external certificates (`.gitkeep` placeholders)
