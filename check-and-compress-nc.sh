#!/bin/bash

# This script compresses NetCDF files in a specified directory using ncks,
# targeting files that do not conform to a list of accepted NetCDF formats.
# It reports file sizes before and after compression and tracks progress.
#
# Accepted formats:
# - netCDF-4
# - netCDF-4 classic model
# - cdf5
# - hdf5
#
# Usage:
# ./compress_nc_files.sh <directory_path>
#
# Arguments:
# - <directory_path>: Path to the directory containing NetCDF files to compress.
#
# Example Invocation:
# To run this script on a directory called "/VOLUMES/Archived_NC/" on a Mac:
# ./compress_nc_files.sh /VOLUMES/Archived_NC/
#
# Note:
# - Ensure `nco` (NetCDF Operators) is installed (`brew install nco`).
# - `gstat` is used for file size in bytes. On macOS, use `stat` instead.
# - Make the script executable if necessary: `chmod +x compress_nc_files.sh`.

DRY_RUN=false
if [[ "$1" == "-n" || "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

STAGE_ROOT="/private/var/tmp/nco_stage"
mkdir -p "$STAGE_ROOT"

trap 'rm -f "$STAGE_ROOT"/*.tmp' EXIT
trap 'exit 130' INT TERM

# Keep temp I/O local & avoid HDF5 file locks on externals
export TMPDIR="/private/var/tmp"
export HDF5_USE_FILE_LOCKING=FALSE

nc_compress() {
    local file=$1

    if [[ ! -e "$file" ]]; then
        echo "File does not exist: $file"
        return 1
    fi

    # Sizes (macOS: stat -f%z ; GNU: gstat -c%s). Use stat by default:
    local before_size_human
    before_size_human=$(ls -lh "$file" | awk '{print $5}')
    local before_size_bytes
    before_size_bytes=$(stat -f%z "$file" 2>/dev/null || gstat -c%s "$file")

    # Derive names/paths
    local base staged_tmp ext_new
    base="$(basename "$file")"
    staged_tmp="$STAGE_ROOT/${base}.tmp"     # internal SSD temp file
    ext_new="${file}.new"                    # external staging name

    # === WRITE INTERNALLY ===
    # Read from external "$file", write to internal "$staged_tmp"
    ncks -O -4 -L 1 \
         "$file" "$staged_tmp" || { echo "ncks failed for $file"; return 1; }

    sync; sleep 0.2

    # === ONE CLEAN WRITE BACK TO EXTERNAL ===
    # Copy staged file to the external as .new (so readers never see partial)
    # Tip: If your dock is touchy, throttle with --bwlimit (KB/s), e.g. 30000 = ~30 MB/s
    rsync -ah --progress --bwlimit=30000 "$staged_tmp" "$ext_new" || { echo "rsync failed for $file"; return 1; }

    # Atomic rename on external volume
    mv -f "$ext_new" "$file" || { echo "rename failed for $file"; return 1; }

    # Remove the internal staged file
    rm -vf -- "$staged_tmp"

    # Post sizes
    local after_size_human
    after_size_human=$(ls -lh "$file" | awk '{print $5}')
    local after_size_bytes
    after_size_bytes=$(stat -f%z "$file" 2>/dev/null || gstat -c%s "$file")

    local compression_ratio="NA"
    if [[ "$after_size_bytes" -gt 0 ]]; then
        compression_ratio=$(echo "scale=2; $before_size_bytes / $after_size_bytes" | bc)
    fi

    echo "compress_nc: $file before: $before_size_human  after: $after_size_human  ratio: $compression_ratio"
}

DIR=$1

# Define an array of accepted values
ACCEPTED_VALS=("netCDF-4" "netCDF-4 classic model" "cdf5" "hdf5")

# Helper: exact membership test (avoid substring/regex pitfalls)
is_accepted() {
    local fmt=$1
    for v in "${ACCEPTED_VALS[@]}"; do
        [[ "$fmt" == "$v" ]] && return 0
    done
    return 1
}

# Collect all .nc files once
nc_files=()
while IFS= read -r -d '' f; do
    nc_files+=("$f")
done < <(find "$DIR" -type f -name '*.nc' -print0)
total_files=${#nc_files[@]}

du -skh "$DIR"

# Initialize a counter for progress tracking
counter=1

for file in "${nc_files[@]}"; do
    # Print the counter every 10 files
    if (( counter % 10 == 0 )); then
        echo "Processing file $counter of $total_files"
    fi

    # Get the file format using ncdump
    format=$(ncdump -k "$file")
    echo "$file: $format"

    # Check if the format is not in the accepted values and report if not
    if ! is_accepted "$format"; then
        if $DRY_RUN; then
            echo "would compress: $file (format: $format)"
        else
            echo "File $file has a non-accepted format: $format"
            nc_compress "$file"
        fi
    fi

    # Increment the counter
    ((counter++))
done

# Print the final count if not a multiple of 100
if (( (counter - 1) % 10 != 0 )); then
    echo "Processed $((counter - 1)) files."
fi

du -skh $DIR

