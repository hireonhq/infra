# HireOn infrastructure

Compose files, Caddy route and operational scripts for the HireOn stack. Code lives
in `hireonhq/backend`, `hireonhq/frontend` and `hireonhq/ml-services`; this repository
holds only how they are run.

## Why this repository exists

The configuration used to sit in `/root/docker/<service>/` on the VPS, outside
version control: no history, no review, no way to see what changed before an
incident. It also built images on the host, so the artifact that ran in production
was never the artifact CI had tested.

Two rules follow from that:

1. **Images are pulled from GHCR, never built here.** What the pipeline tested is
   what runs.
2. **Every change to this repository is a reviewable commit**, including the Caddy
   route and the compose files.

## Topology

```
                    internet
                       │  https
                       ▼
                  ┌─────────┐
                  │  Caddy  │  (own compose project, ports 80/443)
                  └────┬────┘
                       │ caddy_default network
                       ▼
                ┌─────────────┐
                │  frontend   │  Next.js :3000   ← the only public service
                └──────┬──────┘
                       │ internal network
                       │ /api/* proxied by app/api/[...path]/route.ts
                       ▼
                ┌─────────────┐
                │   backend   │  Go :8080        ← no public route, no CORS
                └──┬───────┬──┘
                   │       │
                   ▼       ▼
            ┌──────────┐ ┌────────────┐
            │ postgres │ │ ml-service │
            └──────────┘ └────────────┘
```

Only the frontend is routed to. The browser calls `hireon.evanhfw.my.id`, and
Next.js proxies `/api/*` to the backend over the Docker network, so:

- the API has no public hostname and needs no CORS policy
- the internal hostname is never inlined into the browser bundle
- `/healthz` lives outside `/api` so the frontend's own probe is not proxied away

## First-time setup

```bash
git clone git@github.com:hireonhq/infra.git && cd infra
cp .env.example .env && chmod 600 .env   # then fill it in
docker network create caddy_default      # if Caddy is not already running
```

Secrets are generated, not chosen:

```bash
openssl rand -base64 32   # POSTGRES_PASSWORD
openssl rand -hex 32      # ML_SERVICE_API_KEY
```

## Deploying

`scripts/deploy.sh` is the only supported path. It waits for each layer to be
healthy before starting the next, takes a backup before any schema change, and
records the previous tags so a rollback is one command.

```bash
./scripts/deploy.sh                  # deploy the tags pinned in .env
./scripts/deploy.sh --tag <git-sha>  # deploy a specific build
./scripts/deploy.sh --dry-run        # show what would happen
./scripts/deploy.sh --rollback       # return to the previous tags
```

Order matters and is enforced by the script: postgres → backup → backend
(migrations run on startup) → health check → frontend → public smoke test.

Migrations are additive by convention. A migration that drops or rewrites a column
needs a two-step deploy: add and backfill, then remove in a later release. The
backend refuses to start if an already-applied migration file has been edited, which
catches the common mistake of changing history instead of adding a new file.

## Backups

```bash
./scripts/backup.sh --list
./scripts/backup.sh            # dump + prune older than BACKUP_RETENTION_DAYS
./scripts/backup.sh --verify backups/hireon-20260101-120000.dump.gz
```

Run daily from cron:

```cron
0 3 * * * /root/personal/hireon/infra/scripts/backup.sh >> /var/log/hireon-backup.log 2>&1
```

Dumps land in `backups/` with mode 600. **They are not off-site.** Copy them
somewhere else (another host, or object storage) as a separate step; a backup on the
same disk does not survive the failure it is meant to cover.

## Disaster recovery

```bash
./scripts/restore.sh --file backups/<dump>.gz --yes
```

Not covered by the dump:

- **CV embeddings** live in the ML service, not Postgres. After a restore, re-run
  embedding for affected users, or recommendations will be stale or missing.
- **Uploaded files** live in object storage (R2). Check the bucket is intact and
  matches the `cv_url` values in `profiles`.

## Restoring a migration

```bash
docker compose -f compose/docker-compose.yml run --rm \
  -e MIGRATE_ALLOW_DOWN=yes backend migrate down 1
```

`MIGRATE_ALLOW_DOWN=yes` is required so a stray command cannot drop tables.

## Inspecting the database

No published port. Reach it through the container:

```bash
docker compose -f compose/docker-compose.yml exec postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

## Logs

```bash
docker compose -f compose/docker-compose.yml logs -f backend
docker compose -f compose/docker-compose.yml logs -f frontend
```

Container logs are capped at 10 MB × 3 files. Caddy writes access logs to its own
volume.
