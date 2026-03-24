#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

require_command git
require_command pnpm
require_command npm
require_command node
require_command docker
require_command sha256sum
require_command join

KEEP_WORK_ROOT="${KEEP_WORK_ROOT:-on-failure}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "/tmp/${BACKPORT_ID}.XXXXXX")}"
BASE_WORKTREE="$WORK_ROOT/base"
PATCHED_WORKTREE="$WORK_ROOT/patched"
BASE_IMAGE_TAG="peertube-${BACKPORT_ID}-base:latest"
PATCHED_IMAGE_TAG="peertube-${BACKPORT_ID}-patched:latest"

cleanup() {
  local exit_code=$?
  set +e

  docker image rm -f "$BASE_IMAGE_TAG" "$PATCHED_IMAGE_TAG" >/dev/null 2>&1 || true

  case "$KEEP_WORK_ROOT" in
    always)
      warn "Preserving temporary worktrees in $WORK_ROOT"
      return
      ;;
    on-failure)
      if [ "$exit_code" -ne 0 ]; then
        warn "Preserving temporary worktrees in $WORK_ROOT because the generator failed"
        return
      fi
      ;;
    never)
      ;;
    *)
      warn "Unknown KEEP_WORK_ROOT mode '$KEEP_WORK_ROOT'; defaulting to on-failure behavior"
      if [ "$exit_code" -ne 0 ]; then
        warn "Preserving temporary worktrees in $WORK_ROOT because the generator failed"
        return
      fi
      ;;
  esac

  git -C "$ROOT_DIR" worktree remove --force "$BASE_WORKTREE" >/dev/null 2>&1 || true
  git -C "$ROOT_DIR" worktree remove --force "$PATCHED_WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$WORK_ROOT"
}

trap cleanup EXIT

LOCAL_ALLOWED_CHANGED=(
  "config/default.yaml"
  "config/production.yaml.example"
  "dist/core/helpers/youtube-dl/youtube-dl-cli.js"
  "dist/core/helpers/youtube-dl/youtube-dl-cli.js.map"
  "dist/core/initializers/checker-before-init.js"
  "dist/core/initializers/checker-before-init.js.map"
  "dist/core/initializers/config.js"
  "dist/core/initializers/config.js.map"
  "dist/server.js"
  "dist/server.js.map"
)

DOCKER_ALLOWED_CHANGED=(
  "app/config/default.yaml"
  "app/dist/core/helpers/youtube-dl/youtube-dl-cli.js"
  "app/dist/core/helpers/youtube-dl/youtube-dl-cli.js.map"
  "app/dist/core/initializers/checker-before-init.js"
  "app/dist/core/initializers/checker-before-init.js.map"
  "app/dist/core/initializers/config.js"
  "app/dist/core/initializers/config.js.map"
  "app/dist/server.js"
  "app/dist/server.js.map"
  "app/support/docker/production/config/custom-environment-variables.yaml"
  "app/support/docker/production/config/production.yaml"
)

LOCAL_PAYLOAD_FILES=(
  "config/default.yaml"
  "config/production.yaml.example"
  "dist/core/helpers/youtube-dl/youtube-dl-cli.js"
  "dist/core/helpers/youtube-dl/youtube-dl-cli.js.map"
  "dist/core/initializers/checker-before-init.js"
  "dist/core/initializers/checker-before-init.js.map"
  "dist/core/initializers/config.js"
  "dist/core/initializers/config.js.map"
  "dist/server.js"
  "dist/server.js.map"
)

DOCKER_PAYLOAD_FILES=(
  "app/config/default.yaml"
  "app/dist/core/helpers/youtube-dl/youtube-dl-cli.js"
  "app/dist/core/helpers/youtube-dl/youtube-dl-cli.js.map"
  "app/dist/core/initializers/checker-before-init.js"
  "app/dist/core/initializers/checker-before-init.js.map"
  "app/dist/core/initializers/config.js"
  "app/dist/core/initializers/config.js.map"
  "app/dist/server.js"
  "app/dist/server.js.map"
  "app/support/docker/production/config/custom-environment-variables.yaml"
  "app/support/docker/production/config/production.yaml"
)

