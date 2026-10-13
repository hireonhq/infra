#!/usr/bin/env bash
#
# Deploy or roll back the HireOn stack.
#
# Deployment is a deliberate, manual action rather than an automatic pull: on a
# single VPS you want to watch a rollout and be able to reverse it in one command.
#
#   ./scripts/deploy.sh                 deploy the pinned tags from .env
#   ./scripts/deploy.sh --tag <sha>     deploy a specific image tag for both services
#   ./scripts/deploy.sh --backend <sha> --frontend <sha>
#   ./scripts/deploy.sh --rollback      re-deploy the previously running tags
#   ./scripts/deploy.sh --dry-run       show what would happen
#   ./scripts/deploy.sh --env dev       deploy the development stack
#
# --env dev switches to .env.dev, the `hireon-dev` compose project and
# compose/dev.yml, so dev and prod share a host without sharing container names,
# volumes or a database.
#
# The script never touches the database. Schema changes come from the backend's
# migrations, which run on startup and are additive by convention.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BACKEND_TAG=""
FRONTEND_TAG=""
BACKEND_TAG_CLI=""
FRONTEND_TAG_CLI=""
ROLLBACK=0
DRY_RUN=0
ENVIRONMENT="prod"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)      BACKEND_TAG_CLI="$2"; FRONTEND_TAG_CLI="$2"; shift 2 ;;
    --backend)  BACKEND_TAG_CLI="$2"; shift 2 ;;
    --frontend) FRONTEND_TAG_CLI="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --env)      ENVIRONMENT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

case "$ENVIRONMENT" in
  prod)
    ENV_FILE="$REPO_ROOT/.env"
    PROJECT="hireon"
    COMPOSE_FILES=(-f compose/docker-compose.yml)
    STATE_FILE="$REPO_ROOT/.deploy-state"
    BACKEND_CONTAINER="hireon-backend"
    FRONTEND_CONTAINER="hireon-frontend"
    SMOKE_URL="${SMOKE_URL:-https://hireon.evanhfw.my.id/healthz}"
    TAKE_BACKUP=1
    ;;
  dev)
    ENV_FILE="$REPO_ROOT/.env.dev"
    PROJECT="hireon-dev"
    COMPOSE_FILES=(-f compose/docker-compose.yml -f compose/dev.yml)
    STATE_FILE="$REPO_ROOT/.deploy-state.dev"
    BACKEND_CONTAINER="hireon-dev-backend"
    FRONTEND_CONTAINER="hireon-dev-frontend"
    SMOKE_URL="${SMOKE_URL:-https://hireon-dev.evanhfw.my.id/healthz}"
    # The dev database is disposable and the host disk is the scarce resource.
    TAKE_BACKUP=0
    ;;
  *) die "unknown --env: $ENVIRONMENT (expected prod or dev)" ;;
esac

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found (copy .env.example and fill it in)"
# shellcheck disable=SC1091
set -a; source "$ENV_FILE"; set +a

# CLI flags beat the pins in the env file: the file is sourced after argv is
# parsed, so without this --tag was silently ignored whenever .env pinned a tag.
[[ -n "$BACKEND_TAG_CLI" ]]  && BACKEND_TAG="$BACKEND_TAG_CLI"
[[ -n "$FRONTEND_TAG_CLI" ]] && FRONTEND_TAG="$FRONTEND_TAG_CLI"

if [[ $ROLLBACK -eq 1 ]]; then
  [[ -f "$STATE_FILE" ]] || die "no $STATE_FILE to roll back to"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  BACKEND_TAG="${PREV_BACKEND_TAG:-latest}"
  FRONTEND_TAG="${PREV_FRONTEND_TAG:-latest}"
  log "rolling back to backend=$BACKEND_TAG frontend=$FRONTEND_TAG"
fi

BACKEND_TAG="${BACKEND_TAG:-${BACKEND_TAG_PIN:-latest}}"
FRONTEND_TAG="${FRONTEND_TAG:-${FRONTEND_TAG_PIN:-latest}}"

# Must be exported: compose interpolates ${BACKEND_TAG:-latest} from the process
# env, so an unexported shell var silently deploys :latest.
export BACKEND_TAG FRONTEND_TAG

# -p keeps the two environments in separate compose projects; -f is the base file
# plus (for dev) the override that renames containers and the volume. The old
# version pointed at compose/<service>/docker-compose.yml, a layout that no longer
# exists -- every deploy failed with "no such file".
compose() {
  docker compose -p "$PROJECT" --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" "$@"
}

# Capture the currently running tags so --rollback has somewhere to go.
if [[ $ROLLBACK -eq 0 ]]; then
  CURRENT_BACKEND="$(docker inspect "$BACKEND_CONTAINER" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo latest)"
  CURRENT_FRONTEND="$(docker inspect "$FRONTEND_CONTAINER" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo latest)"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "would deploy env=$ENVIRONMENT backend=$BACKEND_TAG frontend=$FRONTEND_TAG"
  exit 0
fi

# 1. Database first: the backend waits for it to be healthy, and migrations must
#    run before the new API revision serves traffic.
log "starting postgres"
compose up -d --wait postgres

# 2. Take a backup before any schema change. Cheap, and the only thing standing
#    between a bad migration and data loss.
if [[ $TAKE_BACKUP -eq 1 ]]; then
  log "backing up before deploy"
  if ! ./scripts/backup.sh; then
    warn "backup failed; refusing to continue"
    die "deploy aborted"
  fi
else
  log "skipping backup (env=$ENVIRONMENT)"
fi

# 3. Backend, which applies migrations on startup. If migrations fail the container
#    exits and `up --wait` reports it, so a broken schema never reaches the frontend.
log "deploying backend ($BACKEND_TAG)"
BACKEND_TAG="$BACKEND_TAG" compose up -d --wait backend

log "verifying backend health"
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$BACKEND_CONTAINER"):8080/healthz" >/dev/null 2>&1; then
    break
  fi
  [[ $i -eq 30 ]] && { compose logs --tail 40 backend; die "backend did not become healthy"; }
  sleep 2
done

# 4. Frontend last: it proxies to the backend, so it should only start once the
#    API answers.
log "deploying frontend ($FRONTEND_TAG)"
FRONTEND_TAG="$FRONTEND_TAG" compose up -d --wait frontend

# 5. Public smoke test through Caddy, which is the path a user takes.
log "smoke testing $SMOKE_URL"
for i in $(seq 1 20); do
  if curl -fsS --max-time 5 "$SMOKE_URL" >/dev/null 2>&1; then
    log "public health check passed"
    break
  fi
  [[ $i -eq 20 ]] && { warn "public health check did not pass; the site may still be serving the previous version"; }
  sleep 3
done

if [[ $ROLLBACK -eq 0 ]]; then
  cat > "$STATE_FILE" <<EOF
# Written by scripts/deploy.sh -- source of truth for --rollback. Not a secret.
PREV_BACKEND_TAG=$CURRENT_BACKEND
PREV_FRONTEND_TAG=$CURRENT_FRONTEND
DEPLOYED_BACKEND_TAG=$BACKEND_TAG
DEPLOYED_FRONTEND_TAG=$FRONTEND_TAG
DEPLOYED_AT=$(date -Iseconds)
EOF
fi

log "done: env=$ENVIRONMENT backend=$BACKEND_TAG frontend=$FRONTEND_TAG"
if [[ "$ENVIRONMENT" == "dev" ]]; then
  log "roll back with: ./scripts/deploy.sh --env dev --rollback"
else
  log "roll back with: ./scripts/deploy.sh --rollback"
fi
