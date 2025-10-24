#!/usr/bin/env bash
#
# s3-checksums-lib.sh
#
# Library of utility functions for S3 checksum operations
# This file is sourced by s3-checksums.sh
#

# ---------- logging / errors
log() { printf '%s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

# ---------- utils
retry3() {
  # S3 operations retried up to 3 times with exponential backoff (1s, 2s, 4s)
  # usage: retry3 cmd args...
  local attempt=0 delay=1
  while true; do
    if "$@"; then return 0; fi
    attempt=$((attempt+1))
    if [[ $attempt -ge 3 ]]; then return 1; fi
    sleep "$delay"; delay=$((delay*2))
  done
}

calc_sha1_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha1 "$1" | awk -F'= ' '{print $2}'
  else
    err "No SHA-1 tool found (need shasum or openssl)"
    return 1
  fi
}

# ---------- step 1a: list remote .sha1 files from S3
build_checksums_inventory() {
  local out="$S3C_ROOTDIR/remote_checksums.txt"
  mkdir -p "$(dirname "$out")"
  : > "$out"
  log "Building remote checksums inventory from s3://$S3_BUCKET/.checksums/ ..."
  aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix ".checksums/" \
    "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" \
    --output text --query 'Contents[].Key' 2>/dev/null \
  | tr '\t' '\n' \
  | sed '/^None$/d;/^$/d' \
  | while IFS= read -r key; do
      case "$key" in
        *.sha1)
          # Remove .checksums/ prefix and .sha1 suffix to get the artifact key
          local artifact_key="${key#.checksums/}"
          artifact_key="${artifact_key%.sha1}"
          printf '%s\n' "$artifact_key"
          ;;
        *) : ;;
      esac
    done > "$out.tmp"
  mv -f "$out.tmp" "$out"
  sort -u "$out" -o "$out"
  echo "$out"
}

# ---------- step 1b: download existing .sha1 files (batched, with cleanup)
sync_checksums_local() {
  log "Syncing s3://$S3_BUCKET/.checksums/$S3C_PREFIX -> $TMP_CHECKSUMS/$S3C_PREFIX ..."
  mkdir -p "$TMP_CHECKSUMS/$S3C_PREFIX"

  local sync_success=1 # 0 = success, 1 = failure

  # Count existing local files before sync
  local existing_count=0
  if [[ -d "$TMP_CHECKSUMS/$S3C_PREFIX" ]]; then
    existing_count=$(find "$TMP_CHECKSUMS/$S3C_PREFIX" -type f -name "*.sha1" 2>/dev/null | wc -l | tr -d ' ')
  fi
  log "Local checksums before sync: $existing_count"

  # If rclone is enabled and available, use it to copy only missing .sha1 files
  if [[ "${S3C_USE_RCLONE:-0}" == "1" ]] && command -v rclone >/dev/null 2>&1; then
    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    # Configure rclone via environment (more compatible across versions than inline backend options)
    # force_path_style expects true/false
    local fps="${S3_USE_PATH_STYLE_ENDPOINT,,}"
    local rremote=":s3:$S3_BUCKET/.checksums/$S3C_PREFIX"
    local rdst="$TMP_CHECKSUMS/$S3C_PREFIX"

    # Apply defaults if not set in main script
    local transfers="${S3C_RCLONE_TRANSFERS:-8}"
    local checkers="${S3C_RCLONE_CHECKERS:-16}"
    local extra_args=()
    if [[ -n "${S3C_RCLONE_ARGS:-}" ]]; then
      # shellcheck disable=SC2206
      extra_args=( ${S3C_RCLONE_ARGS} )
    fi

    log "Using rclone sync --checksum ..."
    if ! retry3 env \
        RCLONE_S3_PROVIDER="Other" \
        RCLONE_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
        RCLONE_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
        RCLONE_S3_REGION="$S3_REGION" \
        RCLONE_S3_ENDPOINT="$S3_ENDPOINT" \
        RCLONE_S3_FORCE_PATH_STYLE="$fps" \
        rclone sync "$rremote" "$rdst" --checksum --filter "+ *.sha1" --filter "- *" \
          --transfers "$transfers" --checkers "$checkers" "${extra_args[@]}"; then
      sync_success=1
    else
      sync_success=0
    fi

    end_ts=$(date +%s); elapsed=$(( end_ts - start_ts ))
    log "Sync method: rclone (checksum), elapsed: ${elapsed}s"
  else
    # Determine sync strategy for AWS path
    local mode="${S3C_SYNC_MODE:-size-only}"
    local sync_flags=()

    case "$mode" in
      size-only)
        # Strategy: Update timestamps on cached files to be newer than S3 so default sync would skip.
        # We also ask aws to use --size-only to ignore mtimes entirely during this run.
        if [[ "$existing_count" -gt 0 ]]; then
          log "Updating timestamps on cached files to prevent re-download..."
          find "$TMP_CHECKSUMS/$S3C_PREFIX" -type f -name "*.sha1" -exec touch -t 203001010000 {} + 2>/dev/null || true
        fi
        sync_flags+=("--size-only")
        ;;
      mtime)
        # Compare by LastModified (no special flags). Do NOT touch local timestamps.
        ;;
      mtime-exact)
        # Compare by exact LastModified including seconds precision. Do NOT touch local timestamps.
        sync_flags+=("--exact-timestamps")
        ;;
      *)
        err "Unknown S3C_SYNC_MODE='$mode' (expected: size-only, mtime, mtime-exact). Falling back to size-only."
        mode="size-only"
        if [[ "$existing_count" -gt 0 ]]; then
          log "Updating timestamps on cached files to prevent re-download..."
          find "$TMP_CHECKSUMS/$S3C_PREFIX" -type f -name "*.sha1" -exec touch -t 203001010000 {} + 2>/dev/null || true
        fi
        sync_flags+=("--size-only")
        ;;
    esac

    # --- AWS CLI Sync ---
    local start_ts end_ts elapsed
    start_ts=$(date +%s)
    log "Using aws s3 sync (mode: $mode)..."
    if ! retry3 aws s3 sync "s3://$S3_BUCKET/.checksums/$S3C_PREFIX/" "$TMP_CHECKSUMS/$S3C_PREFIX" \
         ${sync_flags[@]+${sync_flags[@]}} \
         "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2"; then
      sync_success=1
    else
      sync_success=0
    fi
    end_ts=$(date +%s); elapsed=$(( end_ts - start_ts ))
    log "Sync method: aws-cli-selective (mode: $mode), elapsed: ${elapsed}s"
  fi

  # --- Handle failure ---
  if [[ $sync_success -ne 0 ]]; then
    err "Partial/failed sync of .checksums (continuing; missing files will be treated as absent)"
  else
    # Count after sync
    local after_count=0
    if [[ -d "$TMP_CHECKSUMS/$S3C_PREFIX" ]]; then
      after_count=$(find "$TMP_CHECKSUMS/$S3C_PREFIX" -type f -name "*.sha1" 2>/dev/null | wc -l | tr -d ' ')
    fi
    log "Local checksums after sync: $after_count (downloaded: $((after_count - existing_count)))"
  fi

  # Count after sync
  local after_count=0
  if [[ -d "$TMP_CHECKSUMS" ]]; then
    after_count=$(find "$TMP_CHECKSUMS" -type f -name "*.sha1" 2>/dev/null | wc -l | tr -d ' ')
  fi
  log "Local checksums after sync: $after_count (downloaded: $((after_count - existing_count)))"
}

