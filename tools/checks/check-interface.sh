#!/usr/bin/env bash
# Usage: check-interface.sh [<config.yaml>...] — verify the P_* provider interface: schema-required symbols supplied by every provider params.yaml, every ${P_*} in gitops/ declared in the schema, and no P_* keys leaking into environment config.yaml files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

SCHEMA="config/schemas/params.schema.json"
findings=0

required=""
declared=""
have_schema=0
if [ -f "$SCHEMA" ]; then
  have_schema=1
  # Interface symbols live under the schema's params block:
  # .properties.params.{required,properties}
  required=$(jq -r '.properties.params.required[]?' "$SCHEMA")
  declared=$(jq -r '(.properties.params.properties // {}) | keys[]' "$SCHEMA")
  # every required symbol is implicitly declared
  declared=$(printf '%s\n%s\n' "$declared" "$required" | sort -u | sed '/^$/d')
else
  echo "$SCHEMA: schema not found (provider interface cannot be verified)"
  findings=$((findings+1))
fi

# --- Direction 1: every required P_* symbol present in each provider params.yaml
if [ "$have_schema" = "1" ]; then
  provider_params=$(find config/templates -mindepth 2 -maxdepth 2 -name 'params.yaml' 2>/dev/null | sort)
  if [ -z "$provider_params" ]; then
    echo "warning: no config/templates/<provider>/params.yaml files exist yet — skipping required-symbol check" >&2
  else
    for pf in $provider_params; do
      keys=$(yq eval '.params | keys | .[]' "$pf" 2>/dev/null) || { echo "$pf:1: YAML parse error"; findings=$((findings+1)); continue; }
      for sym in $required; do
        if ! printf '%s\n' "$keys" | grep -qx "$sym"; then
          echo "$pf: required interface symbol '$sym' not supplied"
          findings=$((findings+1))
        fi
      done
    done
  fi
fi

# --- Direction 2: every ${P_*} referenced in gitops/ is declared in the schema
if [ "$have_schema" = "1" ] && [ -d gitops ]; then
  refs=$(grep -rhoE '\$\{P_[A-Z0-9_]*\}' gitops --include='*.yaml' --include='*.yml' 2>/dev/null \
           | sed -e 's/^\${//' -e 's/}$//' | sort -u) || true
  for sym in $refs; do
    if ! printf '%s\n' "$declared" | grep -qx "$sym"; then
      # locate references for per-line reporting
      hits=$(grep -rnF "\${$sym}" gitops --include='*.yaml' --include='*.yml' 2>/dev/null || true)
      printf '%s\n' "$hits" | awk -F: -v s="$sym" 'NF {printf "%s:%s: ${%s} not declared in schema\n", $1, $2, s}'
      findings=$((findings + $(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ')))
    fi
  done
fi

# --- Direction 3: no P_* keys in environment config.yaml files (namespaces disjoint)
for cf in "$@"; do
  if [ ! -f "$cf" ]; then
    echo "usage error: config file not found: $cf" >&2
    exit 2
  fi
  hits=$(grep -nE '^[[:space:]]*(["'\'']?)P_[A-Z0-9_]*\1[[:space:]]*:' "$cf" || true)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | awk -F: -v f="$cf" '{printf "%s:%s: P_* key in environment config (provider namespace is reserved)\n", f, $1}'
    findings=$((findings + $(printf '%s\n' "$hits" | wc -l | tr -d ' ')))
  fi
done

if [ "$findings" -gt 0 ]; then
  echo "check-interface: $findings finding(s)"
  exit 1
fi
echo "check-interface: OK"
