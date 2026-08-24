#!/usr/bin/env bash
# Usage: check-secret-placement.sh — forbid secret-named substitution tokens (Makefile SECRET_KEYS or *PASSWORD/SECRET/TOKEN/KEY_ID/ACCESS_KEY/API_TOKEN*) inside ConfigMap documents in gitops/, AND inside any file a configMapGenerator inlines (the generator builds a ConfigMap out of it, which the document scan cannot see).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }
[ -f Makefile ] || { echo "error: Makefile not found at repo root" >&2; exit 2; }
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

# Extract the SECRET_KEYS list (backslash-continued assignment) from the Makefile.
SECRET_KEYS=$(awk '
  /^SECRET_KEYS[[:space:]]*:?=/ { inlist = 1; sub(/^SECRET_KEYS[[:space:]]*:?=/, "") }
  inlist {
    cont = ($0 ~ /\\[[:space:]]*$/)
    gsub(/\\/, "");
    n = split($0, a, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    if (!cont) inlist = 0
  }' Makefile)

# SECRET_KEYS lists everything sourced from .env — not everything in it is a
# secret. Keys below are declared non-sensitive and resolve from the
# cluster-config ConfigMap (see flux-config/main.tf), so their appearance in a
# ConfigMap document is by design.
NON_SECRET_EXCEPTIONS="AWS_REGION"
SECRET_KEYS=$(printf '%s\n' "$SECRET_KEYS" | grep -vxF "$NON_SECRET_EXCEPTIONS" || true)

if [ -z "$SECRET_KEYS" ]; then
  echo "error: could not extract SECRET_KEYS from Makefile" >&2
  exit 2
fi

SECRET_PATTERN='(PASSWORD|SECRET|TOKEN|KEY_ID|ACCESS_KEY|API_TOKEN)'
findings=0

is_secret_name() {
  # $1 = UPPER token name
  if printf '%s\n' "$SECRET_KEYS" | grep -qx "$1"; then return 0; fi
  printf '%s' "$1" | grep -qE "$SECRET_PATTERN"
}

while IFS= read -r f; do
  # Text of the ConfigMap documents only (empty if none).
  cmtext=$(yq eval-all 'select(.kind == "ConfigMap")' "$f" 2>/dev/null) \
    || { echo "$f:1: YAML parse error (yq could not read file)"; findings=$((findings+1)); continue; }
  [ -n "$cmtext" ] || continue

  # Substitution tokens inside ConfigMap docs, with $${...} escapes removed first.
  toks=$(printf '%s\n' "$cmtext" \
          | sed 's/\$\${[^}]*}//g' \
          | grep -oE '\$\{[A-Z][A-Z0-9_]*\}' \
          | sed -e 's/^\${//' -e 's/}$//' | sort -u) || true

  for tok in $toks; do
    if is_secret_name "$tok"; then
      # Line numbers from the original file (best effort; escaped uses excluded).
      hits=$(sed 's/\$\${[^}]*}//g' "$f" | grep -nF "\${$tok}" | cut -d: -f1 || true)
      if [ -n "$hits" ]; then
        for ln in $hits; do
          echo "$f:$ln: secret-named token \${$tok} inside a ConfigMap document (secrets must not pass through ConfigMaps)"
          findings=$((findings+1))
        done
      else
        echo "$f: secret-named token \${$tok} inside a ConfigMap document (secrets must not pass through ConfigMaps)"
        findings=$((findings+1))
      fi
    fi
  done
done < <(find gitops -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

# --- configMapGenerator inputs ----------------------------------------------
# kustomize inlines these files into ConfigMaps at build time, so a secret
# token inside one lands in a ConfigMap without any ConfigMap document
# appearing in the repo. Secret-bearing distribution values belong in the
# handwritten *-values-secret Secrets (stringData — a secretGenerator would
# base64 the content and hide the tokens from post-build substitution).
while IFS= read -r kz; do
  dir=$(dirname "$kz")
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    rel="${spec#*=}"
    src="$dir/$rel"
    [ -f "$src" ] || continue
    toks=$(sed 's/\$\${[^}]*}//g' "$src" \
            | grep -oE '\$\{[A-Z][A-Z0-9_]*\}' \
            | sed -e 's/^\${//' -e 's/}$//' | sort -u) || true
    for tok in $toks; do
      if is_secret_name "$tok"; then
        hits=$(sed 's/\$\${[^}]*}//g' "$src" | grep -nF "\${$tok}" | cut -d: -f1 || true)
        for ln in ${hits:-1}; do
          echo "$src:$ln: secret-named token \${$tok} in a configMapGenerator input ($kz) — the generator inlines this file into a ConfigMap; move the key into the release's *-values-secret Secret"
          findings=$((findings+1))
        done
      fi
    done
  done < <(yq -r '.configMapGenerator[]?.files[]?' "$kz" 2>/dev/null)
done < <(find gitops -name kustomization.yaml | sort)

if [ "$findings" -gt 0 ]; then
  echo "check-secret-placement: $findings finding(s)"
  exit 1
fi
echo "check-secret-placement: OK"
