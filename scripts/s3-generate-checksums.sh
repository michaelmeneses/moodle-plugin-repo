#!/usr/bin/env bash
#
# s3-generate-checksums.sh
#
# Purpose:
#   Ensure every archive under "dist/" has a valid SHA1 checksum at
#   ".checksums/<original-key>.sha1" in the S3 bucket.
#   - Fixes empty checksums (da39a3ee5e6b4b0d3255bfef95601890afd80709)
#   - Generates missing checksums
#
# Requirements:
#   - bash, awk, sed, mktemp, wc
#   - AWS CLI (aws) with S3 commands
#   - shasum or openssl (for SHA1 calculation)
#
# Required environment variables:
#   S3_BUCKET, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY,
#   S3_REGION, S3_ENDPOINT, S3_USE_PATH_STYLE_ENDPOINT
#
# Optional environment variables:
#   PREFIX          (default: "dist/")
#   FILTER_EXTS     (default: "zip tar")
#   DRY_RUN         (default: "0")
#   PARALLEL_JOBS   (default: "10")
#
# Usage:
#   S3_BUCKET=privatesatis \
#   S3_ACCESS_KEY_ID=... \
#   S3_SECRET_ACCESS_KEY=... \
#   S3_REGION=auto \
#   S3_ENDPOINT=https://xxxx.r2.cloudflarestorage.com \
#   S3_USE_PATH_STYLE_ENDPOINT=true \
#   scripts/s3-generate-checksums.sh
#
set -euo pipefail

# Error handler for debugging
error_handler() {
  local line_no=$1
  err "Script failed at line $line_no"
  exit 1
}
trap 'error_handler $LINENO' ERR

PREFIX=${PREFIX:-dist/}
FILTER_EXTS=${FILTER_EXTS:-"zip tar"}
DRY_RUN=${DRY_RUN:-0}
PARALLEL_JOBS=${PARALLEL_JOBS:-10}

# Constants
EMPTY_SHA1="da39a3ee5e6b4b0d3255bfef95601890afd80709"

# Counters
FIXED_EMPTY=0
GENERATED_MISSING=0
CHECKSUMS_SCANNED=0
MISSING_COUNT=0
SKIPPED_NO_SOURCE=0

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found"; exit 1; };
}

# Validate environment
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_ACCESS_KEY_ID:?S3_ACCESS_KEY_ID is required}"
: "${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY is required}"
: "${S3_REGION:?S3_REGION is required}"
: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_USE_PATH_STYLE_ENDPOINT:?S3_USE_PATH_STYLE_ENDPOINT is required (true/false)}"

require aws

# Determine hash tool
calc_sha1() {
  # Args: <file-path>
  if command -v shasum >/dev/null 2>&1; then
    shasum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    # Output format: SHA1(filename)= <hash>
    openssl dgst -sha1 "$1" | awk -F'= ' '{print $2}'
  else
    err "No SHA-1 tool found (need shasum or openssl)"
    return 1
  fi
}

# Setup AWS env
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"
export AWS_REGION="$S3_REGION"
export AWS_EC2_METADATA_DISABLED=true

# Store endpoint args as variables for parallel job compatibility
AWS_ENDPOINT_ARG1="--endpoint-url"
AWS_ENDPOINT_ARG2="$S3_ENDPOINT"

# Configure path-style addressing if requested
TMP_AWS_CONFIG=""
cleanup() {
  if [[ -n "$TMP_AWS_CONFIG" && -f "$TMP_AWS_CONFIG" ]]; then
    rm -f "$TMP_AWS_CONFIG" || true
  fi
}
trap cleanup EXIT INT TERM

if [[ "${S3_USE_PATH_STYLE_ENDPOINT,,}" == "true" ]]; then
  TMP_AWS_CONFIG=$(mktemp)
  cat > "$TMP_AWS_CONFIG" <<EOF
[default]
region = ${S3_REGION}
[default.s3]
addressing_style = path
EOF
  export AWS_CONFIG_FILE="$TMP_AWS_CONFIG"
fi

