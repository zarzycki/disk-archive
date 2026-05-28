#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 /Volumes/VOLUME_NAME"
  exit 1
fi

VOLPATH="$1"

if [ ! -d "$VOLPATH" ]; then
  echo "ERROR: $VOLPATH does not exist or is not a directory."
  exit 1
fi

echo ">>> Checking Spotlight indexing status for: $VOLPATH"
mdutil -s "$VOLPATH" || true

echo ">>> Turning off Spotlight indexing..."
sudo mdutil -i off "$VOLPATH"

echo ">>> Creating .metadata_never_index to permanently disable Spotlight"
sudo touch "$VOLPATH/.metadata_never_index"

echo ">>> Removing Spotlight and macOS metadata directories..."
cd "$VOLPATH"

# Delete known Spotlight / metadata directories safely
for ITEM in .DS_Store .DocumentRevisions-V100 .Spotlight-V100 .TemporaryItems .Trashes .fseventsd; do
  if [ -e "$ITEM" ]; then
    echo "Removing $ITEM ..."
    sudo rm -rfv "$ITEM"
  else
    echo "Skipping $ITEM (not present)"
  fi
done

echo ">>> Done. Spotlight disabled for $VOLPATH."

