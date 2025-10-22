# S3 Checksum Generator (scripts/s3-generate-checksums.sh)

Ensure every object under a prefix (default: `dist/`) has a SHA1 saved at `.checksums/<key>.sha1` in the same
S3-compatible bucket. Safe to run repeatedly; only missing/empty/corrupt checksums are generated or fixed.

**Why/when:** keep release artifacts verifiable without touching existing data. No deletions are performed.

---

### Requirements

- bash
- AWS CLI v2 (`aws`)
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
    - `PREFIX` (default: `dist/`)
    - `DRY_RUN` (default: `0`) — plan only when `1` (no artifact downloads)
    - `TMP_WORK` (default: `<project>/temp`)

-----

### Quick start

- Dry run (plan only):

```bash
DRY_RUN=1 ./scripts/s3-generate-checksums.sh
```

- Real run (generate/update checksums):

```bash
PREFIX="dist/" ./scripts/s3-generate-checksums.sh
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
