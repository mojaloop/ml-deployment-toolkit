#!/usr/bin/env bash
# Usage: check-tools.sh — verify every tool declared in tools-versions.yaml is installed at or above its minimum version (required tools fail the check; optional ones warn).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }
TV="tools-versions.yaml"
if [ ! -f "$TV" ]; then
  echo "$TV: not found at repo root — cannot verify tool versions"
  echo "check-tools: 1 finding(s)"
  exit 1
fi

# version_lt A B — true if version A < B (numeric dot-segment compare, bash 3.2 safe)
version_lt() {
  local a="$1" b="$2" i=1 as bs
  while [ "$i" -le 4 ]; do
    as=$(printf '%s' "$a" | cut -d. -f"$i"); bs=$(printf '%s' "$b" | cut -d. -f"$i")
    as=$(printf '%s' "$as" | tr -cd '0-9'); bs=$(printf '%s' "$bs" | tr -cd '0-9')
    as=${as:-0}; bs=${bs:-0}
    if [ "$as" -lt "$bs" ]; then return 0; fi
    if [ "$as" -gt "$bs" ]; then return 1; fi
    i=$((i+1))
  done
  return 1
}

findings=0
tools=$(yq eval '.tools | keys | .[]' "$TV" 2>/dev/null) \
  || { echo "$TV:1: could not parse (expected a 'tools:' map)"; echo "check-tools: 1 finding(s)"; exit 1; }

for tool in $tools; do
  min=$(yq eval ".tools.\"$tool\".min // \"\"" "$TV")
  req=$(yq eval ".tools.\"$tool\".required // false" "$TV")
  probe=$(yq eval ".tools.\"$tool\".probe // \"\"" "$TV")
  cmd="$tool"
  [ -z "$probe" ] || cmd=${probe%% *}

  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ "$req" = "true" ]; then
      echo "$tool: NOT INSTALLED (required, min $min) — probe command '$cmd' not found"
      findings=$((findings+1))
    else
      echo "warning: $tool not installed (optional, min $min)" >&2
    fi
    continue
  fi

  if [ -n "$probe" ]; then
    out=$($probe 2>&1 | head -2 || true)
  else
    # No probe declared — try the common version-flag spellings in order.
    out=""
    for p in "--version" "version --client" "version"; do
      out=$($cmd $p 2>&1 | head -2 || true)
      if printf '%s' "$out" | grep -qE '[0-9]+\.[0-9]+'; then
        probe="$cmd $p"
        break
      fi
    done
    [ -n "$probe" ] || probe="$cmd --version"
  fi

  # yq flavor gate: mikefarah yq required; python/kislyuk yq is a different tool.
  if [ "$tool" = "yq" ]; then
    if ! printf '%s' "$out" | grep -q 'https://github.com/mikefarah/yq'; then
      echo "yq: wrong yq detected — this looks like python/kislyuk yq; install mikefarah yq v4 (https://github.com/mikefarah/yq)"
      findings=$((findings+1))
      continue
    fi
  fi

  ver=$(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
  if [ -z "$ver" ]; then
    if [ "$req" = "true" ]; then
      echo "$tool: installed but version undetectable from probe '$probe' (min $min)"
      findings=$((findings+1))
    else
      echo "warning: $tool version undetectable (optional)" >&2
    fi
    continue
  fi

  if [ -n "$min" ] && version_lt "$ver" "$min"; then
    if [ "$req" = "true" ]; then
      echo "$tool: version $ver is below required minimum $min"
      findings=$((findings+1))
    else
      echo "warning: $tool version $ver below suggested minimum $min (optional)" >&2
    fi
    continue
  fi

  echo "ok: $tool $ver (min ${min:-any})"
done

if [ "$findings" -gt 0 ]; then
  echo "check-tools: $findings finding(s)"
  exit 1
fi
echo "check-tools: OK"