# Working directories
TMP_WORK="./temp"
TMP_CHECKSUMS="$TMP_WORK/checksums"
TMP_DOWNLOADS="$TMP_WORK/downloads"
mkdir -p "$TMP_CHECKSUMS" "$TMP_DOWNLOADS"

# Helpers
s3_object_exists() {
  local key="$1"
  aws s3api head-object --bucket "$S3_BUCKET" --key "$key" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" >/dev/null 2>&1
}

list_dist_keys() {
  # Outputs one key per line under PREFIX
  aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$PREFIX" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" \
    --output text --query 'Contents[].Key' 2>/dev/null | tr '\t' '\n' | sed '/^None$/d' | grep -v '^$' || true
}

list_checksum_keys() {
  # Outputs checksum keys under .checksums/PREFIX
  local cprefix
  cprefix=".checksums/${PREFIX}"
  aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$cprefix" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" \
    --output text --query 'Contents[].Key' 2>/dev/null | tr '\t' '\n' | sed '/^None$/d' | grep -v '^$' || true
}

has_allowed_ext() {
  local key="$1" ext
  ext="${key##*.}"
  for e in $FILTER_EXTS; do
    if [[ "$ext" == "$e" ]]; then
      return 0
    fi
  done
  return 1
}

compute_and_upload_checksum() {
  # Args: key (dist/...)
  local key="$1" filename tmpfile checksum checksum_key local_checksum_file
  filename=$(basename -- "$key")
  tmpfile="$TMP_DOWNLOADS/$filename.$$"  # Add PID for parallel safety
  checksum_key=".checksums/$key.sha1"

  aws s3 cp "s3://$S3_BUCKET/$key" "$tmpfile" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" >/dev/null 2>&1
  checksum=$(calc_sha1 "$tmpfile")
  rm -f "$tmpfile"

  if [[ -z "$checksum" ]]; then
    err "Failed to compute checksum for $key"
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY_RUN] Would upload: $checksum_key => $checksum"
  else
    # Upload to S3 IMMEDIATELY (so progress is not lost on timeout/error)
    printf '%s' "$checksum" | aws s3 cp - "s3://$S3_BUCKET/$checksum_key" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" \
      --content-type text/plain >/dev/null 2>&1

    # Also save locally for reference
    local_checksum_file="$TMP_CHECKSUMS/$key.sha1"
    mkdir -p "$(dirname "$local_checksum_file")"
    printf '%s' "$checksum" > "$local_checksum_file"
  fi
}

download_and_check_checksum() {
  # Download a single checksum file from S3 and return its content
  # Args: checksum_key (e.g., ".checksums/dist/vendor/package/version.zip.sha1")
  # Returns: the hash value, or empty string if file doesn't exist
  local checksum_key="$1"
  local content

  content=$(aws s3 cp "s3://$S3_BUCKET/$checksum_key" - "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" 2>/dev/null | tr -d '\n\r\t ' || echo "")
  printf '%s' "$content"
}

process_single_file() {
  # Process a single file (for parallel execution)
  # Args: key, total_count, processed_count
  local key="$1"
  local total_count="$2"
  local processed_count="$3"
  local checksum_key checksum_value result_file

  checksum_key=".checksums/$key.sha1"
  result_file="$TMP_WORK/results/result.$$"

  # Check if checksum exists and get its value
  checksum_value=$(download_and_check_checksum "$checksum_key")

  # Process if checksum is missing or empty
  if [[ -z "$checksum_value" ]]; then
    log "[$processed_count/$total_count] Missing checksum: $key"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "MISSING_DRY" > "$result_file"
    else
      if compute_and_upload_checksum "$key"; then
        log "  ✓ Generated checksum for: $key"
        echo "GENERATED" > "$result_file"
      else
        echo "FAILED" > "$result_file"
      fi
    fi
  elif [[ "$checksum_value" == "$EMPTY_SHA1" ]]; then
    log "[$processed_count/$total_count] Empty checksum: $key"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "EMPTY_DRY" > "$result_file"
    else
      if compute_and_upload_checksum "$key"; then
        log "  ✓ Fixed empty checksum for: $key"
        echo "FIXED" > "$result_file"
      else
        echo "FAILED" > "$result_file"
      fi
    fi
  else
    # Checksum exists and is valid
    echo "VALID" > "$result_file"
  fi
}