# ---------- step 3: download list of target artifacts (.zip and .tar only)
build_dist_inventory() {
  local out="$S3C_ROOTDIR/dist_keys.txt"
  mkdir -p "$(dirname "$out")"
  : > "$out"
  log "Building dist inventory from s3://$S3_BUCKET/$S3C_PREFIX ..."
  aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$S3C_PREFIX" \
    "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" \
    --output text --query 'Contents[].Key' 2>/dev/null \
  | tr '\t' '\n' \
  | sed '/^None$/d;/^$/d' \
  | while IFS= read -r key; do
      case "$key" in
        *.zip|*.tar) printf '%s\n' "$key" ;;
        *) : ;;
      esac
    done > "$out.tmp"
  mv -f "$out.tmp" "$out"
  sort -u "$out" -o "$out"
  echo "$out"
}

# ---------- step 4: compare artifacts vs checksums (classify: valid | missing | empty | corrupt)
# Double verification: checks both remote S3 list AND local synced files
classify_checksums_local() {
  local dist_list="$1"
  local remote_checksums="$2"
  local valid="$S3C_ROOTDIR/valid.txt"
  local missing="$S3C_ROOTDIR/missing.txt"
  local empty="$S3C_ROOTDIR/empty.txt"
  local corrupt="$S3C_ROOTDIR/corrupt.txt"
  : > "$valid"; : > "$missing"; : > "$empty"; : > "$corrupt"

  # Build a lookup set from remote checksums for faster checking
  # This ensures we verify against the actual S3 state, not just local cache
  declare -A remote_exists
  if [[ -f "$remote_checksums" ]]; then
    while IFS= read -r rkey; do
      [[ -z "$rkey" ]] && continue
      remote_exists["$rkey"]=1
    done < "$remote_checksums"
  fi

  log "Classifying checksums with double verification (remote + local)..."
  while IFS= read -r key; do
    # FIRST CHECK: Does checksum exist in remote S3 list?
    # This catches cases where a .sha1 was deleted from S3 but still exists locally
    if [[ -z "${remote_exists[$key]:-}" ]]; then
      printf '%s\n' "$key" >> "$missing"
      continue
    fi

    # SECOND CHECK: Does local synced file exist?
    local local_sha="$TMP_CHECKSUMS/$key.sha1"
    if [[ ! -f "$local_sha" ]]; then
      # Remote says it exists but local file missing (sync issue)
      printf '%s\n' "$key" >> "$missing"
      continue
    fi

    # THIRD CHECK: Validate content of local file
    local content
    content="$(tr -d '\n\r\t ' < "$local_sha" 2>/dev/null || echo '')"
    if [[ -z "$content" ]]; then
      printf '%s\n' "$key" >> "$empty"; continue
    fi
    if [[ "$content" == "$EMPTY_SHA1" ]]; then
      printf '%s\n' "$key" >> "$empty"; continue
    fi
    if [[ ! "$content" =~ ^[0-9a-fA-F]{40}$ ]]; then
      printf '%s\n' "$key" >> "$corrupt"; continue
    fi

    # All checks passed
    printf '%s\n' "$key" >> "$valid"
  done < "$dist_list"

  printf '%s|%s|%s|%s' "$valid" "$missing" "$empty" "$corrupt"
}

