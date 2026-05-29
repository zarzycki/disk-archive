#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 /Volumes/DISK_NAME [--outdir DIR] [--jobs N]"
  echo "  --outdir  Where to write hashes/tree/html files (default: current directory)"
  echo "  --jobs    Parallel hash jobs (default: 4)"
  exit 1
}

if [[ $# -lt 1 ]]; then usage; fi

VOLPATH="$1"
shift

OUTDIR="$(pwd)"
JOBS=4

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir) OUTDIR="$2"; shift 2 ;;
    --jobs)   JOBS="$2";   shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [[ ! -d "$VOLPATH" ]]; then
  echo "ERROR: '$VOLPATH' does not exist or is not a directory." >&2
  exit 1
fi

if [[ ! -d "$OUTDIR" ]]; then
  echo "ERROR: --outdir '$OUTDIR' does not exist." >&2
  exit 1
fi

VOL_NAME=$(basename "$VOLPATH")
TREE_FILE="${OUTDIR}/tree_${VOL_NAME}.txt"

echo "========================================"
echo "  archive_disk: $VOL_NAME"
echo "  volume : $VOLPATH"
echo "  outdir : $OUTDIR"
echo "  jobs   : $JOBS"
echo "========================================"

# Step 1: disable Spotlight
echo ""
echo ">>> [1/3] Disabling Spotlight on $VOLPATH"
echo "    (sudo calls may prompt for your password)"
"$SCRIPT_DIR/turn_off_spotlight.sh" "$VOLPATH"

# Step 2: hash all files
echo ""
echo ">>> [2/3] Hashing files in $VOLPATH"
"$SCRIPT_DIR/parallel_hash.sh" "$VOLPATH" --outdir "$OUTDIR" --jobs "$JOBS"

# Step 3: build HTML viewer from the tree file parallel_hash produced
echo ""
echo ">>> [3/3] Building HTML viewer from $TREE_FILE"
python3 "$SCRIPT_DIR/tree_to_html.py" "$TREE_FILE"

echo ""
echo "========================================"
echo "  Done."
echo "  Hashes : ${OUTDIR}/hashes_${VOL_NAME}.txt"
echo "  Tree   : $TREE_FILE"
echo "  HTML   : ${OUTDIR}/html_${VOL_NAME}.html"
echo "========================================"