prepare_release_tree() {
  local worktree="$1"

  (
    cd "$worktree"
    pnpm install --frozen-lockfile
    CI=1 npm run build -- --source-map
    rm -f "./client/dist/en-US/stats.json" "./client/dist/embed-stats.json"
    find dist/ packages/core-utils/dist/ \
      packages/ffmpeg/dist/ \
      packages/node-utils/dist/ \
      packages/models/dist/ \
      \( -name '*.d.ts' -o -name '*.d.ts.map' -o -name '.tsbuildinfo' \) -type f -delete
  )
}

write_manifest() {
  local source_root="$1"
  shift

  local output_file="$1"
  shift

  : > "$output_file"

  local relative_path
  for relative_path in "$@"; do
    [ -f "$source_root/$relative_path" ] || continue
    printf '%s\t%s\n' "$relative_path" "$(sha256_file "$source_root/$relative_path")" >> "$output_file"
  done

  sort -o "$output_file" "$output_file"
}

write_changed_paths_report() {
  local base_manifest="$1"
  local patched_manifest="$2"
  local output_file="$3"

  join -t $'\t' -a 1 -a 2 -e MISSING -o '0,1.2,2.2' "$base_manifest" "$patched_manifest" \
    | awk -F '\t' '$2 != $3 { print $1 }' > "$output_file"
}

assert_allowed_changed_paths() {
  local report_file="$1"
  shift

  local expected_file
  expected_file="$(mktemp "/tmp/${BACKPORT_ID}.expected.XXXXXX")"
  trap 'rm -f "$expected_file"' RETURN

  printf '%s\n' "$@" | sort > "$expected_file"

  if ! diff -u "$expected_file" "$report_file" >/dev/null; then
    diff -u "$expected_file" "$report_file" || true
    die "Changed file set does not match the expected backport payload."
  fi

  rm -f "$expected_file"
  trap - RETURN
}

copy_payload_files() {
  local source_root="$1"
  local destination_root="$2"
  shift 2

  rm -rf "$destination_root"
  mkdir -p "$destination_root"

  local relative_path
  for relative_path in "$@"; do
    [ -f "$source_root/$relative_path" ] || continue
    mkdir -p "$destination_root/$(dirname "$relative_path")"
    install -m 0644 "$source_root/$relative_path" "$destination_root/$relative_path"
  done
}

extract_docker_tree() {
  local image_tag="$1"
  local destination_root="$2"
  shift 2

  local container_id
  container_id="$(docker create "$image_tag" sh -c 'sleep 1')"

  mkdir -p "$destination_root"

  local relative_path
  for relative_path in "$@"; do
    mkdir -p "$destination_root/$(dirname "$relative_path")"
    docker cp "$container_id:/$relative_path" "$destination_root/$relative_path"
  done

  docker rm -f "$container_id" >/dev/null
}

log "Creating temporary worktrees in $WORK_ROOT"
git -C "$ROOT_DIR" worktree add --detach "$BASE_WORKTREE" "$BASE_REF" >/dev/null
git -C "$ROOT_DIR" worktree add --detach "$PATCHED_WORKTREE" "$BASE_REF" >/dev/null
git -C "$PATCHED_WORKTREE" cherry-pick "$PATCH_COMMIT" >/dev/null

log "Building local release-style trees"
prepare_release_tree "$BASE_WORKTREE"
prepare_release_tree "$PATCHED_WORKTREE"

rm -rf "$PAYLOAD_DIR" "$MANIFESTS_DIR" "$DIFFS_DIR"
mkdir -p "$MANIFESTS_DIR" "$DIFFS_DIR"

FULL_LOCAL_BASE_MANIFEST="$WORK_ROOT/full-local-base.tsv"
FULL_LOCAL_PATCHED_MANIFEST="$WORK_ROOT/full-local-patched.tsv"
LOCAL_CHANGED_REPORT="$DIFFS_DIR/local.changed-files.txt"
LOCAL_BASE_EXTRACT="$WORK_ROOT/local-base"
LOCAL_PATCHED_EXTRACT="$WORK_ROOT/local-patched"

mapfile -t FULL_LOCAL_FILES < <(
  cd "$BASE_WORKTREE" && find dist -type f | sort
)
FULL_LOCAL_FILES+=("config/default.yaml" "config/production.yaml.example")

