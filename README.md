# Scripts

Set of scripts for maintaining external MEWAC hard drives. General order is:

- `turn_off_spotlight.sh` -  If needed (new drive), turn off Mac Spotlight.
- `check-and-compress-nc.sh` - If needed, compress .nc files
- `parallel_hash.sh` - Create tree and hash files.
- `tree_to_html.py` - Convert a tree file into an interactive HTML viewer.

## parallel_hash.sh

A Bash script that recursively hashes files in a directory in parallel, with resume support for interrupted runs.

### Usage

```bash
./parallel_hash.sh [DIR] [TOOL] [OUTFILE] [JOBS]
```

| Argument | Default | Description |
|---|---|---|
| `DIR` | `.` | Directory to scan |
| `TOOL` | `xxhsum` | Hash tool to use (e.g. `xxhsum`, `md5`, `sha256sum`) |
| `OUTFILE` | `hashes_<dirname>.txt` | File to write results to |
| `JOBS` | `4` | Number of parallel workers |

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

A directory tree snapshot is saved to `./tree_<dirname>.txt`.

Errors and failed files are logged to `hash_errors.log`. This should generally be an empty file.

### Resume Support

If the output file already exists from a previous run, the script parses it to find already-hashed files and skips them. This allows interrupted runs to be resumed without re-hashing completed files.

### Examples

```bash
# Hash all files in /Volumes/MyDrive using sha256sum, 8 workers
./parallel_hash.sh /Volumes/MyDrive sha256sum drive_hashes.txt 8
```

```bash
# Hash all files in /Volumes/DRIVE/
# Produces: hashes_DRIVE.txt (hash results) and tree_DRIVE.txt (directory tree)
./parallel_hash.sh /Volumes/DRIVE/
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
python3 tree_to_html.py tree_XXXXX.txt
```

The output file is named `html_XXXXX.html` in the same directory, where `XXXXX` matches the suffix of the input file.

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
# Produces html_CPT01.html from tree_CPT01.txt
python3 tree_to_html.py tree_CPT01.txt
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
