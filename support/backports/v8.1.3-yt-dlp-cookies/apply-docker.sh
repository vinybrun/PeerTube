#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

require_command docker
require_command grep
require_command awk
require_command sha256sum

COMPOSE_DIR="$(pwd)"
SERVICE_NAME="peertube"
CONTAINER_ID=""
BACKUP_ROOT=""
SKIP_RESTART=0

usage() {
  cat <<'EOF'
Usage: apply-docker.sh [options]

Options:
  --compose-dir PATH   Docker compose project directory (default: current directory)
  --service NAME       Service name to restart/detect (default: peertube)
  --container ID       Explicit container id/name to patch
  --backup-root PATH   Backup directory (default: <compose-dir>/backups/<timestamp>)
  --yes                Skip interactive approvals
  --force              Ignore unexpected runtime file checksums
  --skip-restart       Do not offer a restart at the end
  --help               Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --compose-dir)
      COMPOSE_DIR="$2"
      shift 2
      ;;
    --service)
      SERVICE_NAME="$2"
      shift 2
      ;;
    --container)
      CONTAINER_ID="$2"
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --yes)
      YES=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --skip-restart)
      SKIP_RESTART=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

ensure_payload_layout

BACKUP_ROOT="${BACKUP_ROOT:-$COMPOSE_DIR/backups/$BACKPORT_ID-$(timestamp_utc)}"
mkdir -p "$BACKUP_ROOT"

compose_config_present=0
if [ -f "$COMPOSE_DIR/docker-compose.yml" ] || [ -f "$COMPOSE_DIR/compose.yml" ] || [ -f "$COMPOSE_DIR/compose.yaml" ]; then
  compose_config_present=1
fi

DOCKER_BASE_MANIFEST="$MANIFESTS_DIR/docker-base.tsv"
DOCKER_PATCHED_MANIFEST="$MANIFESTS_DIR/docker-patched.tsv"

if [ -z "$CONTAINER_ID" ]; then
  detect_compose_command || die "Could not find docker compose or docker-compose"

  (
    cd "$COMPOSE_DIR"
    CONTAINER_ID="$("${COMPOSE_CMD[@]}" ps -q "$SERVICE_NAME" || true)"
    printf '%s' "$CONTAINER_ID" > "$BACKUP_ROOT/.container-id"
  )

  CONTAINER_ID="$(cat "$BACKUP_ROOT/.container-id")"
  rm -f "$BACKUP_ROOT/.container-id"
fi

[ -n "$CONTAINER_ID" ] || die "Could not detect a running container for service $SERVICE_NAME"

docker inspect "$CONTAINER_ID" >/dev/null 2>&1 || die "Container not found: $CONTAINER_ID"

container_version="$(docker exec "$CONTAINER_ID" node -p "JSON.parse(require('fs').readFileSync('/app/package.json', 'utf8')).version")"
[ "$container_version" = "$EXPECTED_VERSION" ] || die "Expected PeerTube $EXPECTED_VERSION in the container but found $container_version"
APP_OWNER="$(docker exec -u 0 "$CONTAINER_ID" sh -c "printf '%s:%s' \"\$(id -u peertube)\" \"\$(id -g peertube)\"")"

DOCKER_RUNTIME_TARGETS=(
  "app/config/default.yaml"
  "app/dist/server.js"
  "app/dist/server.js.map"
  "app/dist/core/helpers/youtube-dl/youtube-dl-cli.js"
  "app/dist/core/helpers/youtube-dl/youtube-dl-cli.js.map"
  "app/dist/core/initializers/config.js"
  "app/dist/core/initializers/config.js.map"
  "app/dist/core/initializers/checker-before-init.js"
  "app/dist/core/initializers/checker-before-init.js.map"
  "app/support/docker/production/config/production.yaml"
  "app/support/docker/production/config/custom-environment-variables.yaml"
)

container_file_sha() {
  local container_path="$1"
  docker exec "$CONTAINER_ID" sh -c "sha256sum '$container_path' | awk '{ print \$1 }'"
}

container_file_owner() {
  local container_path="$1"
  docker exec -u 0 "$CONTAINER_ID" sh -c "stat -c '%u:%g' '$container_path'"
}

ensure_container_file_owner() {
  local container_path="$1"
  local current_owner

  current_owner="$(container_file_owner "$container_path")"

  if [ "$current_owner" != "$APP_OWNER" ]; then
    docker exec -u 0 "$CONTAINER_ID" chown "$APP_OWNER" "$container_path"
    log "Fixed container ownership for $container_path to $APP_OWNER"
  fi
}

