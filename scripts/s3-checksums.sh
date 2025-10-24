#!/usr/bin/env bash
#
# s3-checksums.sh
#
# Goal
#   Ensure every object under "dist/" has a valid SHA1 stored at
#   ".checksums/<key>.sha1" in the same S3-compatible bucket.
#
# Design (9 steps)
#   1. List remote .sha1 files (checksums inventory)
#   2. Sync existing .sha1 files locally (skip already present)
#   3. List target artifacts (only .zip and .tar)
#   4. Classify artifacts vs checksums (valid, missing, empty, corrupt)
#   4b. Optional: detect orphaned files (checksums without artifacts, artifacts without checksums)
#   5. Create a single internal list of items to process
#   6. Present the plan to the user before any large downloads
#   7. Execute (download artifact, compute SHA1, upload .sha1)
#   8. Retry S3 operations up to 3 times with backoff
#   9. Preserve audit trail (keep temp directory)
#
# Requirements
#   - bash, awk, sed, wc, tr, grep, mktemp
#   - AWS CLI v2 (aws)
#   - shasum or openssl (for SHA1)
#
# Required env
#   S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_REGION, S3_ENDPOINT, S3_USE_PATH_STYLE_ENDPOINT
#
# Optional env
#   S3C_ROOTDIR        (default: "./temp") - can also be passed as first argument
#   S3C_PREFIX         (default: "dist/"; PREFIX is deprecated alias)
#   S3C_CHECK_ORPHANS  (default: "0"; when "1" enables orphan checks)
#   S3C_DEBUG          (default: "0"; when "1" compares first N local vs remote checksums and tests sync behavior)
#   S3C_DEBUG_LIMIT    (default: "30"; how many files to test when S3C_DEBUG=1)
#   S3C_DEBUG_RCLONE   (default: "1"; when "1" and rclone is available, debug also tests rclone checksum-sync decisions)
#   S3C_SYNC_MODE      (default: "mtime"; values: "size-only", "mtime", "mtime-exact" for AWS CLI fallback strategy)
#   S3C_USE_RCLONE     (default: "0"; when "1" uses rclone to fetch .sha1 files via rclone sync --checksum)
#   S3C_RCLONE_TRANSFERS (default: "8"; parallel file transfers when rclone is enabled)
#   S3C_RCLONE_CHECKERS  (default: "16"; parallel checks when rclone is enabled)
#   S3C_RCLONE_ARGS      (extra flags passed to rclone; e.g., "--fast-list")
#   DRY_RUN            (default: "0")
#

set -euo pipefail

# ---------- error handling
on_err() { 
  printf 'ERROR: Script failed at line %s\n' "$1" >&2
  exit 1
}
trap 'on_err $LINENO' ERR

# ---------- inputs
S3C_PREFIX=${S3C_PREFIX:-dist/}
DRY_RUN="${DRY_RUN:-0}"
S3C_CHECK_ORPHANS="${S3C_CHECK_ORPHANS:-0}"
S3C_DEBUG="${S3C_DEBUG:-0}"
S3C_DEBUG_LIMIT="${S3C_DEBUG_LIMIT:-30}"
S3C_DEBUG_RCLONE="${S3C_DEBUG_RCLONE:-1}"
S3C_SYNC_MODE="${S3C_SYNC_MODE:-mtime}"
S3C_USE_RCLONE="${S3C_USE_RCLONE:-0}"
S3C_RCLONE_TRANSFERS="${S3C_RCLONE_TRANSFERS:-8}"
S3C_RCLONE_CHECKERS="${S3C_RCLONE_CHECKERS:-16}"
S3C_RCLONE_ARGS="${S3C_RCLONE_ARGS:-}"
BATCH_SIZE="${BATCH_SIZE:-20}"
# shellcheck disable=SC2034
EMPTY_SHA1="da39a3ee5e6b4b0d3255bfef95601890afd80709"

# ---------- preflight checks
need() { 
  command -v "$1" >/dev/null 2>&1 || { 
    printf 'ERROR: Required command "%s" not found\n' "$1" >&2
    exit 1
  }
}

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_ACCESS_KEY_ID:?S3_ACCESS_KEY_ID is required}"
: "${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY is required}"
: "${S3_REGION:?S3_REGION is required}"
: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_USE_PATH_STYLE_ENDPOINT:?S3_USE_PATH_STYLE_ENDPOINT is required (true/false)}"

need aws

# ---------- anchor paths to the script directory (not the current cwd)
# SCRIPT_DIR = folder containing this script (e.g., <project>/scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT = parent of scripts (e.g., <project>)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- working dirs (absolute paths)
# Accept working directory as first parameter or use S3C_ROOTDIR env or default to ./temp
if [[ -n "${1:-}" ]]; then
  S3C_ROOTDIR="$1"
elif [[ -z "${S3C_ROOTDIR:-}" ]]; then
  S3C_ROOTDIR="$PROJECT_ROOT/temp"
