#!/usr/bin/env bash
#
# s3-generate-checksums.sh
#
# Purpose:
#   Ensure every archive under "dist/" has a corresponding checksum object
#   at ".checksums/<original-key>.sha1" in the same S3-compatible bucket.
#   The script is optimized to:
#     1) Download the .checksums subtree locally and fix any checksum files
#        that contain the empty-file SHA1
#        (da39a3ee5e6b4b0d3255bfef95601890afd80709).
#     2) Compare inventories of "dist/" vs ".checksums/dist/" and generate
#        only the missing checksums.
#
# Requirements:
#   - bash, awk, sed, mktemp, find
#   - AWS CLI (aws) with S3API (list-objects-v2, head-object) and S3 (cp/sync) commands
#   - At least one of: shasum, or openssl
#
# Environment variables:
#   S3_BUCKET                 (e.g., "privatesatis")
#   S3_ACCESS_KEY_ID          (e.g., "AKIA...")
#   S3_SECRET_ACCESS_KEY      (secret)
#   S3_REGION                 (e.g., "auto")
#   S3_ENDPOINT               (e.g., "https://<account>.r2.cloudflarestorage.com")
#   S3_USE_PATH_STYLE_ENDPOINT ("true" or "false")
#
# Usage:
#   chmod +x scripts/s3-generate-checksums.sh
#   S3_BUCKET=privatesatis \
#   S3_ACCESS_KEY_ID=... \
#   S3_SECRET_ACCESS_KEY=... \
#   S3_REGION=auto \
#   S3_ENDPOINT=https://xxxx.r2.cloudflarestorage.com \
#   S3_USE_PATH_STYLE_ENDPOINT=true \
#   scripts/s3-generate-checksums.sh
#
# Options (env vars):
#   PREFIX          Prefix to scan for source files (default: "dist/")
#   FILTER_EXTS     Space-separated list of extensions to include (default: "zip tar")
#   DRY_RUN         If set to "1", do not upload, just print actions (default: "0")
#
set -euo pipefail

PREFIX=${PREFIX:-dist/}
FILTER_EXTS=${FILTER_EXTS:-"zip tar"}
DRY_RUN=${DRY_RUN:-0}

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

AWS_ENDPOINT_ARGS=(--endpoint-url "$S3_ENDPOINT")