process_dist_files() {
  log "Starting unified checksum validation and generation..."
  log "Listing all files in '$PREFIX' from S3..."

  local dist_keys_file total_count results_dir
  dist_keys_file="$TMP_WORK/all_dist_keys.txt"
  results_dir="$TMP_WORK/results"

  # Create results directory
  mkdir -p "$results_dir"

  # List all dist files with allowed extensions
  : > "$dist_keys_file"

  log "Fetching list from S3 (this may take a moment for large buckets)..."
  list_dist_keys | while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    [[ "$key" == */ ]] && continue
    if has_allowed_ext "$key"; then
      printf '%s\n' "$key"
    fi
  done > "$dist_keys_file"

  total_count=$(wc -l < "$dist_keys_file" | tr -d ' ') || total_count=0
  log "Found $total_count files to process in dist/"

  if [[ "$total_count" -eq 0 ]]; then
    log "No files found to process"
    return 0
  fi

  log ""
  log "Processing files with $PARALLEL_JOBS parallel jobs..."
  log "Progress updates every 50 files"
  log ""

  # Export functions and variables needed by parallel jobs
  export -f process_single_file download_and_check_checksum compute_and_upload_checksum calc_sha1 log err has_allowed_ext
  export S3_BUCKET S3_ENDPOINT PREFIX EMPTY_SHA1 DRY_RUN TMP_WORK TMP_DOWNLOADS TMP_CHECKSUMS FILTER_EXTS
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION AWS_EC2_METADATA_DISABLED AWS_CONFIG_FILE
  export AWS_ENDPOINT_ARG1 AWS_ENDPOINT_ARG2

  # Process files in parallel using xargs
  local processed_count=0
  cat "$dist_keys_file" | while IFS= read -r key; do
    processed_count=$((processed_count + 1))
    printf '%s\t%s\t%s\n' "$key" "$total_count" "$processed_count"
  done | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    IFS=$'"'"'\t'"'"' read -r key total processed <<< "{}"
    process_single_file "$key" "$total" "$processed"
  '

  log ""
  log "Parallel processing completed. Collecting results..."

  # Count results
  local result_files
  result_files=$(find "$results_dir" -type f -name "result.*" 2>/dev/null)

  for rf in $result_files; do
    result=$(cat "$rf" 2>/dev/null || echo "UNKNOWN")
    case "$result" in
      VALID)
        CHECKSUMS_SCANNED=$((CHECKSUMS_SCANNED + 1))
        ;;
      GENERATED)
        GENERATED_MISSING=$((GENERATED_MISSING + 1))
        MISSING_COUNT=$((MISSING_COUNT + 1))
        ;;
      FIXED)
        FIXED_EMPTY=$((FIXED_EMPTY + 1))
        CHECKSUMS_SCANNED=$((CHECKSUMS_SCANNED + 1))
        ;;
      MISSING_DRY|EMPTY_DRY)
        MISSING_COUNT=$((MISSING_COUNT + 1))
        ;;
      FAILED)
        SKIPPED_NO_SOURCE=$((SKIPPED_NO_SOURCE + 1))
        ;;
    esac
  done

  log "Finished processing all $total_count files"
}

main() {
  log "========================================="
  log "S3 Checksum Generator"
  log "========================================="
  log "Bucket: $S3_BUCKET"
  log "Prefix: $PREFIX"
  log "Filter extensions: $FILTER_EXTS"
  log "Parallel jobs: $PARALLEL_JOBS"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Mode: DRY RUN (no uploads)"
  fi
  log "========================================="
  log ""

  process_dist_files
  log ""

  log "========================================="
  log "Summary:"
  log "  Valid checksums found:       $CHECKSUMS_SCANNED"
  log "  Empty checksums fixed:       $FIXED_EMPTY"
  log "  Missing checksums found:     $MISSING_COUNT"
  log "  Missing checksums generated: $GENERATED_MISSING"
  log "  Skipped (no source found):   $SKIPPED_NO_SOURCE"
  log "========================================="
  log "✓ Done. All checksums uploaded immediately to S3."
}

main "$@"
