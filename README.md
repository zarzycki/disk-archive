# Scripts

Set of scripts for maintaining external MEWAC hard drives. General order is:

- `turn_off_spotlight.sh` -  If needed (new drive), turn off Mac Spotlight.
- `check-and-compress-nc.sh` - If needed, compress .nc files
- `parallel_hash.sh` - Create tree, hash, and disk summary files.
- `tree_to_html.py` - Convert a tree file into an interactive HTML viewer.
- `plot_disk_usage.py` - Visualize free/used space across all drives as a bar chart.
- `archive_disk.sh` - Master driver: runs spotlight, hashing, and HTML generation in one shot.

## Python environment

`plot_disk_usage.py` requires `matplotlib` and `numpy`. Create a dedicated conda environment with:

```bash
conda create -n disk-archive python=3.11 numpy matplotlib
conda activate disk-archive
```

Then run `archive_disk.sh` from a terminal where this environment is active.

## parallel_hash.sh

A Bash script that recursively hashes files in a directory in parallel, with resume support for interrupted runs.

### Usage

```bash
./parallel_hash.sh [DIR] [--tool TOOL] [--outfile OUTFILE] [--jobs JOBS] [--outdir OUTDIR]
```

| Argument | Default | Description |
|---|---|---|
| `DIR` | `.` | Directory to scan (positional, not a flag) |
| `--tool` | `xxhsum` | Hash tool to use (e.g. `xxhsum`, `md5`, `sha256sum`) |
| `--outfile` | `hashes_<dirname>.txt` | Path to write hash results to |
| `--jobs` | `4` | Number of parallel workers |
| `--outdir` | `.` | Directory for all output files (`hashes_*.txt`, `tree_*.txt`, `hash_errors.log`); must already exist |

### Dependencies

- `flock` — install with `brew install flock` (this locks files during commands)
- `tree` — install with `brew install tree`
- `find`, `xargs`, `stat` — standard on macOS/Linux
- Your chosen hash tool (`xxhsum` is the default — install with `brew install xxhash`; `md5` is built into macOS)

### Output

Each line in the output file has the format:

```
<hash>  path/to/file | size: 12345 bytes | modified: 2026-01-01 12:00:00
```

The output file is sorted alphabetically when the run completes (for later lookup and deduplication).

A directory tree snapshot is saved to `tree_<dirname>.txt` in the output directory (`--outdir`, defaults to current directory).

A one-line disk summary is saved to `disk_<dirname>.txt` with the format:

```
DISKNAME | total: 16.0T | used: 15.3T | free: 680.0G
```

Errors and failed files are logged to `hash_errors.log`. This should generally be an empty file.

### Resume Support

If the output file already exists from a previous run, the script parses it to find already-hashed files and skips them. This allows interrupted runs to be resumed without re-hashing completed files.

### Examples

```bash
# Hash all files in /Volumes/MyDrive using sha256sum, 8 workers
./parallel_hash.sh /Volumes/MyDrive --tool sha256sum --jobs 8
```

```bash
# Hash all files in /Volumes/DRIVE/
# Produces: hashes_DRIVE.txt (hash results) and tree_DRIVE.txt (directory tree)
./parallel_hash.sh /Volumes/DRIVE/
```

```bash
# Write all output files to a separate folder
./parallel_hash.sh /Volumes/DRIVE/ --outdir /Volumes/Backup/hashes
```

## check-and-compress-nc.sh

A Bash script that scans a directory for NetCDF files and compresses any that are not already in an accepted format, using a two-stage write strategy to avoid HDF5 file locking on external drives.

### Usage

```bash
./check-and-compress-nc.sh [-n | --dry-run] <directory_path>
```

| Argument | Description |
|---|---|
| `-n`, `--dry-run` | Print what would be compressed without modifying any files |
| `directory_path` | Path to the directory containing `.nc` files to scan |

### Accepted Formats

Files already in one of the following formats are left untouched:

- `netCDF-4`
- `netCDF-4 classic model`
- `cdf5`
- `hdf5`

Any file in a different format (e.g. classic `netCDF-3`) is recompressed to netCDF-4 with compression level 1 (`ncks -4 -L 1`).

### How It Works

1. Walks the directory with `find`, checking each `.nc` file's format via `ncdump -k`.
2. For files needing compression, writes the output to a temp file on internal SSD (`/private/var/tmp/nco_stage/`) to avoid locking issues on external drives.
3. `rsync`s the staged file back to the external drive as a `.new` sibling, then atomically renames it over the original.
4. Reports before/after file sizes and compression ratio for each processed file.
5. Prints a `du` summary of the directory before and after the run.

### Dependencies

- `nco` (NetCDF Operators) — install with `brew install nco` (provides `ncks` and `ncdump`)
- `rsync` — standard on macOS
- `stat` — standard on macOS (falls back to `gstat` on Linux)

### Examples

```bash
# Preview what would be compressed without touching any files
./check-and-compress-nc.sh --dry-run /Volumes/Archived_NC/
```

```bash
# Compress all non-accepted-format files in the directory
./check-and-compress-nc.sh /Volumes/Archived_NC/
```

## turn_off_spotlight.sh

A Bash script that disables macOS Spotlight indexing on a mounted volume and removes residual macOS metadata directories.

### Usage

```bash
sudo ./turn_off_spotlight.sh /Volumes/VOLUME_NAME
```

| Argument | Description |
|---|---|
| `VOLUME_NAME` | Full path to the mounted volume |

### What It Does

