# S3 Checksum Generator (scripts/s3-checksums.sh)

Ensure every object under a prefix (default: `dist/`) has a SHA1 saved at `.checksums/<key>.sha1` in the same
S3-compatible bucket. Safe to run repeatedly; only missing/empty/corrupt checksums are generated or fixed.

**Why/when:** keep release artifacts verifiable without touching existing data. No deletions are performed.

---

### Requirements

- bash
- AWS CLI v2 (`aws`)
- rclone (optional; used when `S3C_USE_RCLONE=1`)
- `shasum` (or `openssl` as fallback)
- `awk`, `sed`, `wc`, `tr`, `grep`, `mktemp`

-----

### Environment variables

- **Required:**
    - `S3_BUCKET` (e.g., `satis-moodle`)
    - `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`
    - `S3_REGION` (e.g., `auto` for R2)
    - `S3_ENDPOINT` (e.g., `https://<account>.r2.cloudflarestorage.com`)
    - `S3_USE_PATH_STYLE_ENDPOINT` = `true` or `false` (lowercase). For Cloudflare R2 use `true`.
- **Optional:**
    - `S3C_ROOTDIR` (default: `<project>/temp`)
    - `S3C_PREFIX` (default: `dist/`)
    - `S3C_CHECK_ORPHANS` (default: `0`) — when `1`, enables detection/report of orphaned files (slower)
    - `S3C_DEBUG` (default: `0`) — when `1`, runs a diagnostic that compares the first N local vs remote `.sha1` files
      and checks whether `aws s3 sync` would re-download them using three modes: default, `--size-only`, and
      `--exact-timestamps`. If `S3C_DEBUG_RCLONE=1` and `rclone` is available, it also tests rclone checksum decisions
      using `rclone sync --checksum --dry-run`. It prints a compact table to the console (useful in CI logs) and writes
      `temp/debug-compare.txt` and `temp/debug-compare.json`.
      - Note: the table's `EQUAL` column compares RAW BYTES of the `.sha1` files (no trimming). The JSON adds
        `equal_ign_whitespace` for a whitespace‑insensitive view (helpful to spot newline‑only differences).
    - `S3C_DEBUG_LIMIT` (default: `30`) — how many files to test when `S3C_DEBUG=1`.
    - `S3C_DEBUG_RCLONE` (default: `1`) — when `1` and `rclone` is available, include rclone dry-run decisions in debug
      (column `RCL(chk)` = rclone sync with `--checksum`).
    - `S3C_SYNC_MODE` (default: `mtime`) — AWS CLI fallback strategy to sync existing `.sha1` files locally:
        - `size-only`: fastest; skips re-download when size is the same (ignores timestamps). Beware: if a remote
          checksum changes but remains 40 bytes, it may not re-download.
        - `mtime`: compares LastModified; downloads when the remote object is newer.
        - `mtime-exact`: compares exact timestamps; downloads whenever size differs or timestamp differs.
    - `DRY_RUN` (default: `0`) — plan only when `1` (no artifact downloads)
    - `S3C_USE_RCLONE` (default: `0`) — when `1`, uses rclone to fetch existing `.sha1` files via `rclone sync --checksum`.
      Requires `rclone` in PATH.
    - `S3C_RCLONE_TRANSFERS` (default: `8`) — number of parallel file transfers when using rclone.
    - `S3C_RCLONE_CHECKERS` (default: `16`) — number of parallel checks when using rclone.
    - `S3C_RCLONE_ARGS` — extra flags passed to rclone (e.g., `--fast-list`, `--low-level-retries 2`).

> Note on rclone behavior: when enabled, the script uses `rclone sync --checksum` with filters to only process `*.sha1`
> under the selected prefix. This ignores timestamps and compares content by checksum (ETag/MD5 on S3 for small objects),
> ensuring correctness while remaining cache-friendly. If rclone is disabled or not installed, the script falls back to
> the AWS CLI path as configured by `S3C_SYNC_MODE`. 

-----

### Quick start

- Dry run (plan only):

```bash
DRY_RUN=1 ./scripts/s3-checksums.sh
```

- Real run (generate/update checksums):

```bash
S3C_PREFIX="dist/" ./scripts/s3-checksums.sh
```

- Enable orphan checks (optional and slower):

```bash
S3C_CHECK_ORPHANS=1 ./scripts/s3-checksums.sh
```

- Use exact timestamps during checksum sync (ensure local cache matches remote mtime):

```bash
S3C_SYNC_MODE=mtime-exact ./scripts/s3-checksums.sh
```

- Use rclone to fetch existing `.sha1` files with checksum verification (fast and correct):
```bash
S3C_USE_RCLONE=1 S3C_RCLONE_TRANSFERS=16 S3C_RCLONE_CHECKERS=32 ./scripts/s3-checksums.sh
# Optional: extra flags
S3C_USE_RCLONE=1 S3C_RCLONE_ARGS="--fast-list --low-level-retries 2" ./scripts/s3-checksums.sh
```

-----

### Cloudflare R2 note

- Set `S3_USE_PATH_STYLE_ENDPOINT=true` and provide the R2 endpoint in `S3_ENDPOINT`.

-----

### Output

- Prints a short summary and writes `<project>/temp/report.json` (kept for auditing).

-----

### How it works

1. **List remote checksums:** First lists all `.sha1` files that exist in the remote S3 bucket (e.g.,
   `/.checksums/dist/*/*.zip.sha1`) to build an authoritative inventory of what checksums currently exist in S3.
2. **Download checksums:** Downloads (syncs) all existing `.sha1` files from the checksums directory to local storage.
   This download operation is batched for efficiency.
3. **List target artifacts:** Downloads the list of all target artifacts from the specified prefix, considering **only**
   exact suffixes: `.zip` and `.tar` (e.g., `/dist/*/*.zip`).
4. **Double verification:** Compares the artifact list against checksums using **two validation layers**:
    - **Remote validation:** Checks if the `.sha1` file exists in the remote S3 list (from step 1). This catches cases
      where a checksum was deleted from S3 but still exists locally.
    - **Local validation:** Verifies the locally synced `.sha1` file exists and validates its content.

   An artifact is marked for processing if its `.sha1` file is:
    - **Missing:** The `.sha1` file does not exist in remote S3, OR the local file is missing after sync.
    - **Empty:** The `.sha1` file is 0 bytes or contains the SHA1 of an empty string:
      `da39a3ee5e6b4b0d3255bfef95601890afd80709`.
    - **Corrupt:** The `.sha1` file content is not exactly 40 hexadecimal characters (case-insensitive).
5. **Create processing list:** Creates a single internal list combining all artifacts that require processing (missing +
   empty + corrupt).
6. **Present plan:** Presents this complete list to the user *before* downloading any large artifacts, showing counts
   for each category.
7. **Execute (if not DRY_RUN):** If not in `DRY_RUN` mode, the script iterates through the processing list: it
   downloads each artifact, computes the SHA1, and uploads the new `.sha1` file to S3 (overwriting the old one if it
   existed).
8. **Retry logic:** All S3 operations are retried up to 3 times with exponential backoff (1s, 2s, 4s) to handle
   transient failures.
9. **Preserve audit trail:** No data is deleted; the temp directory is preserved for auditing purposes.
