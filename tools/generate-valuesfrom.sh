#!/usr/bin/env bash
# Usage: generate-valuesfrom.sh — regenerate the three-layer valuesFrom chain tail
# on every HelmRelease in gitops/. The chain is generated mechanically, never
# hand-written (tools/checks/check-valuesfrom.sh only verifies it). For each
# HelmRelease (tns = spec.targetNamespace // metadata.namespace, rel =
# metadata.name) this removes any existing entries named
# <tns>-<rel>-values-template / <tns>-<rel>-values-override and appends the
# canonical tail:
#   - ConfigMap <tns>-<rel>-values-template  (optional)
#   - ConfigMap <tns>-<rel>-values-override  (optional)
#   - Secret    <tns>-<rel>-values-override  (optional)
# each with valuesKey: values.yaml. Idempotent: on a compliant tree it produces
# zero diff. Text-based on purpose — a yq round-trip would destroy comments and
# formatting, so files are never reformatted, only the tail entries are spliced.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

python3 <<'PYEOF'
import fnmatch
import os
import re
import sys

RX_KIND = re.compile(r'^kind:\s*HelmRelease\s*(#.*)?$', re.M)
RX_ENTRY_NAME = re.compile(r'^\s+name:\s*["\']?([^\s"\'#]+)')


def scalar(lines, top_key, sub_key):
    """Value of a 2-space-indented sub_key inside top-level top_key, or None."""
    in_block = False
    for ln in lines:
        if ln.startswith(top_key + ':'):
            in_block = True
            continue
        if in_block:
            if ln and not ln.startswith(' ') and not ln.startswith('#'):
                break  # next top-level key
            m = re.match(r'^  ' + re.escape(sub_key) + r':\s*["\']?([^\s"\'#]+)', ln)
            if m:
                return m.group(1)
    return None


def canonical_tail(tns, rel):
    t = f'{tns}-{rel}-values-template'
    o = f'{tns}-{rel}-values-override'
    out = []
    for kind, name in (('ConfigMap', t), ('ConfigMap', o), ('Secret', o)):
        out += [f'    - kind: {kind}',
                f'      name: {name}',
                '      valuesKey: values.yaml',
                '      optional: true']
    return out


def process_doc(lines):
    """Splice the canonical tail into one YAML document (list of lines, no
    trailing newlines). Returns (new_lines, changed_release_or_None)."""
    text = '\n'.join(lines)
    if not RX_KIND.search(text):
        return lines, None
    rel = scalar(lines, 'metadata', 'name')
    tns = scalar(lines, 'spec', 'targetNamespace') or scalar(lines, 'metadata', 'namespace')
    if not rel or not tns:
        print(f'warning: HelmRelease without resolvable name/namespace skipped', file=sys.stderr)
        return lines, None
    managed = {f'{tns}-{rel}-values-template', f'{tns}-{rel}-values-override'}

    # Locate the `  valuesFrom:` block (2-space key under spec; entries at 4).
    start = None
    for i, ln in enumerate(lines):
        if re.match(r'^  valuesFrom:\s*(#.*)?$', ln):
            start = i
            break
    if start is None:
        # No valuesFrom yet — append one at the end of the document (spec is the
        # last top-level key in this repo's HelmRelease files).
        while lines and lines[-1].strip() == '':
            lines.pop()
        return lines + ['  valuesFrom:'] + canonical_tail(tns, rel), rel

    end = len(lines)
    for i in range(start + 1, len(lines)):
        ln = lines[i]
        if ln.strip() == '' or ln.startswith('    '):
            continue
        end = i
        break

    block = lines[start + 1:end]
    # Trailing blank lines (e.g. a blank final line of the file) are not part of
    # the list — keep them after the spliced tail so files are never reflowed.
    trail = []
    while block and block[-1].strip() == '':
        trail.insert(0, block.pop())
    # Split block into entry chunks; leading comment/blank lines stay put.
    pre, entries, cur = [], [], None
    for ln in block:
        if re.match(r'^    - ', ln):
            if cur is not None:
                entries.append(cur)
            cur = [ln]
        elif cur is None:
            pre.append(ln)
        else:
            cur.append(ln)
    if cur is not None:
        entries.append(cur)

    kept = []
    for e in entries:
        name = None
        for ln in e:
            m = RX_ENTRY_NAME.match(ln)
            if m:
                name = m.group(1)
                break
        if name in managed:
            continue
        kept.append(e)

    new_block = pre + [ln for e in kept for ln in e] + canonical_tail(tns, rel) + trail
    new_lines = lines[:start + 1] + new_block + lines[end:]
    return new_lines, (rel if new_lines != lines else None)


paths = []
for dirpath, _dirs, files in os.walk('gitops'):
    for fn in files:
        if fnmatch.fnmatch(fn, 'helmrelease*.yaml') or fn.endswith('-helmrelease.yaml'):
            paths.append(os.path.join(dirpath, fn))

files_seen = releases = changed_files = 0
for path in sorted(paths):
    files_seen += 1
    with open(path, encoding='utf-8') as fh:
        original = fh.read()
    trailing_nl = original.endswith('\n')
    lines = original.split('\n')
    if trailing_nl:
        lines.pop()  # drop the empty element after the final newline

    # Split into documents on `---` separator lines, preserving separators.
    docs, seps, cur = [], [], []
    for ln in lines:
        if re.match(r'^---\s*$', ln):
            docs.append(cur)
            seps.append(ln)
            cur = []
        else:
            cur.append(ln)
    docs.append(cur)

    file_changed = False
    out_docs = []
    for d in docs:
        new_d, rel = process_doc(d)
        if RX_KIND.search('\n'.join(d)):
            releases += 1
        if rel is not None:
            file_changed = True
        out_docs.append(new_d)

    rebuilt = []
    for i, d in enumerate(out_docs):
        rebuilt.extend(d)
        if i < len(seps):
            rebuilt.append(seps[i])
    result = '\n'.join(rebuilt) + ('\n' if trailing_nl else '')

    if result != original:
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(result)
        changed_files += 1
        print(f'updated: {path}')

print(f'generate-valuesfrom: {releases} HelmRelease(s) in {files_seen} file(s), '
      f'{changed_files} file(s) rewritten')
PYEOF
