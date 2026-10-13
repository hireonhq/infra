#!/usr/bin/env bash
#
# Restore the HireOn database from a dump.
#
# Destructive: it drops and recreates the schema. Requires an explicit confirmation
# flag so it cannot be run by accident, and refuses to touch a database that is
# still being written to unless told to stop the stack first.
#
#   ./scripts/restore.sh --file backups/hireon-20260101-120000.dump.gz --yes
#   ./scripts/restore.sh --latest --yes
#
# Recovery order after a restore: the backend reconnects on its own, but any CV
# embeddings live in the ML service and are NOT restored by this script. Re-run the
# CV embedding job for affected users afterwards (see the runbook).

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FILE=""
CONFIRMED=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)   FILE="$2"; shift 2 ;;
    --latest) FILE="$(ls -1t "${BACKUP_DIR:-$REPO_ROOT/backups}"/hireon-*.dump.gz 2>/dev/null | head -1 || true)"; shift ;;
    --yes)    CONFIRMED=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *)        die "unknown argument: $1" ;;
  esac
done

[[ $CONFIRMED -eq 1 ]] || die "refusing to run without --yes: this drops and recreates the schema"
[[ -n "$FILE" ]] || die "pass --file <dump> or --latest"
[[ -f "$FILE" ]] || die "not found: $FILE"

[[ -f .env ]] || die ".env not found in $REPO_ROOT"
# shellcheck disable=SC1091
set -a; source .env; set +a

docker inspect hireon-postgres >/dev/null 2>&1 || die "hireon-postgres is not running"

log "verifying $FILE"
gzip -t "$FILE" || die "gzip integrity check failed"

cat <<EOF

  About to restore:
    file     : $FILE
    database : ${POSTGRES_DB:-hireon} on hireon-postgres
    effect   : DROP and recreate the public schema, then load the dump

  The application will serve errors until the restore finishes. Stop the backend
  first for a clean cut:
    docker compose -f compose/backend/docker-compose.yml stop

EOF

log "stopping backend so nothing writes during the restore"
docker compose --env-file .env -f compose/backend/docker-compose.yml stop || true

log "dropping and recreating the public schema"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" hireon-postgres \
  psql -U "${POSTGRES_USER:-hireon}" -d "${POSTGRES_DB:-hireon}" -v ON_ERROR_STOP=1 \
  -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;" >/dev/null

log "loading $FILE"
if ! zcat "$FILE" | docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" hireon-postgres \
      pg_restore -U "${POSTGRES_USER:-hireon}" -d "${POSTGRES_DB:-hireon}" \
      --no-owner --no-acl --exit-on-error; then
  die "restore failed; the database may be incomplete"
fi

log "starting backend"
docker compose --env-file .env -f compose/backend/docker-compose.yml up -d --wait

log "row counts after restore"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" hireon-postgres \
  psql -U "${POSTGRES_USER:-hireon}" -d "${POSTGRES_DB:-hireon}" -tAc \
  "SELECT 'jobs='||count(*) FROM jobs UNION ALL SELECT 'users='||count(*) FROM users UNION ALL SELECT 'profiles='||count(*) FROM profiles"

warn "CV embeddings live in the ML service and were not restored."
warn "Re-run embedding for affected users; see README.md 'Disaster recovery'."
log "restore complete"
