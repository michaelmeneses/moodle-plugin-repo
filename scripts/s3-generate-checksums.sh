#!/usr/bin/env bash
#
# s3-generate-checksums.sh
#
# Goal
#   Ensure every object under "dist/" has a valid SHA1 stored at
#   ".checksums/<key>.sha1" in the same S3-compatible bucket.
#
# Design (8 steps per README.md)
#   1. Downloads all existing .sha1 files from checksums directory (batched)
#   2. Downloads list of target artifacts (only .zip and .tar suffixes)
#   3. Compares artifacts vs checksums; marks for processing if: missing, empty, or corrupt
#   4. Creates single internal list of artifacts requiring processing
#   5. Presents this list to user *before* downloading large artifacts
#   6. If not DRY_RUN: iterates list, downloads artifact, computes SHA1, uploads .sha1
#   7. S3 operations retried up to 3 times with exponential backoff (1s, 2s, 4s)
#   8. No data deleted; temp directory preserved for auditing
#   9. Detects and reports orphaned files (checksums without artifacts, artifacts without checksums)
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
#   PREFIX   (default: "dist/")
#   DRY_RUN  (default: "0")
#   TMP_WORK (default: "./temp") - can also be passed as first argument
#

set -euo pipefail

# ---------- error handling
on_err() { 
  printf 'ERROR: Script failed at line %s\n' "$1" >&2
  exit 1
}
trap 'on_err $LINENO' ERR

# ---------- inputs
PREFIX=${PREFIX:-dist/}
DRY_RUN=${DRY_RUN:-0}
BATCH_SIZE=${BATCH_SIZE:-20}
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
# Accept working directory as first parameter or use TMP_WORK env or default to ./temp
if [[ -n "${1:-}" ]]; then
  TMP_WORK="$1"
elif [[ -z "${TMP_WORK:-}" ]]; then
  TMP_WORK="$PROJECT_ROOT/temp"
fi
TMP_CHECKSUMS="$TMP_WORK/checksums"
TMP_DOWNLOADS="$TMP_WORK/downloads"
TMP_RESULTS="$TMP_WORK/results"
mkdir -p "$TMP_WORK" "$TMP_CHECKSUMS" "$TMP_DOWNLOADS" "$TMP_RESULTS"

# ---------- aws environment setup
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"
export AWS_REGION="$S3_REGION"
export AWS_EC2_METADATA_DISABLED=true

AWS_ENDPOINT_ARG1="--endpoint-url"
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
  # step 8: temp directory preserved for auditing (only AWS config removed)
  if [[ -n "${TMP_AWS_CONFIG:-}" && -f "$TMP_AWS_CONFIG" ]]; then
    rm -f "$TMP_AWS_CONFIG" || true
  fi
  # Note: TMP_WORK and its contents are intentionally NOT removed
}
trap cleanup EXIT INT TERM

# ---------- batch upload queue initialization
QUEUE_FILE="$TMP_WORK/upload_queue.txt"
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
  log "Prefix: $PREFIX"
  log "Working directory: $TMP_WORK"
  [[ "$DRY_RUN" == "1" ]] && log "Mode: DRY RUN (no artifact downloads)"
  log "========================================="

  # Step 1: Get remote checksum inventory and sync locally
  local remote_checksums
  remote_checksums="$(build_checksums_inventory)"
  log "Remote checksums found: $(wc -l < "$remote_checksums" | tr -d ' ')"

  sync_checksums_local

  # Step 2: Build dist inventory
  local dist_list
  dist_list="$(build_dist_inventory)"
  log "Candidates in dist/: $(wc -l < "$dist_list" | tr -d ' ')"

  # Step 3: Classify using both local and remote data
  local cls
  cls="$(classify_checksums_local "$dist_list" "$remote_checksums")"   # returns "valid|missing|empty|corrupt"
  local VALID_FILE MISSING_FILE EMPTY_FILE CORRUPT_FILE
  VALID_FILE="${cls%%|*}"; cls="${cls#*|}"
  MISSING_FILE="${cls%%|*}"; cls="${cls#*|}"
  EMPTY_FILE="${cls%%|*}"; cls="${cls#*|}"
  CORRUPT_FILE="$cls"

  # Step 4: Detect orphaned files
  local orphan_info
  orphan_info="$(detect_orphans "$dist_list" "$remote_checksums")"

  # Step 5-8: Process plan and execute if not DRY_RUN
  process_plan "$VALID_FILE" "$MISSING_FILE" "$EMPTY_FILE" "$CORRUPT_FILE" "$orphan_info"
}

main "$@"