replace_container_file_from_payload() {
  local manifest_key="$1"
  local payload_path="$2"
  local container_path="/$3"
  local backup_relative="$4"

  [ -f "$payload_path" ] || return 0

  local expected_base expected_patched actual_checksum
  expected_base="$(lookup_checksum "$DOCKER_BASE_MANIFEST" "$manifest_key")"
  expected_patched="$(lookup_checksum "$DOCKER_PATCHED_MANIFEST" "$manifest_key")"

  if docker exec "$CONTAINER_ID" test -f "$container_path"; then
    actual_checksum="$(container_file_sha "$container_path")"

    if [ -n "$expected_patched" ] && [ "$actual_checksum" = "$expected_patched" ]; then
      ensure_container_file_owner "$container_path"
      log "Already patched in container: $container_path"
      return 0
    fi

    if [ "$FORCE" -ne 1 ] && { [ -z "$expected_base" ] || [ "$actual_checksum" != "$expected_base" ]; }; then
      die "Unexpected checksum for $container_path. Use --force to overwrite it."
    fi
  elif [ "$FORCE" -ne 1 ]; then
    die "Missing container file: $container_path. Use --force to create it."
  fi

  if docker exec "$CONTAINER_ID" test -f "$container_path"; then
    mkdir -p "$BACKUP_ROOT/$(dirname "$backup_relative")"
    docker cp "$CONTAINER_ID:$container_path" "$BACKUP_ROOT/$backup_relative"
  fi

  docker cp "$payload_path" "$CONTAINER_ID:$container_path"
  ensure_container_file_owner "$container_path"
  log "Patched container file $container_path"
}

for relative_path in "${DOCKER_RUNTIME_TARGETS[@]}"; do
  replace_container_file_from_payload \
    "$relative_path" \
    "$PAYLOAD_DIR/docker/$relative_path" \
    "$relative_path" \
    "container/$relative_path"
done

HOST_CONFIG_DIR="$COMPOSE_DIR/docker-volume/config"
HOST_PRODUCTION="$HOST_CONFIG_DIR/production.yaml"
HOST_LOCAL_PRODUCTION="$HOST_CONFIG_DIR/local-production.json"
HOST_ENV="$COMPOSE_DIR/.env"

[ -f "$HOST_ENV" ] || die "Could not find $HOST_ENV"

if [ -f "$HOST_LOCAL_PRODUCTION" ]; then
  log "Detected $HOST_LOCAL_PRODUCTION. The Docker backport will rely on .env overrides instead of editing UI-managed JSON config."
elif [ -f "$HOST_PRODUCTION" ]; then
  log "Detected $HOST_PRODUCTION. The Docker backport will rely on .env overrides instead of editing host production.yaml."
fi

DOCKER_ENV_LINES=(
  "# Ensure yt-dlp cookies use the persistent Docker data volume"
  "PEERTUBE_STORAGE_IMPORT=/data/import/"
  "# yt-dlp / HTTP video import configuration"
  "#PEERTUBE_IMPORT_VIDEOS_HTTP=true"
  "#PEERTUBE_IMPORT_VIDEOS_HTTP_YOUTUBE_DL_RELEASE_URL=https://api.github.com/repos/yt-dlp/yt-dlp/releases"
  "#PEERTUBE_IMPORT_VIDEOS_HTTP_YOUTUBE_DL_RELEASE_NAME=yt-dlp"
  "#PEERTUBE_IMPORT_VIDEOS_HTTP_FORCE_IPV4=true"
  "# JSON array. Example: [\"http://user:pass@proxy:3128\"]"
  "#PEERTUBE_IMPORT_VIDEOS_HTTP_PROXIES=[]"
  "# Paste your Netscape-format cookies in /data/import/cookies.txt, then enable this to pass them to yt-dlp."
  "#PEERTUBE_IMPORT_VIDEOS_HTTP_COOKIES_ENABLED=false"
)

env_key_exists() {
  local env_file="$1"
  local key_name="$2"

  grep -Eq "^[[:space:]]*#?[[:space:]]*${key_name}=" "$env_file"
}

env_line_exists() {
  local env_file="$1"
  local line="$2"

  grep -Fqx "$line" "$env_file"
}

missing_env_block=""

for line in "${DOCKER_ENV_LINES[@]}"; do
  if [[ "$line" =~ ^#(PEERTUBE_[A-Z0-9_]+)= ]]; then
    env_key="${BASH_REMATCH[1]}"
    if env_key_exists "$HOST_ENV" "$env_key"; then
      continue
    fi
  elif env_line_exists "$HOST_ENV" "$line"; then
    continue
  fi

  if [ -n "$missing_env_block" ]; then
    missing_env_block+=$'\n'
  fi

  missing_env_block+="$line"
done

if [ -n "$missing_env_block" ]; then
  print_block "I want to apply this change to your live .env:" "$missing_env_block"

  if confirm_or_exit "Do you approve?"; then
    backup_file_if_exists "$HOST_ENV" "$BACKUP_ROOT" "host/.env"
    printf '\n%s\n' "$missing_env_block" >> "$HOST_ENV"
    log "Patched $HOST_ENV"
  else
    warn "Skipped changes to $HOST_ENV"
  fi
fi

log "Backups saved in $BACKUP_ROOT"

if [ "$SKIP_RESTART" -eq 0 ]; then
  if confirm_or_exit "I want to restart the Docker PeerTube service now so the backport takes effect. Do you approve?"; then
    if detect_compose_command && [ "$compose_config_present" -eq 1 ]; then
      if (cd "$COMPOSE_DIR" && "${COMPOSE_CMD[@]}" restart "$SERVICE_NAME"); then
        log "Restarted Docker service $SERVICE_NAME"
      else
        warn "Could not restart $SERVICE_NAME with docker compose."
        log "Restart it manually when ready."
      fi
    else
      if docker restart "$CONTAINER_ID" >/dev/null; then
        log "Restarted container $CONTAINER_ID"
      else
        warn "Could not restart container $CONTAINER_ID automatically."
        log "Restart it manually when ready."
      fi
    fi
  fi
fi