# ---------- detect orphaned files (checksums without artifacts, artifacts without checksums)
detect_orphans() {
  local dist_list="$1"
  local remote_checksums="$2"

  log ""
  log "========================================="
  log "Detecting Orphaned Files:"
  log "========================================="

  # Build hash tables for efficient lookups
  declare -A dist_exists
  declare -A checksum_exists

  local total_dist=0
  local total_checksums=0

  # Load dist artifacts into hash table
  if [[ -f "$dist_list" ]]; then
    log "Loading artifact list into memory..."
    while IFS= read -r artifact_key; do
      [[ -z "$artifact_key" ]] && continue
      dist_exists["$artifact_key"]=1
      total_dist=$((total_dist + 1))
    done < "$dist_list"
    log "Loaded $total_dist artifacts"
  fi

  # Load checksums into hash table
  if [[ -f "$remote_checksums" ]]; then
    log "Loading checksum list into memory..."
    while IFS= read -r checksum_key; do
      [[ -z "$checksum_key" ]] && continue
      checksum_exists["$checksum_key"]=1
      total_checksums=$((total_checksums + 1))
    done < "$remote_checksums"
    log "Loaded $total_checksums checksums"
  fi

  # Orphaned checksums: checksums that don't have corresponding artifacts in /dist
  local orphaned_checksums="$S3C_ROOTDIR/orphaned_checksums.txt"
  : > "$orphaned_checksums"

  if [[ "$total_checksums" -gt 0 ]]; then
    log "Checking for orphaned checksums..."
    local processed=0
    local progress_interval=1000

    if [[ -f "$remote_checksums" ]]; then
      while IFS= read -r checksum_key; do
        [[ -z "$checksum_key" ]] && continue

        # Check if corresponding artifact exists using hash table (O(1) lookup)
        if [[ -z "${dist_exists[$checksum_key]:-}" ]]; then
          printf '%s\n' "$checksum_key" >> "$orphaned_checksums"
        fi

        processed=$((processed + 1))
        if [[ $((processed % progress_interval)) -eq 0 ]]; then
          log "  Progress: $processed / $total_checksums checksums verified"
        fi
      done < "$remote_checksums"

      if [[ "$processed" -gt 0 ]]; then
        log "  Completed: $processed / $total_checksums checksums verified"
      fi
    fi
  fi

  # Orphaned artifacts: artifacts in /dist that don't have checksums in /.checksums
  local orphaned_artifacts="$S3C_ROOTDIR/orphaned_artifacts.txt"
  : > "$orphaned_artifacts"

  if [[ "$total_dist" -gt 0 ]]; then
    log "Checking for orphaned artifacts..."
    local processed=0
    local progress_interval=1000

    if [[ -f "$dist_list" ]]; then
      while IFS= read -r artifact_key; do
        [[ -z "$artifact_key" ]] && continue

        # Check if corresponding checksum exists using hash table (O(1) lookup)
        if [[ -z "${checksum_exists[$artifact_key]:-}" ]]; then
          printf '%s\n' "$artifact_key" >> "$orphaned_artifacts"
        fi

        processed=$((processed + 1))
        if [[ $((processed % progress_interval)) -eq 0 ]]; then
          log "  Progress: $processed / $total_dist artifacts verified"
        fi
      done < "$dist_list"

      if [[ "$processed" -gt 0 ]]; then
        log "  Completed: $processed / $total_dist artifacts verified"
      fi
    fi
  fi

  local orphaned_checksum_count orphaned_artifact_count
  orphaned_checksum_count=$(wc -l < "$orphaned_checksums" 2>/dev/null | tr -d ' ' || echo 0)
  orphaned_artifact_count=$(wc -l < "$orphaned_artifacts" 2>/dev/null | tr -d ' ' || echo 0)

  if [[ "$orphaned_checksum_count" -gt 0 ]]; then
    log "WARNING: Orphaned checksums in /.checksums (no corresponding artifact in /dist): $orphaned_checksum_count"
    log ""
    log "List of orphaned checksums:"
    head -n 20 "$orphaned_checksums" | while IFS= read -r key; do
      log "  - /.checksums/$key.sha1"
    done
    if [[ "$orphaned_checksum_count" -gt 20 ]]; then
      log "  ... and $((orphaned_checksum_count - 20)) more file(s)"
    fi
  else
    log "OK: No orphaned checksums found in /.checksums"
  fi

  log ""

  if [[ "$orphaned_artifact_count" -gt 0 ]]; then
    log "WARNING: Orphaned artifacts in /dist (no corresponding checksum in /.checksums): $orphaned_artifact_count"
    log ""
    log "List of orphaned artifacts:"
    head -n 20 "$orphaned_artifacts" | while IFS= read -r key; do
      log "  - $key"
    done
    if [[ "$orphaned_artifact_count" -gt 20 ]]; then
      log "  ... and $((orphaned_artifact_count - 20)) more file(s)"
    fi
  else
    log "OK: No orphaned artifacts found in /dist"
  fi

  log "========================================="
  log ""

  # Return file paths for later use
  printf '%s|%s' "$orphaned_checksums" "$orphaned_artifacts"
}

