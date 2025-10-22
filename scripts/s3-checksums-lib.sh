#!/usr/bin/env bash
#
# s3-checksums-lib.sh
#
# Library of utility functions for S3 checksum operations
# This file is sourced by s3-generate-checksums.sh
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
  local out="$TMP_WORK/remote_checksums.txt"
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
  log "Syncing s3://$S3_BUCKET/.checksums/ -> $TMP_CHECKSUMS/ ..."
  mkdir -p "$TMP_CHECKSUMS"
  if ! retry3 aws s3 sync "s3://$S3_BUCKET/.checksums/" "$TMP_CHECKSUMS" \
       "$AWS_ENDPOINT_ARG1" "$AWS_ENDPOINT_ARG2"; then
    err "Partial/failed sync of .checksums (continuing; missing files will be treated as absent)"
  fi
}

# ---------- step 2: download list of target artifacts (.zip and .tar only)
build_dist_inventory() {
  local out="$TMP_WORK/dist_keys.txt"
  mkdir -p "$(dirname "$out")"
  : > "$out"
  log "Building dist inventory from s3://$S3_BUCKET/$PREFIX ..."
  aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$PREFIX" \
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

# ---------- step 3: compare artifacts vs checksums (classify: valid | missing | empty | corrupt)
# Double verification: checks both remote S3 list AND local synced files
classify_checksums_local() {
  local dist_list="$1"
  local remote_checksums="$2"
  local valid="$TMP_WORK/valid.txt"
  local missing="$TMP_WORK/missing.txt"
  local empty="$TMP_WORK/empty.txt"
  local corrupt="$TMP_WORK/corrupt.txt"
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

  # Orphaned checksums: checksums that don't have corresponding artifacts in /dist
  local orphaned_checksums="$TMP_WORK/orphaned_checksums.txt"
  : > "$orphaned_checksums"

  if [[ -f "$remote_checksums" ]]; then
    while IFS= read -r checksum_key; do
      [[ -z "$checksum_key" ]] && continue
      # Check if corresponding artifact exists in dist list
      if ! grep -qxF "$checksum_key" "$dist_list" 2>/dev/null; then
        printf '%s\n' "$checksum_key" >> "$orphaned_checksums"
      fi
    done < "$remote_checksums"
  fi

  # Orphaned artifacts: artifacts in /dist that don't have checksums in /.checksums
  local orphaned_artifacts="$TMP_WORK/orphaned_artifacts.txt"
  : > "$orphaned_artifacts"

  if [[ -f "$dist_list" ]]; then
    while IFS= read -r artifact_key; do
      [[ -z "$artifact_key" ]] && continue
      # Check if corresponding checksum exists in remote list
      if ! grep -qxF "$artifact_key" "$remote_checksums" 2>/dev/null; then
        printf '%s\n' "$artifact_key" >> "$orphaned_artifacts"
      fi
    done < "$dist_list"
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

# ---------- step 6: download artifact, compute SHA1 (executed per item in real run)
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
  local batch_file="$TMP_WORK/batch.$$"
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
    printf '%s' "$sha" > "$local_sha"

    if retry3 bash -c 'printf "%s" "$0" | aws s3 cp - "s3://'"$S3_BUCKET"'/.checksums/'"$key"'.sha1" --content-type "text/plain" "'"$AWS_ENDPOINT_ARG1"'" "'"$AWS_ENDPOINT_ARG2"'" >/dev/null 2>&1' "$sha"; then
      printf 'OK|%s|%s\n' "$key" "$action" >> "$report_pipe"
    else
      printf 'FAILED|%s|%s\n' "$key" "$action" >> "$report_pipe"
    fi
  done < "$batch_file"

  rm -f "$batch_file" || true
  return 0
}

# ---------- step 4 & 5: create internal list and present to user (planning + execution)
process_plan() {
  local valid="$1" missing="$2" empty="$3" corrupt="$4"
  local orphan_info="$5"
  local report="$TMP_WORK/report.json"

  # step 4: create single internal list (combining missing + empty + corrupt)
  local already_valid missing_count empty_count corrupt_count total_to_process
  already_valid=$(wc -l < "$valid" 2>/dev/null | tr -d ' ' || echo 0)
  missing_count=$(wc -l < "$missing" 2>/dev/null | tr -d ' ' || echo 0)
  empty_count=$(wc -l < "$empty" 2>/dev/null | tr -d ' ' || echo 0)
  corrupt_count=$(wc -l < "$corrupt" 2>/dev/null | tr -d ' ' || echo 0)
  total_to_process=$(( missing_count + empty_count + corrupt_count ))

  # step 5: present complete list to user *before* downloading any large artifacts
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

  # step 6: real execution - now download and process artifacts
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
