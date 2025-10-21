#!/usr/bin/env bash
#
# s3-generate-checksums.sh
#
# Purpose:
#   Iterate over all objects under the "dist/" prefix in an S3-compatible bucket,
#   compute a SHA-256 checksum for each file, and upload the checksum as a plain
#   text object to the path ".checksums/<original-key>.sha1" in the same bucket.
#
#   Note: Although the file extension is ".sha1" (to match existing tooling), the
#   checksum generated is SHA-256, as requested.
#
# Requirements:
#   - bash, awk, sed, mktemp
#   - AWS CLI v2 (aws)
#   - At least one of: shasum, sha256sum, or openssl
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
#   PREFIX          Prefix to scan (default: "dist/")
#   FILTER_EXTS     Space-separated list of extensions to include (default: "zip tar")
#   CONCURRENCY     Not used (placeholder for future parallelization)
#   DRY_RUN         If set to "1", do not upload, just print actions
#
set -euo pipefail

PREFIX=${PREFIX:-dist/}
FILTER_EXTS=${FILTER_EXTS:-"zip tar"}
DRY_RUN=${DRY_RUN:-0}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found"; exit 1; }
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
calc_sha256() {
  # Args: <file-path>
  if command -v shasum >/dev/null 2>&1; then
    shasum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    # Output format: SHA1(filename)= <hash>
    openssl dgst -sha1 "$1" | awk -F'= ' '{print $2}'
  else
    err "No SHA-256 tool found (need shasum, sha256sum, or openssl)"
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
cleanup() {
  if [[ -n "$TMP_AWS_CONFIG" && -f "$TMP_AWS_CONFIG" ]]; then
    rm -f "$TMP_AWS_CONFIG" || true
  fi
  if [[ -d "$TMP_WORK" ]]; then
    rm -rf "$TMP_WORK" || true
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

# Working directory for downloads
TMP_WORK=$(mktemp -d)

# Helpers to list all objects under PREFIX with pagination
list_keys() {
  local token="" more="true"
  while [[ "$more" == "true" ]]; do
    if [[ -n "$token" ]]; then
      resp=$(aws s3api list-objects-v2 "${AWS_ENDPOINT_ARGS[@]}" --bucket "$S3_BUCKET" --prefix "$PREFIX" --max-items 1000 --starting-token "$token")
    else
      resp=$(aws s3api list-objects-v2 "${AWS_ENDPOINT_ARGS[@]}" --bucket "$S3_BUCKET" --prefix "$PREFIX")
    fi

    # Extract keys. Use jq if present, else awk/sed.
    if command -v jq >/dev/null 2>&1; then
      echo "$resp" | jq -r '.Contents[]?.Key // empty'
      token=$(echo "$resp" | jq -r '."NextToken" // empty')
    else
      # Very simple extraction for keys; assumes Keys do not contain newlines
      echo "$resp" | sed -n 's/.*"Key"\s*:\s*"\([^"]\+\)".*/\1/p'
      token=$(echo "$resp" | sed -n 's/.*"NextToken"\s*:\s*"\([^"]\+\)".*/\1/p')
    fi

    if [[ -z "$token" ]]; then
      more="false"
    fi
  done
}

# Check extension filter
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

process_key() {
  local key="$1" filename tmpfile checksum checksum_key

  # Skip "directories"
  if [[ "$key" == */ ]]; then
    return 0
  fi

  if ! has_allowed_ext "$key"; then
    return 0
  fi

  filename=$(basename -- "$key")
  tmpfile="$TMP_WORK/$filename"

  log "Downloading s3://$S3_BUCKET/$key"
  aws s3 cp "s3://$S3_BUCKET/$key" "$tmpfile" "${AWS_ENDPOINT_ARGS[@]}" >/dev/null

  # Skip checksum generation for empty files
  if [[ ! -s "$tmpfile" ]]; then
    log "Skipping checksum for empty file: $key"
    return 0
  fi

  checksum=$(calc_sha256 "$tmpfile")
  if [[ -z "$checksum" ]]; then
    err "Failed to compute checksum for $key"
    return 1
  fi

  checksum_key=".checksums/$key.sha1"
  log "Uploading checksum to s3://$S3_BUCKET/$checksum_key"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would put '$checksum' to $checksum_key"
  else
    printf '%s' "$checksum" | aws s3 cp - "s3://$S3_BUCKET/$checksum_key" "${AWS_ENDPOINT_ARGS[@]}" \
      --content-type text/plain >/dev/null
  fi
}

main() {
  log "Listing objects with prefix '$PREFIX' in bucket '$S3_BUCKET'"
  list_keys | while IFS= read -r key; do
    process_key "$key"
  done
  log "Done."
}

main "$@"
