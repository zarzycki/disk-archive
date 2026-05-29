#!/usr/bin/env python3
"""Build a disk usage bar chart from disk_*.txt summary files."""

import re
import sys
import argparse
from pathlib import Path

try:
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
except ImportError:
    print("Error: matplotlib is required.  pip install matplotlib", file=sys.stderr)
    sys.exit(1)


def parse_size(s):
    units = {'T': 1e12, 'G': 1e9, 'M': 1e6, 'K': 1e3}
    s = s.strip()
    return float(s[:-1]) * units[s[-1]] if s[-1] in units else float(s)


def parse_disk_file(path):
    line = Path(path).read_text().strip()
    m = re.match(r'(\S+)\s*\|\s*total:\s*(\S+)\s*\|\s*used:\s*(\S+)\s*\|\s*free:\s*(\S+)', line)
    if not m:
        raise ValueError(f"cannot parse: {line}")
    return m.group(1), parse_size(m.group(2)), parse_size(m.group(3)), parse_size(m.group(4))


def human(b):
    for unit, scale in [('T', 1e12), ('G', 1e9), ('M', 1e6), ('K', 1e3)]:
        if b >= scale:
            return f"{b / scale:.1f}{unit}"
    return f"{b:.0f}B"


def main():
    parser = argparse.ArgumentParser(description="Visualize disk usage from disk_*.txt files.")
    parser.add_argument("directory", help="Directory containing disk_*.txt files")
    parser.add_argument("--out", help="Output image path (default: disk_usage.png in directory)")
    args = parser.parse_args()

    dirpath = Path(args.directory)
    if not dirpath.is_dir():
        print(f"Error: '{dirpath}' is not a directory or does not exist.", file=sys.stderr)
        sys.exit(1)

    files = sorted(dirpath.glob("disk_*.txt"))
    if not files:
        print(f"Error: no disk_*.txt files found in {dirpath}", file=sys.stderr)
        sys.exit(1)

    disks = []
    for f in files:
        try:
            disks.append(parse_disk_file(f))
        except ValueError as e:
            print(f"Warning: skipping {f.name}: {e}", file=sys.stderr)

    if not disks:
        print("No valid disk entries found.", file=sys.stderr)
        sys.exit(1)

    disks.sort(key=lambda d: d[0])
    names  = [d[0] for d in disks]
    totals = [d[1] for d in disks]
    used   = [d[2] for d in disks]
    free   = [d[3] for d in disks]
    max_total = max(totals)

    COLOR_USED  = '#c0504d'
    COLOR_FREE  = '#4ec9b0'
    COLOR_TEXT  = '#d4d4d4'
    COLOR_LABEL = '#9cdcfe'
    BG          = '#1a1a1a'

    fig, ax = plt.subplots(figsize=(11, max(3, len(disks) * 1.4)))
    fig.patch.set_facecolor(BG)
    ax.set_facecolor(BG)

    bar_h = 0.5

    for i, (name, total, u, f) in enumerate(disks):
        ax.barh(i, u / 1e12, height=bar_h, color=COLOR_USED, left=0)
        ax.barh(i, f / 1e12, height=bar_h, color=COLOR_FREE, left=u / 1e12)

        # used label inside used portion (if wide enough)
        if u / max_total > 0.12:
            ax.text(u / 1e12 / 2, i, f"{human(u)} used",
                    ha='center', va='center', color='white', fontsize=9)

        # free space — the key number — prominently to the right
        ax.text(total / 1e12 + max_total / 1e12 * 0.015, i,
                f"{human(f)} free  (of {human(total)})",
                ha='left', va='center', color=COLOR_FREE, fontsize=10,
                fontfamily='monospace', fontweight='bold')

    ax.set_yticks(range(len(disks)))
    ax.set_yticklabels(names, color=COLOR_LABEL, fontsize=11, fontfamily='monospace')
    ax.set_xlabel("Storage (TB)", color=COLOR_TEXT, fontsize=10)
    ax.set_xlim(0, max_total / 1e12 * 1.55)
    ax.tick_params(axis='x', colors=COLOR_TEXT)
    ax.tick_params(axis='y', length=0)
    for spine in ax.spines.values():
        spine.set_edgecolor('#444')

    legend = ax.legend(
        handles=[mpatches.Patch(color=COLOR_USED, label='Used'),
                 mpatches.Patch(color=COLOR_FREE, label='Free')],
        loc='upper right', facecolor='#2a2a2a', edgecolor='#555', labelcolor=COLOR_TEXT,
    )

    ax.set_title("Disk Usage", color=COLOR_TEXT, fontsize=13, pad=14)
    plt.tight_layout()

    out_path = Path(args.out) if args.out else dirpath / "all_disk_usage.png"
    plt.savefig(out_path, dpi=150, bbox_inches='tight', facecolor=BG)
    print(f"Saved: {out_path}")


if __name__ == "__main__":
    main()
