#!/bin/bash

# --- Parse arguments ---
DIR=${1:-.}
shift
TOOL=xxhsum
JOBS=4
OUTDIR=.
OUTFILE=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool)    TOOL="$2";    shift 2 ;;
    --outfile) OUTFILE="$2"; shift 2 ;;
    --jobs)    JOBS="$2";    shift 2 ;;
    --outdir)  OUTDIR="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$OUTDIR" ]]; then
  echo "Error: --outdir '$OUTDIR' does not exist." >&2
  exit 1
fi

VOL_NAME=$(basename "$DIR")
OUTFILE=${OUTFILE:-${OUTDIR}/hashes_${VOL_NAME}.txt}
ERROR_LOG="${OUTDIR}/hash_errors.log"

echo "Scanning directory: $DIR"
echo "Hashing tool: $TOOL"
echo "Output file: $OUTFILE"
echo "Parallel jobs: $JOBS"

# --- Dependency checks ---
REQUIRED_CMDS=("find" "xargs" "stat" "$TOOL")

if ! command -v flock >/dev/null 2>&1; then
  echo "Error: 'flock' is required but not found. Install via 'brew install flock'." >&2
  exit 1
fi

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Required tool '$cmd' is not installed or not in PATH." >&2
    exit 1
  fi
done

# --- Figure out total files ---

# Sorted so ALL_FILES_TMP can be used with comm (which requires sorted inputs)
ALL_FILES_TMP=$(mktemp)
find "$DIR" \( -path '*/.*' -prune \) -o -type f -size +1k -print | sort > "$ALL_FILES_TMP"
TOTAL=$(wc -l < "$ALL_FILES_TMP" | tr -d ' ')
echo "Total files: $TOTAL"

# --- Save directory tree (optional preview of contents) ---
TREE_OUT="${OUTDIR}/tree_${VOL_NAME}.txt"

echo "Saving directory tree to $TREE_OUT ..."
if [[ -f "$TREE_OUT" ]]; then
  echo "Tree already exists."
  mv "$TREE_OUT" "${TREE_OUT}.tmp"
  tree -f -s -D "$DIR" | sed "s|$DIR/||" > "$TREE_OUT"
  echo "Diff from previous tree:"
  diff -w "${TREE_OUT}.tmp" "$TREE_OUT"
  rm -v "${TREE_OUT}.tmp"
else
  echo "Tree does not exist."
  tree -f -s -D "$DIR" | sed "s|$DIR/||" > "$TREE_OUT"
fi

# --- Build list of already hashed files ---
HASHED_TMP=$(mktemp)

if [[ -f "$OUTFILE" ]]; then
  echo "Hash file exists: $OUTFILE. Loading already-hashed files to skip..."
  MD5_FORMAT=false
  if grep -q '^MD5 (' "$OUTFILE"; then
    MD5_FORMAT=true
    echo "Warning: $OUTFILE is in legacy MD5 format. Stale entry removal will be skipped. Re-run from scratch to migrate to xxhsum." >&2
    grep '^MD5 (' "$OUTFILE" | sed -E 's/^MD5 \((.+)\) =.*/\1/' >> "$HASHED_TMP"
  else
    # Extract path using " | size: " as delimiter to handle filenames with spaces
    sed 's/^[^ ]*  //; s/ | size: .*$//' "$OUTFILE" >> "$HASHED_TMP"
  fi
  sort -u "$HASHED_TMP" -o "$HASHED_TMP"
  echo "$(wc -l < "$HASHED_TMP") file(s) already hashed — will be skipped."

  # Remove stale entries: files recorded in a previous run but since deleted from disk
  # comm -23: keep only lines unique to HASHED_TMP (i.e., not on disk anymore)
  STALE_TMP=$(mktemp)
  comm -23 "$HASHED_TMP" "$ALL_FILES_TMP" > "$STALE_TMP"
  STALE_COUNT=$(wc -l < "$STALE_TMP" | tr -d ' ')
  if [[ "$STALE_COUNT" -gt 0 ]]; then
    if [[ "$MD5_FORMAT" == true ]]; then
      echo "Warning: $STALE_COUNT stale entry/entries detected but removal skipped for legacy MD5-format file." >&2
    else
      echo "$STALE_COUNT stale entry/entries found (deleted from disk) — removing from $OUTFILE..."
      cat "$STALE_TMP"
      # Use a temp file beside OUTFILE to avoid cross-filesystem mv failures (e.g. OneDrive)
      CLEANED=$(mktemp "$(dirname "$OUTFILE")/.cleaned.XXXXXX")
      # Extract full path via delimiter (not $2) to handle filenames with spaces
      awk 'NR==FNR{stale[$0]=1; next} {path=$0; sub(/^[^ ]+  /, "", path); sub(/ \| size: .*$/, "", path); if (!(path in stale)) print}' "$STALE_TMP" "$OUTFILE" > "$CLEANED"
      mv "$CLEANED" "$OUTFILE" || { echo "Error: failed to update $OUTFILE" >&2; rm -f "$CLEANED"; }
    fi
  else
    echo "No stale entries found."
  fi
  rm -f "$STALE_TMP"