# Configure path-style addressing if requested
TMP_AWS_CONFIG=""
PERSISTENT_CACHE=false
cleanup() {
  if [[ -n "$TMP_AWS_CONFIG" && -f "$TMP_AWS_CONFIG" ]]; then
    rm -f "$TMP_AWS_CONFIG" || true
  fi
  if [[ -d "$TMP_WORK" ]]; then
    rm -rf "$TMP_WORK" || true
  fi
  # Don't remove TMP_CHECKSUMS if it's the persistent cache
  if [[ "$PERSISTENT_CACHE" == "false" && -d "$TMP_CHECKSUMS" && "$TMP_CHECKSUMS" != "/tmp/s3-satis-generator/.checksums" ]]; then
    rm -rf "$TMP_CHECKSUMS" || true
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
# Use /tmp/s3-satis-generator/.checksums if available (from GitHub Actions cache)
if [[ -d "/tmp/s3-satis-generator/.checksums" ]]; then
  log "Using existing checksums cache at /tmp/s3-satis-generator/.checksums"
  TMP_CHECKSUMS="/tmp/s3-satis-generator/.checksums"
  TMP_WORK=$(mktemp -d)
  TMP_DOWNLOADS="$TMP_WORK/downloads"
  mkdir -p "$TMP_DOWNLOADS"
  # Don't clean up TMP_CHECKSUMS on exit since it's the persistent cache
  PERSISTENT_CACHE=true
else
  TMP_WORK=$(mktemp -d)
  TMP_CHECKSUMS="$TMP_WORK/checksums"
  TMP_DOWNLOADS="$TMP_WORK/downloads"
  mkdir -p "$TMP_CHECKSUMS" "$TMP_DOWNLOADS"
  PERSISTENT_CACHE=false
fi

# Helpers
s3_object_exists() {
  local key="$1"
  aws s3api head-object --bucket "$S3_BUCKET" --key "$key" "${AWS_ENDPOINT_ARGS[@]}" >/dev/null 2>&1
}

list_dist_keys() {
  # Outputs one key per line under PREFIX
  aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$PREFIX" "${AWS_ENDPOINT_ARGS[@]}" \
    --output text --query 'Contents[].Key' 2>/dev/null | sed '/^None$/d' || true
}

list_checksum_keys() {
  # Outputs checksum keys under .checksums/PREFIX
  local cprefix
  cprefix=".checksums/${PREFIX}"
  aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$cprefix" "${AWS_ENDPOINT_ARGS[@]}" \
    --output text --query 'Contents[].Key' 2>/dev/null | sed '/^None$/d' || true
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
  local key="$1" filename tmpfile checksum checksum_key
  filename=$(basename -- "$key")
  tmpfile="$TMP_DOWNLOADS/$filename"
  checksum_key=".checksums/$key.sha1"

  log "Downloading s3://$S3_BUCKET/$key"
  aws s3 cp "s3://$S3_BUCKET/$key" "$tmpfile" "${AWS_ENDPOINT_ARGS[@]}" >/dev/null
  checksum=$(calc_sha1 "$tmpfile")
  rm -f "$tmpfile"

  if [[ -z "$checksum" ]]; then
    err "Failed to compute checksum for $key"
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would upload checksum to s3://$S3_BUCKET/$checksum_key => $checksum"
  else
    printf '%s' "$checksum" | aws s3 cp - "s3://$S3_BUCKET/$checksum_key" "${AWS_ENDPOINT_ARGS[@]}" \
      --content-type text/plain >/dev/null
  fi
}

fix_empty_hash_checksums() {
  # Download entire .checksums subtree for the PREFIX locally and fix empty-hash files
  if [[ "$PERSISTENT_CACHE" == "false" ]]; then
    log "Syncing .checksums/${PREFIX} to local temp dir to check for empty hashes..."
    # If the source path doesn't exist, allow sync to no-op
    aws s3 sync "s3://$S3_BUCKET/.checksums/${PREFIX}" "$TMP_CHECKSUMS" "${AWS_ENDPOINT_ARGS[@]}" >/dev/null 2>&1 || true
  else
    log "Using persistent cache at $TMP_CHECKSUMS (skipping S3 sync)"
  fi

  if [[ ! -d "$TMP_CHECKSUMS" ]]; then
    return 0
  fi

  # Iterate over all sha1 files
  while IFS= read -r -d '' f; do
    ((CHECKSUMS_SCANNED++))
    local h rel orig_key
    h=$(tr -d '\n\r\t ' < "$f" || true)
    if [[ "$h" == "$EMPTY_SHA1" ]]; then
      # Map local path back to S3 key: TMP_CHECKSUMS/<PREFIX>/path/file.zip.sha1 -> dist/.../file.zip
      rel="${f#${TMP_CHECKSUMS}/}"
      orig_key="${rel%*.sha1}"
      # Ensure it maps under PREFIX
      if [[ -n "$orig_key" && -n "$PREFIX" ]]; then
        # Confirm source exists in S3
        if s3_object_exists "$orig_key"; then
          log "Found empty-hash checksum: $rel -> fixing using $orig_key"
          if [[ "$DRY_RUN" == "1" ]]; then
            log "DRY_RUN: would recompute checksum for s3://$S3_BUCKET/$orig_key and overwrite .checksums/$orig_key.sha1"
          else
            compute_and_upload_checksum "$orig_key" && ((FIXED_EMPTY++)) || true
          fi
        else
          log "Source missing for checksum '$rel' (expected: $orig_key). Skipping."
          ((SKIPPED_NO_SOURCE++))
        fi
      fi
    fi
  done < <(find "$TMP_CHECKSUMS" -type f -name '*.sha1' -print0)
}

generate_missing_checksums() {
  log "Listing inventories for '$PREFIX' and matching .checksums..."

  # Build list of dist keys (filtered by extension)
  local dist_keys_file checksummed_keys_file missing_file
  dist_keys_file="$TMP_WORK/dist_keys.txt"
  checksummed_keys_file="$TMP_WORK/checksummed_keys.txt"
  missing_file="$TMP_WORK/missing_keys.txt"

  : > "$dist_keys_file"
  : > "$checksummed_keys_file"

  list_dist_keys | while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    [[ "$key" == */ ]] && continue
    if has_allowed_ext "$key"; then
      printf '%s\n' "$key" >> "$dist_keys_file"
    fi
  done

  # Prefer deriving from local synced files to avoid another remote roundtrip
  if [[ -d "$TMP_CHECKSUMS" ]]; then
    # For each local checksum file, derive original key
    while IFS= read -r -d '' f; do
      local rel orig_key
      rel="${f#${TMP_CHECKSUMS}/}"
      orig_key="${rel%*.sha1}"
      printf '%s\n' "$orig_key" >> "$checksummed_keys_file"
    done < <(find "$TMP_CHECKSUMS" -type f -name '*.sha1' -print0)
  else
    # Fallback to remote listing
    list_checksum_keys | while IFS= read -r ckey; do
      [[ -z "$ckey" ]] && continue
      # Strip ".checksums/" prefix and ".sha1" suffix
      ckey="${ckey#.checksums/}"
      ckey="${ckey%*.sha1}"
      printf '%s\n' "$ckey" >> "$checksummed_keys_file"
    done
  fi

  # Compute dist minus checksummed (missing)
  sort -u "$dist_keys_file" -o "$dist_keys_file"
  sort -u "$checksummed_keys_file" -o "$checksummed_keys_file"
  comm -23 "$dist_keys_file" "$checksummed_keys_file" > "$missing_file" || true

  MISSING_COUNT=$(wc -l < "$missing_file" | tr -d ' ')
  if [[ "$MISSING_COUNT" -gt 0 ]]; then
    log "Found $MISSING_COUNT missing checksum(s). Generating..."
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      if s3_object_exists "$key"; then
        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY_RUN: would generate checksum for s3://$S3_BUCKET/$key"
        else
          compute_and_upload_checksum "$key" && ((GENERATED_MISSING++)) || true
        fi
      else
        log "Skipping missing source: $key"
        ((SKIPPED_NO_SOURCE++))
      fi
    done < "$missing_file"
  else
    log "No missing checksums detected."
  fi
}

main() {
  log "Bucket: $S3_BUCKET"
  log "Prefix: $PREFIX"
  log "Filter extensions: $FILTER_EXTS"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Mode: DRY RUN (no uploads)"
  fi
  log ""

  fix_empty_hash_checksums
  log ""
  generate_missing_checksums
  log ""

  log "========================================="
  log "Summary:"
  log "  Checksums scanned locally:   $CHECKSUMS_SCANNED"
  log "  Empty-hash fixed:            $FIXED_EMPTY"
  log "  Missing checksums found:     $MISSING_COUNT"
  log "  Missing checksums generated: $GENERATED_MISSING"
  log "  Skipped (no source found):   $SKIPPED_NO_SOURCE"
  log "========================================="
  log "Done."
}

main "$@"
