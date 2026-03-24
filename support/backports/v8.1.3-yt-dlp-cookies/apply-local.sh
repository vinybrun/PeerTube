#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

require_command awk
require_command grep
require_command node
require_command sha256sum

BASE_DIR="/var/www/peertube"
APP_DIR=""
CONFIG_DIR=""
BACKUP_ROOT=""
SKIP_RESTART=0

usage() {
  cat <<'EOF'
Usage: apply-local.sh [options]

Options:
  --base-dir PATH      Base PeerTube directory (default: /var/www/peertube)
  --app-dir PATH       Application directory (default: $BASE_DIR/peertube-latest)
  --config-dir PATH    Live config directory (default: $BASE_DIR/config)
  --backup-root PATH   Backup directory (default: $BASE_DIR/backups/<timestamp>)
  --yes                Skip interactive approvals
  --force              Ignore unexpected runtime file checksums
  --skip-restart       Do not offer a restart at the end
  --help               Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-dir)
      BASE_DIR="$2"
      shift 2
      ;;
    --app-dir)
      APP_DIR="$2"
      shift 2
      ;;
    --config-dir)
      CONFIG_DIR="$2"
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

APP_DIR="${APP_DIR:-$BASE_DIR/peertube-latest}"
CONFIG_DIR="${CONFIG_DIR:-$BASE_DIR/config}"
BACKUP_ROOT="${BACKUP_ROOT:-$BASE_DIR/backups/$BACKPORT_ID-$(timestamp_utc)}"

ensure_payload_layout

LOCAL_BASE_MANIFEST="$MANIFESTS_DIR/local-base.tsv"
LOCAL_PATCHED_MANIFEST="$MANIFESTS_DIR/local-patched.tsv"

[ -f "$APP_DIR/package.json" ] || die "Could not find $APP_DIR/package.json"
[ -f "$CONFIG_DIR/production.yaml" ] || die "Could not find $CONFIG_DIR/production.yaml"

installed_version="$(read_package_version "$APP_DIR/package.json")"
[ "$installed_version" = "$EXPECTED_VERSION" ] || die "Expected PeerTube $EXPECTED_VERSION but found $installed_version"

mkdir -p "$BACKUP_ROOT"

LOCAL_APP_TARGETS=(
  "dist/server.js"
  "dist/server.js.map"
  "dist/core/helpers/youtube-dl/youtube-dl-cli.js"
  "dist/core/helpers/youtube-dl/youtube-dl-cli.js.map"
  "dist/core/initializers/config.js"
  "dist/core/initializers/config.js.map"
  "dist/core/initializers/checker-before-init.js"
  "dist/core/initializers/checker-before-init.js.map"
  "config/default.yaml"
  "config/production.yaml.example"
)

replace_target_from_payload() {
  local manifest_key="$1"
  local payload_path="$2"
  local target_path="$3"
  local backup_relative="$4"

  [ -f "$payload_path" ] || return 0

  local expected_base expected_patched actual_checksum
  expected_base="$(lookup_checksum "$LOCAL_BASE_MANIFEST" "$manifest_key")"
  expected_patched="$(lookup_checksum "$LOCAL_PATCHED_MANIFEST" "$manifest_key")"

  if [ -e "$target_path" ]; then
    actual_checksum="$(sha256_file "$target_path")"

    if [ -n "$expected_patched" ] && [ "$actual_checksum" = "$expected_patched" ]; then
      log "Already patched: $target_path"
      return 0
    fi

    if [ "$FORCE" -ne 1 ] && { [ -z "$expected_base" ] || [ "$actual_checksum" != "$expected_base" ]; }; then
      die "Unexpected checksum for $target_path. Use --force to overwrite it."
    fi
  elif [ "$FORCE" -ne 1 ]; then
    die "Target file is missing: $target_path. Use --force to create it."
  fi

  backup_file_if_exists "$target_path" "$BACKUP_ROOT" "$backup_relative"
  install_payload_file "$payload_path" "$target_path"
  log "Patched $target_path"
}

for relative_path in "${LOCAL_APP_TARGETS[@]}"; do
  replace_target_from_payload \
    "$relative_path" \
    "$PAYLOAD_DIR/local/$relative_path" \
    "$APP_DIR/$relative_path" \
    "app/$relative_path"
done

replace_target_from_payload \
  "config/default.yaml" \
  "$PAYLOAD_DIR/local/config/default.yaml" \
  "$CONFIG_DIR/default.yaml" \
  "config/default.yaml"

LOCAL_PRODUCTION="$CONFIG_DIR/production.yaml"
need_storage_import=0
need_cookies_block=0

if ! file_contains_key_in_storage_block "$LOCAL_PRODUCTION" "import"; then
  need_storage_import=1
fi

if ! file_contains_local_cookies_block "$LOCAL_PRODUCTION"; then
  need_cookies_block=1
fi

if [ "$need_storage_import" -eq 1 ] || [ "$need_cookies_block" -eq 1 ]; then
  sample_storage_path="$(extract_storage_sample_path "$LOCAL_PRODUCTION")"
  [ -n "$sample_storage_path" ] || die "Could not infer storage paths from $LOCAL_PRODUCTION"

  derived_import_path="$(relative_sibling_import_path "$sample_storage_path")"
  preview_block=""

  if [ "$need_storage_import" -eq 1 ]; then
    preview_block="  import: '$derived_import_path'"
  fi

  if [ "$need_cookies_block" -eq 1 ]; then
    if [ -n "$preview_block" ]; then
      preview_block+=$'\n\n'
    fi

    preview_block+=$'      cookies:\n        enabled: false'
  fi

  print_block "I want to apply this change to your live production.yaml:" "$preview_block"

  if confirm_or_exit "Do you approve?"; then
    backup_file_if_exists "$LOCAL_PRODUCTION" "$BACKUP_ROOT" "config/production.yaml"

    working_file="$LOCAL_PRODUCTION"
    temp_file="$(mktemp "/tmp/${BACKPORT_ID}.local.XXXXXX")"

    if [ "$need_storage_import" -eq 1 ]; then
      insert_before_first_match \
        "$working_file" \
        "$temp_file" \
        '^  plugins:' \
        "  import: '$derived_import_path'"
      mv "$temp_file" "$LOCAL_PRODUCTION"
      working_file="$LOCAL_PRODUCTION"
      temp_file="$(mktemp "/tmp/${BACKPORT_ID}.local.XXXXXX")"
    fi

    if [ "$need_cookies_block" -eq 1 ]; then
      insert_before_first_match \
        "$working_file" \
        "$temp_file" \
        '^    torrent:' \
        $'      cookies:\n        enabled: false\n'
      mv "$temp_file" "$LOCAL_PRODUCTION"
    else
      rm -f "$temp_file"
    fi

    log "Patched $LOCAL_PRODUCTION"
  else
    warn "Skipped changes to $LOCAL_PRODUCTION"
  fi
fi

log "Backups saved in $BACKUP_ROOT"

if [ "$SKIP_RESTART" -eq 0 ]; then
  if confirm_or_exit "I want to restart PeerTube now so the backport takes effect. Do you approve?"; then
    if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl show peertube --property LoadState --value 2>/dev/null || true)" != "not-found" ]; then
      if systemctl restart peertube; then
        log "Restarted peertube.service"
      else
        warn "Could not restart peertube.service automatically."
        log "Restart it manually when ready, for example: systemctl restart peertube"
      fi
    else
      log "Restart PeerTube manually when ready. Example: systemctl restart peertube"
    fi
  fi
fi
