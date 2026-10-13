#!/usr/bin/env bash
#
# Dump the HireOn database and prune old backups.
#
# There was no backup at all before this: a dropped volume or a bad migration meant
# permanent data loss. Run it from cron, and always before a deploy.
#
#   ./scripts/backup.sh              write a dump and prune old ones
#   ./scripts/backup.sh --list       list existing backups
#   ./scripts/backup.sh --verify F   verify a dump is readable
#
# Dumps are compressed and written with restrictive permissions because they contain
# user emails, CV URLs and profile data.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--list" ]]; then
  [[ -d "$BACKUP_DIR" ]] || { echo "no backups yet"; exit 0; }
  ls -lh "$BACKUP_DIR"/*.dump.gz 2>/dev/null || echo "no backups yet"
  exit 0
fi

if [[ "${1:-}" == "--verify" ]]; then
  file="${2:?usage: backup.sh --verify <file>}"
  [[ -f "$file" ]] || die "not found: $file"
  # Read the archive listing only; this catches a truncated or corrupt dump.
  gzip -t "$file" || die "gzip integrity check failed: $file"
  if zcat "$file" | pg_restore --list >/dev/null 2>&1; then
    log "ok: $file"
  else
    die "pg_restore could not read $file"
  fi
  exit 0
fi

[[ -f .env ]] || die ".env not found in $REPO_ROOT"
# shellcheck disable=SC1091
set -a; source .env; set +a

# Back up through the running container so no local psql client is needed and the
# server version always matches.
docker inspect hireon-postgres >/dev/null 2>&1 || die "hireon-postgres is not running"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

stamp="$(date +%Y%m%d-%H%M%S)"
out="$BACKUP_DIR/hireon-$stamp.dump.gz"
tmp="$out.partial"

log "dumping ${POSTGRES_DB:-hireon} to $out"
# -Fc allows selective restore; --no-owner keeps the dump portable.
if ! docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" hireon-postgres \
      pg_dump -U "${POSTGRES_USER:-hireon}" -d "${POSTGRES_DB:-hireon}" \
      --format=custom --no-owner --no-acl \
    | gzip -9 > "$tmp"; then
  rm -f "$tmp"
  die "pg_dump failed"
fi

# Only publish a dump that is complete: a partial file must never look valid.
if ! gzip -t "$tmp" 2>/dev/null; then
  rm -f "$tmp"
  die "the dump is corrupt"
fi
mv "$tmp" "$out"
chmod 600 "$out"
log "wrote $(du -h "$out" | cut -f1)"

log "pruning backups older than $RETENTION_DAYS days"
find "$BACKUP_DIR" -name 'hireon-*.dump.gz' -type f -mtime "+$RETENTION_DAYS" -print -delete || true

count="$(find "$BACKUP_DIR" -name 'hireon-*.dump.gz' -type f | wc -l)"
log "done: $count backup(s) retained"
