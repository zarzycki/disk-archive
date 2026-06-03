#!/usr/bin/env python3
"""Build a lightweight master search index from html_*.html disk viewers.

Strips sizes and dates from each disk's embedded node tree, keeping only
name + children (integer indices). This avoids repeating parent path
components, so the combined file is smaller than storing full paths.
Per-disk tree browsing stays in the individual html_DISKNAME.html files.
"""

import re
import sys
import json
from pathlib import Path

_NODE_RE = re.compile(r'<script>\s*const N = (\[.*?\]);\s*\nfunction', re.DOTALL)


def strip_nodes(html_path: Path):
    """Return (disk_name, stripped_nodes) where each node is [name] or [name, [children]]."""
    text = html_path.read_text(encoding="utf-8")
    m = _NODE_RE.search(text)
    if not m:
        raise ValueError(f"Could not find node JSON in {html_path}")
    disk_name = html_path.stem[len("html_"):]
    raw = json.loads(m.group(1))
    # raw node: [name, size, date, [childIndices]]
    # stripped:  [name]  (leaf)  or  [name, [childIndices]]  (dir)
    stripped = []
    for name, _size, _date, children in raw:
        stripped.append([name, children] if children else [name])
    return disk_name, stripped


HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>All Disks — master lookup</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font: 13px/1.5 "SF Mono","Fira Mono","Consolas",monospace;
       background: #1a1a1a; color: #d4d4d4; padding: 12px; }
#bar { position: sticky; top: 0; z-index: 10; background: #1a1a1a;
       padding: 8px 0 10px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
#q { flex: 1; min-width: 200px; padding: 6px 10px; background: #2a2a2a;
     border: 1px solid #444; border-radius: 4px; color: #d4d4d4; font: inherit; outline: none; }
#q:focus { border-color: #888; }
#count { color: #888; font-size: 11px; min-width: 140px; }
#hint  { color: #555; font-size: 11px; }
ul { list-style: none; padding-left: 0; }
li { display: flex; align-items: baseline; gap: 4px; padding: 1px 4px; flex-wrap: wrap; }
.disk { font-size: 10px; padding: 1px 6px; border-radius: 3px;
        background: #1a2a2a; color: #4ec9b0; text-decoration: none;
        white-space: nowrap; flex-shrink: 0; }
.disk:hover { background: #223a3a; }
.dir  { color: #555; font-size: 11px; word-break: break-all; }
.name { color: #ce9178; }
mark  { background: #5a3e00; color: #ffd700; border-radius: 2px; }
#empty { color: #555; padding: 20px 4px; }
</style>
</head>
<body>
<div id="bar">
  <input id="q" type="search" placeholder="Search all disks… (supports * and ? wildcards)" autocomplete="off" spellcheck="false">
  <span id="count"></span>
  <span id="hint">DISK_LIST_HINT</span>
</div>
<div id="empty">Start typing to search across all disks.</div>
<ul id="list"></ul>

<script>
// Each disk: {name, href, nodes}
// Each node: [name] (leaf) or [name, [childIndices]] (dir)
const DISKS = INDEX_JSON_PLACEHOLDER;

function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function highlight(text, term) {
  const lo = text.toLowerCase();
  let out = '', i = 0;
  while (i < text.length) {
    const j = lo.indexOf(term, i);
    if (j < 0) { out += esc(text.slice(i)); break; }
    out += esc(text.slice(i, j)) + '<mark>' + esc(text.slice(j, j + term.length)) + '</mark>';
    i = j + term.length;
  }
  return out;
}

function makeMatchFn(term) {
  if (/[*?]/.test(term)) {
    const re = new RegExp('^' + term.replace(/[.+^${}()|[\]\\]/g,'\\$&').replace(/\*/g,'.*').replace(/\?/g,'.') + '$', 'i');
    return { matchFn: n => re.test(n), hlFn: n => '<mark>' + esc(n) + '</mark>' };
  }
  return { matchFn: n => n.toLowerCase().includes(term), hlFn: n => highlight(n, term) };
}

const q       = document.getElementById('q');
const listEl  = document.getElementById('list');
const countEl = document.getElementById('count');
const emptyEl = document.getElementById('empty');

let debounce;
q.addEventListener('input',  () => { clearTimeout(debounce); debounce = setTimeout(search, 150); });
q.addEventListener('search', () => { if (!q.value) clear(); });

function clear() {
  listEl.innerHTML = '';
  countEl.textContent = '';
  emptyEl.style.display = 'block';
}

function search() {
  const term = q.value.trim().toLowerCase();
  if (!term) { clear(); return; }

  const { matchFn, hlFn } = makeMatchFn(term);
  const MAX = 3000;
  const frag = document.createDocumentFragment();
  let total = 0;

  for (const { name: diskName, href, nodes } of DISKS) {
    // Iterative DFS: node = [name] (leaf) or [name, [childIndices]]
    const stack = [[0, '']];
    while (stack.length) {
      const [idx, parentPath] = stack.pop();
      const node = nodes[idx];
      const name = node[0];
      const children = node[1];           // undefined for leaves
      const myPath = parentPath ? parentPath + '/' + name : name;
      if (!children) {
        // leaf file
        if (matchFn(name)) {
          total++;
          if (total <= MAX) {
            const li = document.createElement('li');
            li.innerHTML =
              '<a class="disk" href="' + esc(href) + '" title="Open ' + esc(diskName) + ' viewer">' + esc(diskName) + '</a>' +
              '<span class="dir">'  + esc(myPath.slice(0, myPath.length - name.length)) + '</span>' +
              '<span class="name">' + hlFn(name) + '</span>';
            frag.appendChild(li);
          }
        }
      } else {
        for (let i = children.length - 1; i >= 0; i--) stack.push([children[i], myPath]);
      }
    }
  }

  listEl.innerHTML = '';
  listEl.appendChild(frag);
  emptyEl.style.display = 'none';
  countEl.textContent = total > MAX
    ? MAX.toLocaleString() + ' of ' + total.toLocaleString() + ' shown'
    : total.toLocaleString() + ' match' + (total !== 1 ? 'es' : '');
}

q.focus();
</script>
</body>
</html>
"""


def main():
    if len(sys.argv) < 2:
        directory = Path(".")
    else:
        directory = Path(sys.argv[1])

    html_files = sorted(
        p for p in directory.glob("html_*.html") if p.stem != "html_ALL"
    )
    if not html_files:
        print(f"No html_*.html files found in {directory}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(html_files)} disk HTML file(s):")
    index = []
    for p in html_files:
        print(f"  Stripping {p.name}…")
        name, nodes = strip_nodes(p)
        leaves = sum(1 for n in nodes if len(n) == 1)
        print(f"    {len(nodes):,} nodes, {leaves:,} files")
        index.append({"name": name, "href": p.name, "nodes": nodes})

    total_files = sum(sum(1 for n in d["nodes"] if len(n) == 1) for d in index)
    disk_hint = "  |  ".join(
        f"{d['name']}: {sum(1 for n in d['nodes'] if len(n)==1):,} files"
        for d in index
    ) + f"  |  total: {total_files:,}"

    index_json = json.dumps(index, ensure_ascii=False, separators=(",", ":"))

    html_out = (HTML
                .replace("INDEX_JSON_PLACEHOLDER", index_json)
                .replace("DISK_LIST_HINT", disk_hint))

    out_path = directory / "html_ALL.html"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html_out)

    size_mb = len(html_out.encode()) / (1024 * 1024)
    print(f"Written {out_path} ({size_mb:.1f} MB)  [{total_files:,} files indexed]")


if __name__ == "__main__":
    main()
