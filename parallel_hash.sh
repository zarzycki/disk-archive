#!/bin/bash

# --- Parse arguments ---
DIR=${1:-.}
TOOL=${2:-xxhsum}
VOL_NAME=$(basename "$DIR")
OUTFILE=${3:-hashes_${VOL_NAME}.txt}
JOBS=${4:-4}
ERROR_LOG="hash_errors.log"

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

TOTAL=$(find "$DIR" \( -path '*/.*' -prune \) -o -type f -size +1k -print | wc -l | tr -d ' ')
echo "Total files: $TOTAL"

# --- Save directory tree (optional preview of contents) ---
TREE_OUT=./tree_${VOL_NAME}.txt

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
  if grep -q '^MD5 (' "$OUTFILE"; then
    # macOS md5 format
    grep '^MD5 (' "$OUTFILE" | sed -E 's/^MD5 \((.+)\) =.*/\1/' >> "$HASHED_TMP"
  else
    # Generic format: assume path is second column
    awk '{print $2}' "$OUTFILE" >> "$HASHED_TMP"
  fi
  sort -u "$HASHED_TMP" -o "$HASHED_TMP"
  echo "$(wc -l < "$HASHED_TMP") file(s) already hashed — will be skipped."
else
  echo "Hash file does not exist. All files will be hashed."
fi

# --- Create temp files and lock file ---

# Create a temporary file to store the count of successfully hashed files
COUNTER=$(mktemp)
# Create a temporary file to store the count of failed hash attempts
FAILED=$(mktemp)
# Create a temporary file to use as a lock for synchronizing access to COUNTER and FAILED
LOCK=$(mktemp)
# Create a temporary file to store the count of skipped files
SKIPPED=$(mktemp)
# Initialize the COUNTER file with 0 (no files processed yet)
echo 0 > "$COUNTER"
# Initialize the FAILED file with 0 (no failures yet)
echo 0 > "$FAILED"
# Initialize with 0
echo 0 > "$SKIPPED"
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

    if grep -Fxq "$FILE" "$HASHED_TMP"; then
        # Increment both skipped and total processed counters
        flock "$LOCK" bash -c "
            echo \$((\$(<\"$SKIPPED\") + 1)) > \"$SKIPPED\"
            echo \$((\$(<\"$COUNTER\") + 1)) > \"$COUNTER\"
        "
    else
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
    fi

    # Always print progress, no matter if skipped, failed, or succeeded
    COUNT=$(<"$COUNTER")
    FAIL=$(<"$FAILED")
    printf "\rProcessed: %d of %d (Failed: %d)" "$COUNT" "$TOTAL" "$FAIL" >&2
}


export -f hash_and_count
export COUNTER FAILED SKIPPED LOCK TOOL OUTFILE TOTAL ERROR_LOG
export HASHED_TMP

# --- Time the hashing ---
START_TIME=$(date +%s)

# Find all non-hidden files >1KB and hash them in parallel using xargs and hash_and_count
find "$DIR" \( -path '*/.*' -prune \) -o -type f -size +1k -print0 | xargs -0 -n 1 -P "$JOBS" bash -c 'hash_and_count "$1"' _

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\nDone in $DURATION seconds."
echo "Successful: $(<"$COUNTER")"
echo "Failed:     $(<"$FAILED")"
echo "Skipped:    $(<"$SKIPPED")"
echo "Results saved to: $OUTFILE"
echo "Errors logged to: $ERROR_LOG"

echo "Sorting output..."
sort "$OUTFILE" -o "$OUTFILE"

rm "$COUNTER" "$FAILED" "$SKIPPED" "$LOCK" "$HASHED_TMP"