write_manifest "$BASE_WORKTREE" "$FULL_LOCAL_BASE_MANIFEST" "${FULL_LOCAL_FILES[@]}"
write_manifest "$PATCHED_WORKTREE" "$FULL_LOCAL_PATCHED_MANIFEST" "${FULL_LOCAL_FILES[@]}"
write_changed_paths_report "$FULL_LOCAL_BASE_MANIFEST" "$FULL_LOCAL_PATCHED_MANIFEST" "$LOCAL_CHANGED_REPORT"
assert_allowed_changed_paths "$LOCAL_CHANGED_REPORT" "${LOCAL_ALLOWED_CHANGED[@]}"

copy_payload_files "$BASE_WORKTREE" "$LOCAL_BASE_EXTRACT" "${LOCAL_PAYLOAD_FILES[@]}"
copy_payload_files "$PATCHED_WORKTREE" "$LOCAL_PATCHED_EXTRACT" "${LOCAL_PAYLOAD_FILES[@]}"
copy_payload_files "$PATCHED_WORKTREE" "$PAYLOAD_DIR/local" "${LOCAL_PAYLOAD_FILES[@]}"
write_manifest "$BASE_WORKTREE" "$MANIFESTS_DIR/local-base.tsv" "${LOCAL_PAYLOAD_FILES[@]}"
write_manifest "$PATCHED_WORKTREE" "$MANIFESTS_DIR/local-patched.tsv" "${LOCAL_PAYLOAD_FILES[@]}"
diff -ruN "$LOCAL_BASE_EXTRACT" "$LOCAL_PATCHED_EXTRACT" > "$DIFFS_DIR/local.diff" || [ "$?" -eq 1 ]

log "Building Docker production images"
docker build -f "$BASE_WORKTREE/support/docker/production/Dockerfile" --build-arg ALREADY_BUILT=1 -t "$BASE_IMAGE_TAG" "$BASE_WORKTREE" >/dev/null
docker build -f "$PATCHED_WORKTREE/support/docker/production/Dockerfile" --build-arg ALREADY_BUILT=1 -t "$PATCHED_IMAGE_TAG" "$PATCHED_WORKTREE" >/dev/null

DOCKER_BASE_EXTRACT="$WORK_ROOT/docker-base"
DOCKER_PATCHED_EXTRACT="$WORK_ROOT/docker-patched"
extract_docker_tree "$BASE_IMAGE_TAG" "$DOCKER_BASE_EXTRACT" "${DOCKER_PAYLOAD_FILES[@]}"
extract_docker_tree "$PATCHED_IMAGE_TAG" "$DOCKER_PATCHED_EXTRACT" "${DOCKER_PAYLOAD_FILES[@]}"

FULL_DOCKER_BASE_MANIFEST="$WORK_ROOT/full-docker-base.tsv"
FULL_DOCKER_PATCHED_MANIFEST="$WORK_ROOT/full-docker-patched.tsv"
DOCKER_CHANGED_REPORT="$DIFFS_DIR/docker.changed-files.txt"

write_manifest "$DOCKER_BASE_EXTRACT" "$FULL_DOCKER_BASE_MANIFEST" "${DOCKER_PAYLOAD_FILES[@]}"
write_manifest "$DOCKER_PATCHED_EXTRACT" "$FULL_DOCKER_PATCHED_MANIFEST" "${DOCKER_PAYLOAD_FILES[@]}"
write_changed_paths_report "$FULL_DOCKER_BASE_MANIFEST" "$FULL_DOCKER_PATCHED_MANIFEST" "$DOCKER_CHANGED_REPORT"
assert_allowed_changed_paths "$DOCKER_CHANGED_REPORT" "${DOCKER_ALLOWED_CHANGED[@]}"

copy_payload_files "$DOCKER_PATCHED_EXTRACT" "$PAYLOAD_DIR/docker" "${DOCKER_PAYLOAD_FILES[@]}"
write_manifest "$DOCKER_BASE_EXTRACT" "$MANIFESTS_DIR/docker-base.tsv" "${DOCKER_PAYLOAD_FILES[@]}"
write_manifest "$DOCKER_PATCHED_EXTRACT" "$MANIFESTS_DIR/docker-patched.tsv" "${DOCKER_PAYLOAD_FILES[@]}"
diff -ruN "$DOCKER_BASE_EXTRACT" "$DOCKER_PATCHED_EXTRACT" > "$DIFFS_DIR/docker.diff" || [ "$?" -eq 1 ]

log "Backport payload refreshed in $SCRIPT_DIR"