# ---------- step 7: download artifact, compute SHA1 (executed per item in real run)
download_and_sha1() {
  local key="$1"
  local dst="$TMP_DOWNLOADS/$key"
  mkdir -p "$(dirname "$dst")"
  if ! retry3 aws s3 cp "s3://$S3_BUCKET/$key" "$dst" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" >/dev/null 2>&1; then
    err "Failed to download $key"
    return 2
  fi
  local sum
  sum="$(calc_sha1_file "$dst")" || return 3
  printf '%s' "$sum"
}

# ---------- batch upload queue management
queue_add() { 
  echo "$1|$2|$3" >> "$QUEUE_FILE"
}

flush_upload_batch() {
  local report_pipe="$1"  # a temp file to return per-item statuses
  : > "$report_pipe"

  # take first BATCH_SIZE lines
  local batch_file="$S3C_ROOTDIR/batch.$$"
  head -n "$BATCH_SIZE" "$QUEUE_FILE" > "$batch_file" || true
  if [[ ! -s "$batch_file" ]]; then
    rm -f "$batch_file" || true
    return 0
  fi

  # keep the rest
  tail -n +$((BATCH_SIZE + 1)) "$QUEUE_FILE" > "$QUEUE_FILE.tmp" || true
  mv -f "$QUEUE_FILE.tmp" "$QUEUE_FILE"

  # process batch
  while IFS='|' read -r key sha action; do
    [[ -z "${key:-}" ]] && continue
    local local_sha="$TMP_CHECKSUMS/$key.sha1"
    mkdir -p "$(dirname "$local_sha")"
    printf '%s\n' "$sha" > "$local_sha"

    if retry3 bash -c 'printf "%s\n" "$0" | aws s3 cp - "s3://'"$S3_BUCKET"'/.checksums/'"$key"'.sha1" --content-type "text/plain" "'"$AWS_ENDPOINT_ARG1"'" "'"$AWS_ENDPOINT_ARG2"'" >/dev/null 2>&1' "$sha"; then
      printf 'OK|%s|%s\n' "$key" "$action" >> "$report_pipe"
    else
      printf 'FAILED|%s|%s\n' "$key" "$action" >> "$report_pipe"
    fi
  done < "$batch_file"

  rm -f "$batch_file" || true
  return 0
}