1. Reports the current Spotlight indexing status via `mdutil -s`.
2. Disables Spotlight indexing on the volume with `mdutil -i off`.
3. Creates a `.metadata_never_index` marker file to persistently suppress re-indexing.
4. Removes known macOS metadata directories: `.DS_Store`, `.DocumentRevisions-V100`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes`, `.fseventsd`.

### Dependencies

- `mdutil` — built into macOS (requires `sudo`)
- `rm`, `touch` — standard on macOS

### Notes

- Requires `sudo` for `mdutil` and for removing system-owned metadata directories.
- Safe to run on external drives (USB, Thunderbolt, network volumes).
- If the volume is formatted as FAT32 or exFAT, the `.metadata_never_index` marker file may not persist across remounts.

### Examples

```bash
sudo ./turn_off_spotlight.sh /Volumes/MyExternalDrive
```

## tree_to_html.py

A Python script that converts a `tree -s` directory snapshot into a self-contained, interactive HTML viewer with lazy rendering and filename search.

### Usage

```bash
python3 tree_to_html.py /path/to/tree_XXXXX.txt
```

The output file is named `html_XXXXX.html` and is always written to the same directory as the input file, regardless of where the script is invoked from.

| Argument | Description |
|---|---|
| `tree_XXXXX.txt` | Directory tree file produced by `parallel_hash.sh` |

### Dependencies

- Python 3 — standard on macOS

### Output

A single self-contained `.html` file that can be opened in any browser. The tree data is stored as JSON and rendered lazily — only expanded folders create DOM nodes, so the page loads quickly regardless of tree size.

### Features

- **Collapsible folders** — click any directory to expand or collapse it
- **Lazy rendering** — child nodes are created on demand when a folder is opened
- **Filename search** — type any substring to see a flat list of matching files with their full paths; supports `*` (any characters) and `?` (one character) wildcards (e.g. `*.nc`)
- **Expand all / Collapse all** buttons

### Examples

```bash
# Produces html_CPT01.html in the same folder as the input file
python3 tree_to_html.py /Volumes/Backup/hashes/tree_CPT01.txt
```

## plot_disk_usage.py

A Python script that reads all `disk_*.txt` files in a directory (produced by `parallel_hash.sh`) and renders a horizontal bar chart showing used and free space for each drive. Useful for quickly identifying which drives have room for new data.

### Usage

```bash
python3 plot_disk_usage.py <directory> [--out OUTPUT.png]
```

| Argument | Default | Description |
|---|---|---|
| `directory` | | Directory containing `disk_*.txt` files |
| `--out` | `all_disk_usage.png` in the input directory | Path to write the output image |

### Dependencies

- Python 3
- `matplotlib` — install with `pip install matplotlib` or `conda install matplotlib`

### Output

A PNG image with one horizontal bar per disk. Each bar shows used space (red) and free space (teal). The free space label is displayed prominently to the right of each bar since that is the key number when looking for a drive with capacity.

### Examples

```bash
# Read all disk_*.txt in the current directory, write all_disk_usage.png
python3 plot_disk_usage.py .

# Specify an output path
python3 plot_disk_usage.py ~/archives --out ~/Desktop/disk_report.png
```

## archive_disk.sh

A master driver script that runs the full archive pipeline for a single volume in one shot: disables Spotlight, hashes all files, and builds the HTML tree viewer.

### Usage

```bash
./archive_disk.sh /Volumes/DISK_NAME [--outdir DIR] [--jobs N]
```

| Argument | Default | Description |
|---|---|---|
| `/Volumes/DISK_NAME` | | Mounted volume to archive |
| `--outdir` | current directory | Where to write all output files |
| `--jobs` | `4` | Number of parallel hash workers |

### What It Does

1. Runs `turn_off_spotlight.sh` on the volume (will prompt for sudo password).
2. Runs `parallel_hash.sh`, producing `hashes_DISK.txt`, `tree_DISK.txt`, and `disk_DISK.txt`.
3. Runs `tree_to_html.py` on the resulting tree file, producing `html_DISK.html`.

### Examples

```bash
./archive_disk.sh /Volumes/CPT01
./archive_disk.sh /Volumes/CPT01 --outdir ~/archives --jobs 8
```

## sync_and_verify.sh

A Bash script that copies a source directory to a destination with `rsync`, then verifies the transfer by comparing checksums of every file. If the directories are identical, it prints (but does not execute) the command to remove the source.

### Usage

```bash
./sync_and_verify.sh <SRC> <DEST> [TOOL]
```

| Argument | Default | Description |
|---|---|---|
| `SRC` | | Source directory to sync from |
| `DEST` | | Destination directory to sync to |
| `TOOL` | `xxhsum` | Hash tool to use (e.g. `xxhsum`, `md5`, `sha256sum`) |

### What It Does

1. Syncs `SRC/` → `DEST/` using `rsync -av --progress --stats`.
2. Generates `SRC_checksums.txt` and `DEST_checksums.txt` by hashing every file in each directory using relative paths.
3. Diffs the two checksum files.
4. If they match, prints the `rm -rfv` command that would delete the source (the actual `rm` line is commented out for safety).
5. If they differ, prints the diff output so mismatches can be identified.

### Dependencies

- `rsync` — standard on macOS
- `xxhsum` — install with `brew install xxhash` (or pass a different tool as the third argument)
- `find`, `diff` — standard on macOS/Linux

### Notes

- The `rm -rfv "$SRC"` line is intentionally commented out. Uncomment it only after confirming the checksums match.
- Checksum file cleanup lines are also commented out; delete `SRC_checksums.txt` and `DEST_checksums.txt` manually once you are satisfied.

### Example

```bash
./sync_and_verify.sh /Volumes/3KM_DOWNSCALING/jpan/ /Volumes/ERASED
```
