#!/usr/bin/env bash
# Usage: check-talos-fragments.sh — every talos patch fragment (config/patches/talos/, config/templates/<provider>/<role>/<name>/talos/, <env>/talos/) must parse as YAML once ${...} tokens are stubbed, and must not be a JSON6902 patch (strategic-merge fragments only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }

TMP=$(mktemp "${TMPDIR:-/tmp}/talos-frag.XXXXXX")
trap 'rm -f "$TMP"' EXIT

findings=0
scanned=0

check_fragment() {
  local f="$1"
  scanned=$((scanned+1))
  # Stub substitution tokens (escaped and live) with a plain scalar before parsing.
  # *.tpl files are Terraform-native templates: drop directive-only %{...} lines
  # (for/endfor/if/endif, with optional ~ strip markers) and stub inline %{...}.
  case "$f" in
    *.tpl)
      sed -e '/^[[:space:]]*%{[^}]*}[[:space:]]*$/d' \
          -e 's/%{[^}]*}/x/g' \
          -e 's/\$\${[^}]*}/x/g' -e 's/\${[^}]*}/x/g' "$f" > "$TMP"
      ;;
    *)
      sed -e 's/\$\${[^}]*}/x/g' -e 's/\${[^}]*}/x/g' "$f" > "$TMP"
      ;;
  esac

  if ! yq eval-all '.' "$TMP" >/dev/null 2>&1; then
    echo "$f:1: does not parse as YAML (after stubbing \${...} tokens)"
    findings=$((findings+1))
    return
  fi

  # JSON6902 patch = top-level sequence whose items carry op: keys — forbidden here.
  local is6902
  is6902=$(yq eval-all 'select(type == "!!seq") | [.[] | select(type == "!!map") | has("op")] | any' "$TMP" 2>/dev/null || echo "false")
  if printf '%s\n' "$is6902" | grep -qx "true"; then
    ln=$(grep -nE '^[[:space:]]*-[[:space:]]*op:' "$f" | head -1 | cut -d: -f1 || true)
    echo "$f:${ln:-1}: JSON6902 patch is forbidden in talos dirs (use strategic-merge fragments)"
    findings=$((findings+1))
  fi
}

# Fixed root + target-state roots (silently absent until later phases).
for dir in config/patches/talos config/templates/*/*/*/talos "${ENVIRONMENTS_ROOT:-../environments}"/*/talos; do
  [ -d "$dir" ] || continue
  while IFS= read -r f; do
    check_fragment "$f"
  done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.tpl' \) | sort)
done

if [ "$scanned" -eq 0 ]; then
  echo "warning: no talos fragments found to check" >&2
fi

if [ "$findings" -gt 0 ]; then
  echo "check-talos-fragments: $findings finding(s) in $scanned fragment(s)"
  exit 1
fi
echo "check-talos-fragments: OK ($scanned fragment(s))"