else
  echo "Hash file does not exist. All files will be hashed."
fi

# --- Compute files to hash this run ---
# comm -23: keep only lines unique to ALL_FILES_TMP (i.e., not yet hashed)
TO_HASH_TMP=$(mktemp)
comm -23 "$ALL_FILES_TMP" "$HASHED_TMP" > "$TO_HASH_TMP"
rm -f "$ALL_FILES_TMP" "$HASHED_TMP"
TO_HASH_COUNT=$(wc -l < "$TO_HASH_TMP" | tr -d ' ')
SKIP_COUNT=$(( TOTAL - TO_HASH_COUNT ))
TOTAL=$TO_HASH_COUNT
echo "Files to hash: $TOTAL (skipping $SKIP_COUNT already hashed)"

# --- Create temp files and lock file ---

# Create a temporary file to store the count of successfully hashed files
COUNTER=$(mktemp)
# Create a temporary file to store the count of failed hash attempts
FAILED=$(mktemp)
# Create a temporary file to use as a lock for synchronizing access to COUNTER and FAILED
LOCK=$(mktemp)
# Initialize the COUNTER file with 0 (no files processed yet)
echo 0 > "$COUNTER"
# Initialize the FAILED file with 0 (no failures yet)
echo 0 > "$FAILED"
# Truncate (or create) the error log file to start fresh
if [[ ! -f "$ERROR_LOG" ]]; then
  > "$ERROR_LOG"
fi
# Truncate (or create) the output file to store hash results
if [[ ! -f "$OUTFILE" ]]; then
  > "$OUTFILE"
fi


# --- Hashing function ---
# This function is called once per file (in parallel) to:
#   1. Hash the file using the specified tool (e.g., md5, sha256sum).
#   2. Record the file size and modification timestamp (BSD-compatible stat).
#   3. Append the results to the output file in a human-readable format.
#   4. Use a file lock (via `flock`) to safely increment a global counter
#      tracking success and failure across parallel jobs.
#   5. On failure, increment the failure counter and log the filename to
#      the error log.
#   6. Print real-time progress to stderr showing number processed and failed.
#
# Note:
#   - This function is exported and executed in parallel by `xargs`.
#   - It relies on global environment variables: $TOOL, $COUNTER, $FAILED,
#     $LOCK, $OUTFILE, $TOTAL, $ERROR_LOG.
# -----------------------------------------------------------------------------
hash_and_count() {
    FILE="$1"

    # Run the hash tool on the file, capture output if successful, log errors if not
    if HASH=$("$TOOL" "$FILE" 2>> "$ERROR_LOG"); then
        SIZE=$(stat -f%z "$FILE" 2>/dev/null)
        MODIFIED=$(stat -f"%Sm" -t "%Y-%m-%d %H:%M:%S" "$FILE" 2>/dev/null)

        echo "$HASH | size: ${SIZE:-N/A} bytes | modified: ${MODIFIED:-N/A}" >> "$OUTFILE"

        flock "$LOCK" bash -c "echo \$((\$(<\"$COUNTER\") + 1)) > \"$COUNTER\""
    else
        flock "$LOCK" bash -c "echo \$((\$(<\"$FAILED\") + 1)) > \"$FAILED\""
        echo "FAILED: $FILE" >> "$ERROR_LOG"
    fi

    COUNT=$(<"$COUNTER")
    FAIL=$(<"$FAILED")
    printf "\rProcessed: %d of %d (Failed: %d)" "$COUNT" "$TOTAL" "$FAIL" >&2
}


export -f hash_and_count
export COUNTER FAILED LOCK TOOL OUTFILE TOTAL ERROR_LOG

# --- Time the hashing ---
START_TIME=$(date +%s)

# Feed only unhashed files to the parallel workers
tr '\n' '\0' < "$TO_HASH_TMP" | xargs -0 -n 1 -P "$JOBS" bash -c 'hash_and_count "$1"' _

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\nDone in $DURATION seconds."
echo "Successful: $(<"$COUNTER")"
echo "Failed:     $(<"$FAILED")"
echo "Skipped:    $SKIP_COUNT"
echo "Results saved to: $OUTFILE"
echo "Errors logged to: $ERROR_LOG"

echo "Sorting output..."
sort "$OUTFILE" -o "$OUTFILE"

rm "$COUNTER" "$FAILED" "$LOCK" "$TO_HASH_TMP"