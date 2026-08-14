#!/usr/bin/env bash
# Usage: check-pristine.sh [<config.yaml>] — require a clean working tree and an exact tag checkout; if a config.yaml with a dtk_version key is given, the tag must match it (DTK_DEV_ALLOW_UNTAGGED=1 waives the tag requirement in untagged dev clones).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -le 1 ] || { echo "usage: $0 [<config.yaml>]" >&2; exit 2; }
CONFIG="${1:-}"
if [ -n "$CONFIG" ] && [ ! -f "$CONFIG" ]; then
  echo "usage error: config file not found: $CONFIG" >&2
  exit 2
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repository: $ROOT" >&2; exit 2; }

findings=0

# --- Clean working tree
dirty=$(git status --porcelain)
if [ -n "$dirty" ]; then
  echo "working tree is not pristine — uncommitted changes:"
  printf '%s\n' "$dirty" | sed 's/^/  /'
  findings=$((findings+1))
fi

# --- Exact tag checkout
tag_count=$(git tag | wc -l | tr -d ' ')
if [ "$tag_count" = "0" ]; then
  if [ "${DTK_DEV_ALLOW_UNTAGGED:-}" = "1" ]; then
    echo "warning: repository has no tags; allowed by DTK_DEV_ALLOW_UNTAGGED=1 (dev clone)" >&2
    if [ "$findings" -gt 0 ]; then
      echo "check-pristine: $findings finding(s)"
      exit 1
    fi
    echo "check-pristine: OK (untagged dev clone)"
    exit 0
  fi
  echo "repository has no tags at all — deploy from a released tag (or set DTK_DEV_ALLOW_UNTAGGED=1 for development)"
  findings=$((findings+1))
else
  if tag=$(git describe --tags --exact-match 2>/dev/null); then
    echo "checked-out tag: $tag"
    if [ -n "$CONFIG" ]; then
      want=$(yq eval '.dtk_version // ""' "$CONFIG")
      if [ -n "$want" ] && [ "$want" != "null" ]; then
        if [ "$want" != "$tag" ]; then
          echo "$CONFIG: dtk_version '$want' does not match checked-out tag '$tag'"
          findings=$((findings+1))
        fi
      fi
    fi
  else
    echo "HEAD is not an exact tag (git describe --tags --exact-match failed) — check out a released tag"
    findings=$((findings+1))
  fi
fi

if [ "$findings" -gt 0 ]; then
  echo "check-pristine: $findings finding(s)"
  exit 1
fi
echo "check-pristine: OK"
