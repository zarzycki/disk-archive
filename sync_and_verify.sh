#!/bin/bash

# This script syncs a source directory to a destination using rsync, then
# verifies the transfer by comparing MD5 checksums of all files. If the
# directories are identical, it prints (but does not execute) an rm command
# to remove the source. Checksum files are written to the current working
# directory.
#
# Usage:
# ./sync_and_verify.sh <SRC> <DEST> [TOOL]
#
# Arguments:
# - <SRC>  : Source directory to sync from
# - <DEST> : Destination directory to sync to
# - [TOOL] : Hash tool to use (default: xxhsum). Use xxhsum, md5, md5sum, sha256sum, etc.
#
# Outputs:
# - SRC_checksums.txt  : MD5 hashes of all files in SRC
# - DEST_checksums.txt : MD5 hashes of all files in DEST
#
# Example Invocation:
# ./sync_and_verify.sh /Volumes/3KM_DOWNSCALING/jpan/ /Volumes/ERASED
#
# Note:
# - Requires rsync and the macOS md5 utility (standard on macOS).
# - The rm command that would delete the source is commented out for safety;
#   uncomment it in the script once you are confident the transfer is correct.
# - Checksum cleanup lines are also commented out; remove them manually after
#   confirming results.

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "Usage: $0 <SRC> <DEST> [TOOL]"
  exit 1
fi

SRC="$1"
DEST="$2"
TOOL="${3:-xxhsum}"

if ! command -v "$TOOL" >/dev/null 2>&1; then
  echo "Error: hash tool '$TOOL' is not installed or not in PATH." >&2
  echo "Install xxhsum with: brew install xxhash" >&2
  exit 1
fi

# Sync directories
rsync -av --progress --stats "$SRC/" "$DEST/"

# Generate checksums in the source directory
# $2=root dir, $3=tool; xxhsum/md5sum/sha256sum output hash as first field; md5 (macOS) needs -q for hash-only output
find "$SRC" -type f -exec sh -c '
    rel="${1#$2/}"
    if [ "$3" = "md5" ]; then hash=$(md5 -q "$1"); else hash=$("$3" "$1" | awk "{print \$1}"); fi
    echo "$hash  $rel"
' _ {} "$SRC" "$TOOL" \; > "SRC_checksums.txt"

# Generate checksums in the destination directory
find "$DEST" -type f -exec sh -c '
    rel="${1#$2/}"
    if [ "$3" = "md5" ]; then hash=$(md5 -q "$1"); else hash=$("$3" "$1" | awk "{print \$1}"); fi
    echo "$hash  $rel"
' _ {} "$DEST" "$TOOL" \; > "DEST_checksums.txt"

# Compare checksum files
if [ $(diff "SRC_checksums.txt" "DEST_checksums.txt" | wc -l) -eq 0 ]; then
  echo "Directories are identical. Deleting source directory."
  echo "rm -rfv $SRC"
  #rm -rfv "$SRC"
else
  echo "Directories differ! Aborting deletion."
  diff "SRC_checksums.txt" "DEST_checksums.txt"
fi

# Remove files?
#rm -v "SRC_checksums.txt"
#rm -v "DEST_checksums.txt"