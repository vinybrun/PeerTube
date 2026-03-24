#!/usr/bin/env bash

set -euo pipefail

BACKPORT_ID="v8.1.3-yt-dlp-cookies"
EXPECTED_VERSION="8.1.3"
BASE_REF="v8.1.3"
PATCH_COMMIT="35e7afbe68b175ec8e75694d51878b070043b3cb"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$SCRIPT_DIR/payload"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
DIFFS_DIR="$SCRIPT_DIR/diffs"

YES="${YES:-0}"
FORCE="${FORCE:-0}"

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name"
}

timestamp_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

sha256_file() {
  sha256sum "$1" | awk '{ print $1 }'
}

lookup_checksum() {
  local manifest="$1"
  local relative_path="$2"

  awk -F '\t' -v relative_path="$relative_path" '$1 == relative_path { print $2 }' "$manifest"
}

ensure_payload_layout() {
  [ -d "$PAYLOAD_DIR" ] || die "Payload directory not found: $PAYLOAD_DIR"
  [ -d "$MANIFESTS_DIR" ] || die "Manifest directory not found: $MANIFESTS_DIR"
}

backup_file_if_exists() {
  local target="$1"
  local backup_root="$2"
  local backup_relative="$3"

  [ -e "$target" ] || return 0

  mkdir -p "$backup_root/$(dirname "$backup_relative")"
  cp -a "$target" "$backup_root/$backup_relative"
}

install_payload_file() {
  local source="$1"
  local target="$2"

  mkdir -p "$(dirname "$target")"
  install -m 0644 "$source" "$target"
}

confirm_or_exit() {
  local prompt="$1"

  if [ "$YES" -eq 1 ]; then
    return 0
  fi

  printf '%s [y/N] ' "$prompt"
  read -r reply || true

  case "$reply" in
    y|Y|yes|YES|Yes)
      return 0
      ;;
  esac

  return 1
}

print_block() {
  local heading="$1"
  local block="$2"

  printf '%s\n' "$heading"
  printf '%s\n' "$block"
}

read_package_version() {
  local package_json="$1"

  node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).version" "$package_json"
}

relative_sibling_import_path() {
  local sample_path="$1"
  local trimmed="${sample_path%/}"
  local parent="${trimmed%/*}"

  printf '%s/import/\n' "$parent"
}

extract_storage_sample_path() {
  local config_file="$1"

  awk '
    /^storage:$/ { in_storage = 1; next }
    in_storage && /^[^[:space:]]/ { exit }
    in_storage && $0 ~ /^  (tmp|tmp_persistent|bin|avatars|web_videos|streaming_playlists|original_video_files|redundancy|logs|previews|thumbnails|storyboards|torrents|captions|cache|plugins|uploads|well_known|client_overrides): / {
      line = $0
      sub(/^[^:]+:[[:space:]]*/, "", line)
      gsub(/^["'\''"]|["'\''"]$/, "", line)
      print line
      exit
    }
  ' "$config_file"
}

file_contains_key_in_storage_block() {
  local config_file="$1"
  local key_name="$2"

  awk -v key_name="$key_name" '
    /^storage:$/ { in_storage = 1; next }
    in_storage && /^[^[:space:]]/ { in_storage = 0 }
    in_storage && $0 ~ ("^  " key_name ":") { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$config_file"
}

file_contains_local_cookies_block() {
  local config_file="$1"

  awk '
    /^import:$/ { in_import = 1; next }
    in_import && /^[^[:space:]]/ { in_import = 0; in_videos = 0; in_http = 0; in_cookies = 0 }

    in_import && /^  videos:$/ { in_videos = 1; next }
    in_videos && !/^    / { in_videos = 0; in_http = 0; in_cookies = 0 }

    in_videos && /^    http:$/ { in_http = 1; next }
    in_http && !/^      / { in_http = 0; in_cookies = 0 }

    in_http && /^      cookies:$/ { in_cookies = 1; next }
    in_cookies && !/^        / { in_cookies = 0 }
    in_cookies && /^        enabled:/ { found = 1 }

    END { exit found ? 0 : 1 }
  ' "$config_file"
}

insert_before_first_match() {
  local source_file="$1"
  local destination_file="$2"
  local pattern="$3"
  local block="$4"

  awk -v pattern="$pattern" -v block="$block" '
    BEGIN {
      line_count = split(block, block_lines, "\n")
    }

    !inserted && $0 ~ pattern {
      for (i = 1; i <= line_count; i++) print block_lines[i]
      inserted = 1
    }

    { print }

    END {
      if (!inserted) exit 42
    }
  ' "$source_file" > "$destination_file" || {
    local exit_code=$?
    if [ "$exit_code" -eq 42 ]; then
      die "Could not find insertion anchor matching: $pattern"
    fi

    exit "$exit_code"
  }
}

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi

  return 1
}