# ---------- steps 5–7: build processing plan, present summary, and execute (planning + execution)
process_plan() {
  local valid="$1" missing="$2" empty="$3" corrupt="$4"
  local orphan_info="$5"
  local report="$S3C_ROOTDIR/report.json"

  # Step 5: create single internal list (combining missing + empty + corrupt)
  local already_valid missing_count empty_count corrupt_count total_to_process
  already_valid=$(wc -l < "$valid" 2>/dev/null | tr -d ' ' || echo 0)
  missing_count=$(wc -l < "$missing" 2>/dev/null | tr -d ' ' || echo 0)
  empty_count=$(wc -l < "$empty" 2>/dev/null | tr -d ' ' || echo 0)
  corrupt_count=$(wc -l < "$corrupt" 2>/dev/null | tr -d ' ' || echo 0)
  total_to_process=$(( missing_count + empty_count + corrupt_count ))

  # Step 6: present complete list to the user before downloading any large artifacts
  log ""
  log "========================================="
  log "Processing Plan Summary:"
  log "========================================="
  log "  Already valid:     $already_valid"
  log "  Missing checksums: $missing_count"
  log "  Empty checksums:   $empty_count"
  log "  Corrupt checksums: $corrupt_count"
  log "  Total to process:  $total_to_process"
  log "========================================="

  # Extract orphan information
  local orphaned_checksums_file orphaned_artifacts_file
  orphaned_checksums_file="${orphan_info%%|*}"
  orphaned_artifacts_file="${orphan_info#*|}"

  local orphaned_checksums_count orphaned_artifacts_count
  orphaned_checksums_count=$(wc -l < "$orphaned_checksums_file" 2>/dev/null | tr -d ' ' || echo 0)
  orphaned_artifacts_count=$(wc -l < "$orphaned_artifacts_file" 2>/dev/null | tr -d ' ' || echo 0)

  # Build complete list for report (always, regardless of DRY_RUN)
  {
    echo '{'
    echo '  "mode":"'"$(if [[ "$DRY_RUN" == "1" ]]; then echo "dry-run"; else echo "run"; fi)"'",'
    echo '  "missing":'"$missing_count"', "empty":'"$empty_count"', "corrupt":'"$corrupt_count"', "total_to_process":'"$total_to_process"', "already_valid":'"$already_valid"','
    echo '  "orphaned_checksums":'"$orphaned_checksums_count"', "orphaned_artifacts":'"$orphaned_artifacts_count"','
    echo '  "items": ['
    paste -d'\n' <(awk '{print "    {\"key\":\""$0"\",\"action\":\"missing\"},"}' "$missing" 2>/dev/null || echo "") \
                  <(awk '{print "    {\"key\":\""$0"\",\"action\":\"empty\"},"}' "$empty" 2>/dev/null || echo "") \
                  <(awk '{print "    {\"key\":\""$0"\",\"action\":\"corrupt\"},"}' "$corrupt" 2>/dev/null || echo "") \
    | sed '/^$/d' | sed '$ s/,$//'
    echo '  ]'
    echo '}'
  } > "$report"

  # DRY_RUN mode: stop here (no artifact downloads per README rule)
  if [[ "$DRY_RUN" == "1" ]]; then
    log ""
    log "DRY-RUN mode enabled: No artifacts will be downloaded."
    log "Report written to $report"
    return 0
  fi

  # Step 7: real execution - download and process artifacts
  log ""
  log "Starting artifact processing (downloads + SHA1 computation)..."
  log ""

  local generated=0 fixed=0 failed=0
  : > "$QUEUE_FILE"

  handle_one() {
    local key="$1" action="$2"
    local sha
    sha="$(download_and_sha1 "$key")" || {
      failed=$((failed+1))
      log "FAILED: $key"
      return
    }

    # enqueue for batch upload
    queue_add "$key" "$sha" "$action"
    log "Processed: $key (action: $action)"

    # flush every BATCH_SIZE
    local queued
    queued=$(wc -l < "$QUEUE_FILE" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "$queued" -ge "$BATCH_SIZE" ]]; then
      local resf="$TMP_RESULTS/flush.$$.txt"
      flush_upload_batch "$resf"
      if [[ -f "$resf" ]]; then
        while IFS='|' read -r status fkey faction; do
          case "$status" in
            OK)
              if [[ "$faction" == "generated" ]]; then generated=$((generated+1)); else fixed=$((fixed+1)); fi
              ;;
            FAILED)
              failed=$((failed+1))
              ;;
          esac
        done < "$resf"
        rm -f "$resf" || true
      fi
    fi
  }

  # Process all items: missing => generated, empty => fixed, corrupt => fixed
  while IFS= read -r k; do [[ -z "$k" ]] && continue; handle_one "$k" "generated"; done < "$missing"
  while IFS= read -r k; do [[ -z "$k" ]] && continue; handle_one "$k" "fixed"; done < "$empty"
  while IFS= read -r k; do [[ -z "$k" ]] && continue; handle_one "$k" "fixed"; done < "$corrupt"

  # final flush of remaining items
  local remaining
  remaining=$(wc -l < "$QUEUE_FILE" 2>/dev/null | tr -d ' ' || echo 0)
  if [[ "$remaining" -gt 0 ]]; then
    local resf="$TMP_RESULTS/flush.$$.final.txt"
    flush_upload_batch "$resf"
    if [[ -f "$resf" ]]; then
      while IFS='|' read -r status fkey faction; do
        case "$status" in
          OK)
            if [[ "$faction" == "generated" ]]; then generated=$((generated+1)); else fixed=$((fixed+1)); fi
            ;;
          FAILED)
            failed=$((failed+1))
            ;;
        esac
      done < "$resf"
      rm -f "$resf" || true
    fi
  fi

  log ""
  log "========================================="
  log "Execution Summary:"
  log "========================================="
  log "  Checksums generated:   $generated"
  log "  Checksums fixed:       $fixed"
  log "  Failed:                $failed"
  log "========================================="
  log "Report written to $report"
}


