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
  provider_params=$(find providers -mindepth 2 -maxdepth 2 -name 'params.yaml' 2>/dev/null | sort)
  if [ -z "$provider_params" ]; then
    echo "warning: no providers/<provider>/params.yaml files exist yet — skipping required-symbol check" >&2
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

# --- Direction 3: contract version equality ---------------------------------
# One contract version per DTK release (config/definitions/provider-contract.yaml);
# every provider package must declare exactly it — plain equality, no matrix.
CONTRACT="config/definitions/provider-contract.yaml"
if [ -f "$CONTRACT" ]; then
  cv=$(yq eval '.contract_version' "$CONTRACT")
  for pf in providers/*/params.yaml; do
    [ -f "$pf" ] || continue
    pcv=$(yq eval '.contract_version // "unset"' "$pf")
    if [ "$pcv" != "$cv" ]; then
      echo "$pf: contract_version '$pcv' != release contract '$cv' ($CONTRACT) — the package must implement the release's contract"
      findings=$((findings+1))
    fi
  done
else
  echo "$CONTRACT: not found — contract version equality cannot be verified"
  findings=$((findings+1))
fi

# --- Direction 4: every provider materializes every workload class ----------
# Class identity lives in config/definitions/workload-classes.yaml; each
# provider package's classes.yaml must have an entry for every class (an empty
# entry is valid — the SEAT must exist). A missing entry is what a renamed
# class looks like. Cloud providers must additionally set instance_type.
WC="config/definitions/workload-classes.yaml"
if [ -f "$WC" ]; then
  platform_classes=$(yq eval '.classes | keys | .[]' "$WC" 2>/dev/null | sort)
  for cf in providers/*/classes.yaml; do
    [ -f "$cf" ] || continue
    prov=$(basename "$(dirname "$cf")")
    pclasses=$(yq eval '.classes | keys | .[]' "$cf" 2>/dev/null) || { echo "$cf:1: YAML parse error"; findings=$((findings+1)); continue; }
    for c in $platform_classes; do
      if ! printf '%s\n' "$pclasses" | grep -qxF "$c"; then
        echo "$cf: does not materialize workload class '$c' (declared in $WC)"
        findings=$((findings+1))
      fi
    done
    if [ "$prov" = "aws" ] || [ "$prov" = "digitalocean" ]; then
      for c in $platform_classes; do
        it=$(yq eval ".classes.\"$c\".instance_type // \"\"" "$cf" 2>/dev/null)
        if [ -z "$it" ]; then
          echo "$cf: class '$c' has no instance_type (required on cloud providers)"
          findings=$((findings+1))
        fi
      done
    fi
  done
  for pdir in providers/*/; do
    [ -f "$pdir/params.yaml" ] || continue
    if [ ! -f "$pdir/classes.yaml" ]; then
      echo "${pdir}classes.yaml: missing — every provider package must carry the per-class materialization seat"
      findings=$((findings+1))
    fi
  done
else
  echo "warning: $WC not found — class materialization completeness not verified" >&2
fi

# --- Direction 5: no P_* keys in environment config.yaml files (namespaces disjoint)
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
