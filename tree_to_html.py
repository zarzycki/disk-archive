#!/usr/bin/env python3
"""Convert tree -s output to a lazy-loading interactive HTML viewer."""

import re
import sys
import json
from pathlib import Path, PurePosixPath


def parse(filename):
    nodes = {}
    with open(filename, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.search(r'\[\s*(\d+)\s+(\w{3}\s+\d+\s+[\d:]+)\]\s+(/\S+)', line)
            if not m:
                continue
            size = int(m.group(1))
            date = m.group(2).strip()
            path = m.group(3).rstrip()
            name = PurePosixPath(path).name or path
            nodes[path] = {"size": size, "date": date, "children": [], "name": name}

    root = None
    for path in nodes:
        parent = str(PurePosixPath(path).parent)
        if parent in nodes:
            nodes[parent]["children"].append(path)
        else:
            root = path

    for node in nodes.values():
        node["children"].sort(key=lambda p: (len(nodes[p]["children"]) == 0, p.lower()))

    return nodes, root


def build_flat(nodes, root):
    """Build a flat index array with iterative DFS (avoids Python recursion limits)."""
    path_to_idx = {}
    order = []
    stack = [root]
    while stack:
        path = stack.pop()
        if path in path_to_idx:
            continue
        path_to_idx[path] = len(path_to_idx)
        order.append(path)
        for child in reversed(nodes[path]["children"]):
            stack.append(child)

    flat = []
    for path in order:
        node = nodes[path]
        flat.append([
            node["name"],
            node["size"],
            node["date"],
            [path_to_idx[c] for c in node["children"]],
        ])
    return flat


# Raw string: no {{ }} escaping needed, no \] warnings
HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>DISK_NAME_PLACEHOLDER — disk tree</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font: 13px/1.5 "SF Mono","Fira Mono","Consolas",monospace;
       background: #1a1a1a; color: #d4d4d4; padding: 12px; }
#bar { position: sticky; top: 0; z-index: 10; background: #1a1a1a;
       padding: 8px 0 10px; display: flex; gap: 8px; align-items: center; }
#q { flex: 1; padding: 6px 10px; background: #2a2a2a; border: 1px solid #444;
     border-radius: 4px; color: #d4d4d4; font: inherit; outline: none; }