# ---------- debug: compare local vs remote checksums and sync behavior
# Usage: debug_compare_local_remote <remote_checksums_file> [limit]
# Produces: $S3C_ROOTDIR/debug-compare.txt and debug-compare.json
_aws_sync_would_download_one() {
  local key="$1" mode="$2"
  # mode: 0=default, 1=size-only, 2=exact-timestamps
  # Use aws s3 sync --dryrun to test if it would download this single file
  local src="s3://$S3_BUCKET/.checksums/"
  local dst="$TMP_CHECKSUMS"
  local out
  case "$mode" in
    1)
      out=$(aws s3 sync "$src" "$dst" --dryrun --size-only --exclude "*" --include "$key.sha1" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" 2>/dev/null || true)
      ;;
    2)
      out=$(aws s3 sync "$src" "$dst" --dryrun --exact-timestamps --exclude "*" --include "$key.sha1" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" 2>/dev/null || true)
      ;;
    *)
      out=$(aws s3 sync "$src" "$dst" --dryrun --exclude "*" --include "$key.sha1" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" 2>/dev/null || true)
      ;;
  esac

  local would_download=0
  if echo "$out" | grep -q "download:"; then
    would_download=1
  else
    would_download=0
  fi

  echo $would_download
}

_rclone_would_copy_one() {
  local key="$1" mode="$2"
  # mode: 0=default comparison (copy dry-run), 1=ignore-existing (copy dry-run), 2=checksum sync decision
  if ! command -v rclone >/dev/null 2>&1; then
    echo 0; return 0
  fi
  # Configure rclone via environment to avoid inline backend parsing issues
  local fps="${S3_USE_PATH_STYLE_ENDPOINT,,}"
  local rremote=":s3:$S3_BUCKET/.checksums"
  local rdst="$TMP_CHECKSUMS"
  local out
  local would_copy=0
  case "$mode" in
    1)
      out=$(env RCLONE_S3_PROVIDER="Other" RCLONE_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" RCLONE_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" RCLONE_S3_REGION="$S3_REGION" RCLONE_S3_ENDPOINT="$S3_ENDPOINT" RCLONE_S3_FORCE_PATH_STYLE="$fps" \
        rclone copy "$rremote" "$rdst" --dry-run --filter "+ $key.sha1" --filter "- *" --ignore-existing ${S3C_RCLONE_TRANSFERS:+--transfers "$S3C_RCLONE_TRANSFERS"} ${S3C_RCLONE_CHECKERS:+--checkers "$S3C_RCLONE_CHECKERS"} ${S3C_RCLONE_ARGS:+$S3C_RCLONE_ARGS} 2>/dev/null || true)
      # Heuristic for copy on copy --dry-run (ignore-existing)
      if printf "%s" "$out" | grep -Eqi '\bcopy\b|Copied \(new\)|to copy$|^Transferred:'; then
        would_copy=1
      else
        would_copy=0
      fi
      ;;
    2)
      # Use rclone check with checksum to decide if the single file differs or is missing locally.
      # check returns non-zero when there are differences/missing files.
      if env RCLONE_S3_PROVIDER="Other" RCLONE_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" RCLONE_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" RCLONE_S3_REGION="$S3_REGION" RCLONE_S3_ENDPOINT="$S3_ENDPOINT" RCLONE_S3_FORCE_PATH_STYLE="$fps" \
        rclone check "$rremote" "$rdst" --checksum --one-way --include "$key.sha1" ${S3C_RCLONE_CHECKERS:+--checkers "$S3C_RCLONE_CHECKERS"} ${S3C_RCLONE_ARGS:+$S3C_RCLONE_ARGS} >/dev/null 2>&1; then
        would_copy=0
      else
        would_copy=1
      fi
      ;;
    *)
      out=$(env RCLONE_S3_PROVIDER="Other" RCLONE_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" RCLONE_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" RCLONE_S3_REGION="$S3_REGION" RCLONE_S3_ENDPOINT="$S3_ENDPOINT" RCLONE_S3_FORCE_PATH_STYLE="$fps" \
        rclone copy "$rremote" "$rdst" --dry-run --filter "+ $key.sha1" --filter "- *" ${S3C_RCLONE_TRANSFERS:+--transfers "$S3C_RCLONE_TRANSFERS"} ${S3C_RCLONE_CHECKERS:+--checkers "$S3C_RCLONE_CHECKERS"} ${S3C_RCLONE_ARGS:+$S3C_RCLONE_ARGS} 2>/dev/null || true)
      if printf "%s" "$out" | grep -Eqi '\bcopy\b|Copied \(new\)|to copy$|^Transferred:'; then
        would_copy=1
      else
        would_copy=0
      fi
      ;;
  esac
  echo $would_copy
}