fi
TMP_CHECKSUMS="$S3C_ROOTDIR/checksums"
TMP_DOWNLOADS="$S3C_ROOTDIR/downloads"
TMP_RESULTS="$S3C_ROOTDIR/results"
mkdir -p "$S3C_ROOTDIR" "$TMP_CHECKSUMS" "$TMP_DOWNLOADS" "$TMP_RESULTS"

# ---------- aws environment setup
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"
export AWS_REGION="$S3_REGION"
export AWS_EC2_METADATA_DISABLED=true

# shellcheck disable=SC2034
AWS_ENDPOINT_ARG1="--endpoint-url"
# shellcheck disable=SC2034
AWS_ENDPOINT_ARG2="$S3_ENDPOINT"

TMP_AWS_CONFIG=""
if [[ "${S3_USE_PATH_STYLE_ENDPOINT,,}" == "true" ]]; then
  TMP_AWS_CONFIG="$(mktemp)"
  cat > "$TMP_AWS_CONFIG" <<EOF
[default]
region = ${S3_REGION}
[default.s3]
addressing_style = path
EOF
  export AWS_CONFIG_FILE="$TMP_AWS_CONFIG"
fi

# ---------- cleanup handler
cleanup() {
  # Step 9: preserve audit trail — temp directory kept (only temporary AWS config removed)
  if [[ -n "${TMP_AWS_CONFIG:-}" && -f "$TMP_AWS_CONFIG" ]]; then
    rm -f "$TMP_AWS_CONFIG" || true
  fi
  # Note: S3C_ROOTDIR and its contents are intentionally NOT removed
}
trap cleanup EXIT INT TERM

# ---------- batch upload queue initialization
QUEUE_FILE="$S3C_ROOTDIR/upload_queue.txt"
: > "$QUEUE_FILE"

# ---------- source library functions
# shellcheck source=s3-checksums-lib.sh
if [[ -f "$SCRIPT_DIR/s3-checksums-lib.sh" ]]; then
  source "$SCRIPT_DIR/s3-checksums-lib.sh"
else
  printf 'ERROR: Library file s3-checksums-lib.sh not found\n' >&2
  exit 1
fi

# ---------- main orchestration
main() {
  log "========================================="
  log "S3 Checksum Generator"
  log "========================================="
  log "Bucket: $S3_BUCKET"
  log "Prefix: $S3C_PREFIX"
  log "Working directory: $S3C_ROOTDIR"
  [[ "$DRY_RUN" == "1" ]] && log "Mode: DRY RUN (no artifact downloads)"
  [[ "$S3C_DEBUG" == "1" ]] && log "Debug: S3C_DEBUG enabled (will compare first ${S3C_DEBUG_LIMIT} local vs remote checksums and test sync behavior)"
  log "========================================="

  # Step 1: Get remote checksum inventory and sync locally
  local remote_checksums
  remote_checksums="$(build_checksums_inventory)"
  log "Remote checksums found: $(wc -l < "$remote_checksums" | tr -d ' ')"

  sync_checksums_local

  # Debug mode: verify local cache freshness against remote and analyze sync behavior
  if [[ "${S3C_DEBUG:-0}" == "1" ]]; then
    debug_compare_local_remote "$remote_checksums" "$S3C_DEBUG_LIMIT"
    DRY_RUN=1
  fi

  # Step 2: Build dist inventory
  local dist_list
  dist_list="$(build_dist_inventory)"
  log "Candidates in $S3C_PREFIX: $(wc -l < "$dist_list" | tr -d ' ')"

  # Step 3: Classify using both local and remote data
  local cls
  cls="$(classify_checksums_local "$dist_list" "$remote_checksums")"   # returns "valid|missing|empty|corrupt"
  local VALID_FILE MISSING_FILE EMPTY_FILE CORRUPT_FILE
  VALID_FILE="${cls%%|*}"; cls="${cls#*|}"
  MISSING_FILE="${cls%%|*}"; cls="${cls#*|}"
  EMPTY_FILE="${cls%%|*}"; cls="${cls#*|}"
  CORRUPT_FILE="$cls"

  # Step 4: Detect orphaned files (optional)
  local orphan_info
  if [[ "${S3C_CHECK_ORPHANS:-0}" == "1" ]]; then
    orphan_info="$(detect_orphans "$dist_list" "$remote_checksums")"
  else
    : > "$S3C_ROOTDIR/orphaned_checksums.txt"
    : > "$S3C_ROOTDIR/orphaned_artifacts.txt"
    orphan_info="$S3C_ROOTDIR/orphaned_checksums.txt|$S3C_ROOTDIR/orphaned_artifacts.txt"
  fi

  # Steps 5-7: Process plan and execute if not DRY_RUN
  process_plan "$VALID_FILE" "$MISSING_FILE" "$EMPTY_FILE" "$CORRUPT_FILE" "$orphan_info"
}

main "$@"