#q:focus { border-color: #888; }
#count { color: #888; font-size: 11px; min-width: 100px; }
button { padding: 5px 10px; background: #2a2a2a; border: 1px solid #444;
         border-radius: 4px; color: #aaa; cursor: pointer; font: inherit; }
button:hover { background: #333; }
ul { list-style: none; padding-left: 18px; }
#tree > ul { padding-left: 0; }
li { padding: 1px 0; }
details > summary { cursor: pointer; display: flex; align-items: baseline;
                    gap: 4px; padding: 2px 4px; border-radius: 3px; }
details > summary:hover { background: #2a2a2a; }
details[open] > summary { color: #9cdcfe; }
.d > details > summary::before { content: "▶ "; font-size: 9px; color: #888; }
.d > details[open] > summary::before { content: "▼ "; }
.f { display: flex; align-items: baseline; gap: 4px; padding: 1px 4px; }
.f::before { content: "  "; }
.n { color: #ce9178; }
.d > details > summary .n { color: #4ec9b0; font-weight: bold; }
.sep { color: #555; }
.m { font-size: 11px; white-space: nowrap; }
.sz { color: #e06c6c; }
.dt { color: #6c9fe0; }
.path { color: #666; font-size: 11px; }
mark { background: #5a3e00; color: #ffd700; border-radius: 2px; }
#results { display: none; }
#results ul { padding-left: 0; }
#results .f::before { content: ""; }
</style>
</head>
<body>
<div id="bar">
  <input id="q" type="search" placeholder="Search filenames…" autocomplete="off" spellcheck="false">
  <span id="count"></span>
  <button onclick="expandAll()">Expand all</button>
  <button onclick="collapseAll()">Collapse all</button>
</div>
<div id="tree"><ul id="root"></ul></div>
<div id="results"><ul id="rlist"></ul></div>
<script>
const N = NODES_JSON_PLACEHOLDER;

function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function humanSize(b) {
  const u = ['B','KB','MB','GB','TB'];
  let i = 0;
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
  return i === 0 ? b + ' B' : b.toFixed(1) + ' ' + u[i];
}

function metaHtml(idx) {
  const [, size, date] = N[idx];
  return '<span class="sep"> — </span><span class="m">' +
         '<span class="sz">' + humanSize(size) + '</span>' +
         ' · <span class="dt">' + esc(date) + '</span></span>';
}

const domMap = new Map(); // dir idx -> {det, ul}

function makeNode(idx) {
  const [name,,, children] = N[idx];
  const li = document.createElement('li');
  if (children.length === 0) {
    li.className = 'f';
    li.innerHTML = '<span class="n">' + esc(name) + '</span>' + metaHtml(idx);
  } else {
    li.className = 'd';
    const det = document.createElement('details');
    const sum = document.createElement('summary');
    sum.innerHTML = '<span class="n">' + esc(name) + '</span>' + metaHtml(idx);
    const ul = document.createElement('ul');
    det.append(sum, ul);
    li.appendChild(det);
    domMap.set(idx, {det, ul});
    det.addEventListener('toggle', () => {
      if (det.open && ul.childElementCount === 0) populateDir(idx);
    });
  }
  return li;
}

function populateDir(idx) {
  const {ul} = domMap.get(idx);
  const [,,,children] = N[idx];
  const frag = document.createDocumentFragment();
  for (const ci of children) frag.appendChild(makeNode(ci));
  ul.appendChild(frag);
}

// Boot: render root and open it
const rootLi = makeNode(0);
domMap.get(0).det.open = true;
populateDir(0);
document.getElementById('root').appendChild(rootLi);

// Expand all currently-rendered dirs, discovering new ones each pass
function expandAll() {
  let prev;
  do {
    prev = domMap.size;
    for (const [idx, {det, ul}] of [...domMap]) {
      if (ul.childElementCount === 0) populateDir(idx);
      det.open = true;
    }
  } while (domMap.size > prev);
}

function collapseAll() {
  domMap.forEach(({det}) => { det.open = false; });
}

// Search: walk JSON tree, show flat matching-file list
const q       = document.getElementById('q');
const countEl = document.getElementById('count');
const treeEl  = document.getElementById('tree');
const results = document.getElementById('results');
const rlist   = document.getElementById('rlist');

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

let debounce;
q.addEventListener('input',  () => { clearTimeout(debounce); debounce = setTimeout(applyFilter, 200); });
q.addEventListener('search', () => { if (!q.value) applyFilter(); }); // X button clear

function applyFilter() {
  const term = q.value.trim().toLowerCase();
  if (!term) {
    treeEl.style.display = 'block';
    results.style.display = 'none';
    countEl.textContent = '';
    return;
  }

  // Build matcher: support * (any chars) and ? (one char) wildcards
  const isGlob = /[*?]/.test(term);
  let matchFn, hlFn;
  if (isGlob) {
    const rePat = term.replace(/[.+^${}()|[\]\\]/g, '\\$&')
                      .replace(/\*/g, '.*').replace(/\?/g, '.');
    const re = new RegExp('^' + rePat + '$', 'i');
    matchFn = name => re.test(name);
    // For glob, highlight the whole filename on a match
    hlFn = name => '<mark>' + esc(name) + '</mark>';
  } else {
    matchFn = name => name.toLowerCase().includes(term);
    hlFn    = name => highlight(name, term);
  }

  // Iterative DFS through JSON (not DOM) — fast regardless of what's expanded
  const matches = [];
  const stack = [[0, '']];
  while (stack.length) {
    const [idx, par] = stack.pop();
    const [name,,, children] = N[idx];
    const myPath = par ? par + '/' + name : name;
    if (children.length === 0) {
      if (matchFn(name)) matches.push([idx, myPath]);
    } else {
      for (let i = children.length - 1; i >= 0; i--) stack.push([children[i], myPath]);
    }
  }

  const MAX = 2000;
  const frag = document.createDocumentFragment();
  for (const [idx, fullPath] of matches.slice(0, MAX)) {
    const [name] = N[idx];
    const dir = fullPath.slice(0, fullPath.length - name.length);
    const li = document.createElement('li');
    li.className = 'f';
    li.innerHTML = '<span class="path">' + esc(dir) + '</span>' +
                   '<span class="n">' + hlFn(name) + '</span>' +
                   metaHtml(idx);
    frag.appendChild(li);
  }

  rlist.innerHTML = '';
  rlist.appendChild(frag);
  countEl.textContent = matches.length > MAX
    ? MAX.toLocaleString() + ' of ' + matches.length.toLocaleString() + ' shown'
    : matches.length.toLocaleString() + ' match' + (matches.length !== 1 ? 'es' : '');

  treeEl.style.display = 'none';
  results.style.display = 'block';
}

q.focus();
</script>
</body>
</html>
"""


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} tree_XXXXX.txt", file=sys.stderr)
        sys.exit(1)

    in_path = Path(sys.argv[1])
    if not in_path.name.startswith("tree_") or in_path.suffix != ".txt":
        print(f"Error: input must be named tree_XXXXX.txt, got {in_path.name}", file=sys.stderr)
        sys.exit(1)

    disk_name = in_path.stem[len("tree_"):]          # e.g. "CPT01"
    out_path  = in_path.with_name(f"html_{disk_name}.html")

    print(f"Parsing {in_path}…")
    nodes, root = parse(in_path)
    print(f"  {len(nodes):,} entries. Building index…")

    flat = build_flat(nodes, root)
    print("  Serializing JSON…")

    json_str = json.dumps(flat, ensure_ascii=False, separators=(',', ':'))
    html_out = (HTML
                .replace("NODES_JSON_PLACEHOLDER", json_str)
                .replace("DISK_NAME_PLACEHOLDER", disk_name))

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html_out)

    size_mb = len(html_out.encode()) / (1024 * 1024)
    print(f"  Written {out_path} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