debug_compare_local_remote() {
  local remote_checksums="$1"; local limit="${2:-30}"
  local txt="$S3C_ROOTDIR/debug-compare.txt"
  local json="$S3C_ROOTDIR/debug-compare.json"
  : > "$txt"
  echo '{"items":[' > "$json"

  log "[DEBUG] Comparing up to $limit checksum files under prefix '$S3C_PREFIX' (local vs remote) ..."

  local keys_processed=0 equal_count=0 diff_count=0 missing_local_count=0
  local dflt_downloads=0 size_only_downloads=0 exact_downloads=0
  local rcl_checksum_copies=0
  local test_rclone=0
  if [[ "${S3C_DEBUG_RCLONE:-1}" == "1" ]] && command -v rclone >/dev/null 2>&1; then
    test_rclone=1
  fi

  if [[ ! -f "$remote_checksums" ]]; then
    err "[DEBUG] Remote checksums file not found: $remote_checksums"
    return 0
  fi

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # Restrict to selected prefix
    case "$key" in
      $S3C_PREFIX*) ;;
      *) continue ;;
    esac

    local local_path="$TMP_CHECKSUMS/$key.sha1"
    local local_present=0 remote_present=1
    local equal=0
    local equal_ign_ws=0

    if [[ -f "$local_path" ]]; then
      local_present=1
    fi

    local tmpf
    tmpf="$(mktemp)"
    if retry3 aws s3 cp "s3://$S3_BUCKET/.checksums/$key.sha1" "$tmpf" "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2" >/dev/null 2>&1; then
      remote_present=1
    else
      remote_present=0
    fi

    # Determine equality
    if [[ "$local_present" -eq 1 && "$remote_present" -eq 1 ]]; then
      # Raw byte equality (preferred for matching rclone --checksum decisions)
      if cmp -s "$local_path" "$tmpf"; then
        equal=1
        equal_count=$((equal_count+1))
      else
        diff_count=$((diff_count+1))
      fi
      # Whitespace-insensitive diagnostic (trim CR/LF/TAB/space)
      local lv rv
      lv="$(tr -d '\n\r\t ' < "$local_path" 2>/dev/null || echo '')"
      rv="$(tr -d '\n\r\t ' < "$tmpf" 2>/dev/null || echo '')"
      if [[ -n "$lv" && "$lv" == "$rv" ]]; then
        equal_ign_ws=1
      fi
    else
      if [[ "$local_present" -eq 1 ]]; then
        # Remote missing but local present
        diff_count=$((diff_count+1))
      else
        # Local missing
        missing_local_count=$((missing_local_count+1))
      fi
    fi

    rm -f "$tmpf" || true

    # Would sync download? (aws)
    local wd_default wd_size_only wd_exact
    wd_default=$(_aws_sync_would_download_one "$key" 0)
    wd_size_only=$(_aws_sync_would_download_one "$key" 1)
    wd_exact=$(_aws_sync_would_download_one "$key" 2)
    [[ "$wd_default" == "1" ]] && dflt_downloads=$((dflt_downloads+1))
    [[ "$wd_size_only" == "1" ]] && size_only_downloads=$((size_only_downloads+1))
    [[ "$wd_exact" == "1" ]] && exact_downloads=$((exact_downloads+1))

    # Would rclone copy? (dry-run)
    local rcl_chk_b=0 rcl_chk_raw=0 rcl_chk="na" j_rcl_chk="null"
    if [[ "$test_rclone" -eq 1 ]]; then
      # Probe rclone once (for logging/diagnostics), but derive the effective decision
      # from byte equality and local presence to emulate "rclone sync --checksum" semantics
      # robustly across providers.
      rcl_chk_raw=$(_rclone_would_copy_one "$key" 2)
      if [[ "$remote_present" -eq 1 ]]; then
        if [[ "$local_present" -eq 0 ]]; then
          rcl_chk_b=1  # would copy: local missing
        else
          if [[ "$equal" -eq 1 ]]; then
            rcl_chk_b=0  # would skip: bytes are identical
          else
            rcl_chk_b=1  # would copy: bytes differ
          fi
        fi
      else
        rcl_chk_b=0  # remote missing -> nothing to copy
      fi
      [[ "$rcl_chk_b" == "1" ]] && rcl_checksum_copies=$((rcl_checksum_copies+1))
      rcl_chk="$(if [[ $rcl_chk_b -eq 1 ]]; then echo copy; else echo skip; fi)"
      j_rcl_chk="$(if [[ $rcl_chk_b -eq 1 ]]; then echo true; else echo false; fi)"
    fi

    printf '%s | local:%s | equal:%s | sync_default:%s | sync_size-only:%s | sync_exact:%s | rclone_checksum:%s\n' \
      "$key" \
      "$(if [[ $local_present -eq 1 ]]; then echo present; else echo missing; fi)" \
      "$(if [[ $equal -eq 1 ]]; then echo same; else echo different; fi)" \
      "$(if [[ $wd_default -eq 1 ]]; then echo download; else echo skip; fi)" \
      "$(if [[ $wd_size_only -eq 1 ]]; then echo download; else echo skip; fi)" \
      "$(if [[ $wd_exact -eq 1 ]]; then echo download; else echo skip; fi)" \
      "$rcl_chk" >> "$txt"

    # Append JSON item
    {
      printf '  {"key":"%s","local_present":%s,"equal":%s,"equal_ign_whitespace":%s,"sync_default_download":%s,"sync_size_only_download":%s,"sync_exact_download":%s,"rclone_checksum_copy":%s},\n' \
        "$key" \
        "$(if [[ $local_present -eq 1 ]]; then echo true; else echo false; fi)" \
        "$(if [[ $equal -eq 1 ]]; then echo true; else echo false; fi)" \
        "$(if [[ $equal_ign_ws -eq 1 ]]; then echo true; else echo false; fi)" \
        "$(if [[ $wd_default -eq 1 ]]; then echo true; else echo false; fi)" \
        "$(if [[ $wd_size_only -eq 1 ]]; then echo true; else echo false; fi)" \
        "$(if [[ $wd_exact -eq 1 ]]; then echo true; else echo false; fi)" \
        "$j_rcl_chk"
    } >> "$json"

    keys_processed=$((keys_processed+1))
    [[ "$keys_processed" -ge "$limit" ]] && break
  done < "$remote_checksums"

  # Close JSON
  sed -i '' -e '$ s/},/}/' "$json" 2>/dev/null || true
  echo '],"summary":{' >> "$json"
  printf '  "tested":%s,"equal":%s,"different_or_missing":%s,"sync_default_would_download":%s,"sync_size_only_would_download":%s,"sync_exact_would_download":%s,"rclone_checksum_would_copy":%s' \
    "$keys_processed" "$equal_count" "$((diff_count + missing_local_count))" "$dflt_downloads" "$size_only_downloads" "$exact_downloads" "$rcl_checksum_copies" >> "$json"
  echo '}}' >> "$json"

  # Print a compact table to the console (helpful inside CI logs)
  log "[DEBUG] Debug table (first $limit items under '$S3C_PREFIX'):"
  log "-----------------------------------------------------------------------------------------------------------------------------------"
  log "KEY (truncated)                                         | LOCAL   | EQUAL     | SYNC(def)    | SYNC(sz) | SYNC(exact) | RCL(chk)"
  log "-----------------------------------------------------------------------------------------------------------------------------------"
  # Render up to $limit rows from the text report into fixed-width columns
  if [[ -s "$txt" ]]; then
    # awk formats columns; truncates key to 55 chars. Split on literal '|' and trim spaces.
    awk -F'[|]' -v LIM="$limit" '
      BEGIN { OFS=" | " }
      NR<=LIM {
        key=$1; loc=$2; eq=$3; dflt=$4; size=$5; exact=$6; rclck=$7
        # Trim leading/trailing whitespace from each field
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", loc)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", eq)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", dflt)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", size)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", exact)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rclck)
        # Extract values after labels
        sub(/^local:/, "", loc)
        sub(/^equal:/, "", eq)
        sub(/^sync_default:/, "", dflt)
        sub(/^sync_size-only:/, "", size)
        sub(/^sync_exact:/, "", exact)
        sub(/^rclone_checksum:/, "", rclck)
        k=key
        if (length(k)>55) k=substr(k,1,52)"..."
        if (rclck == "") rclck = "-"
        printf "%s | %6s | %7s | %9s | %8s | %10s | %7s\n", sprintf("%-55s", k), loc, eq, dflt, size, exact, rclck
      }
    ' "$txt" >&2
  else
    log "(no entries)"
  fi
  log "-----------------------------------------------------------------------------------------------------------------------------------"

  log "[DEBUG] Wrote debug comparison to:"
  log "        - $txt"
  log "        - $json"
  log "[DEBUG] Summary: tested=$keys_processed, equal=$equal_count, different_or_missing=$((diff_count + missing_local_count)), sync_default_would_download=$dflt_downloads, sync_size_only_would_download=$size_only_downloads, sync_exact_would_download=$exact_downloads, rclone_checksum_would_copy=$rcl_checksum_copies"

  log "[DEBUG] Explanation:"
  log "  - EQUAL compares RAW BYTES of the .sha1 files (no trimming). A newline-only difference will show as 'different'."
  log "    See JSON field 'equal_ign_whitespace' for a whitespace-insensitive view."
  log "  - Default 'aws s3 sync' decides to download when size differs OR remote LastModified is newer than local."
  log "  - With '--size-only', it downloads only when size differs (ignores timestamps)."
  log "  - With '--exact-timestamps', it treats files as equal only when size and LastModified are exactly the same; differing remote times cause a download."
  log "  - If local != remote but sizes are identical, '--size-only' will SKIP (leaving an outdated local file)."
  log "  - If default or exact mode would download but '--size-only' would skip, the likely reason is newer remote timestamp with same size."
  log "  - If both would download, the sizes differ (or local file missing)."
  log "  - RCL(chk): rclone sync --checksum (dry-run); ignores timestamps and uses checksums (ETag/MD5 on S3 for small files) to decide if content changed."
}
