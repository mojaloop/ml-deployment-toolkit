#!/usr/bin/env bash
# Usage: check-placement.sh — every node-role value referenced in gitops/ (tolerations, nodeSelector, nodeAffinity matchExpressions) must exist as a node_labels node-role in config/definitions/workload-classes.yaml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }
CLASSES="config/definitions/workload-classes.yaml"
[ -f "$CLASSES" ] || { echo "error: $CLASSES not found" >&2; exit 2; }
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

allowed=$(yq eval '.classes[] | .node_labels."node-role" // ""' "$CLASSES" | sed '/^$/d' | sort -u)
if [ -z "$allowed" ]; then
  echo "warning: no node-role labels defined in $CLASSES" >&2
fi

findings=0

while IFS= read -r f; do
  # node-role values used as a map key (nodeSelector / matchLabels) …
  vals1=$(yq eval-all '.. | select(type == "!!map") | select(has("node-role")) | ."node-role" | select(tag == "!!str")' "$f" 2>/dev/null) || {
    echo "$f:1: YAML parse error (yq could not read file)"; findings=$((findings+1)); continue; }
  # … and as key/value(s) pairs (tolerations / nodeAffinity matchExpressions)
  vals2=$(yq eval-all '.. | select(type == "!!map") | select(.key == "node-role") | (.value // (.values[]?)) | select(tag == "!!str")' "$f" 2>/dev/null) || true

  vals=$(printf '%s\n%s\n' "$vals1" "$vals2" | sed '/^$/d' | sort -u)
  [ -n "$vals" ] || continue

  for v in $vals; do
    case "$v" in
      *'$'*) continue ;;   # templated value — cannot validate statically
    esac
    if ! printf '%s\n' "$allowed" | grep -qx "$v"; then
      ln=$(grep -n -- "$v" "$f" | head -1 | cut -d: -f1 || true)
      echo "$f:${ln:-1}: node-role '$v' not defined as a node_labels node-role in $CLASSES"
      findings=$((findings+1))
    fi
  done
done < <(find gitops -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

if [ "$findings" -gt 0 ]; then
  echo "check-placement: $findings finding(s)"
  exit 1
fi
echo "check-placement: OK"
