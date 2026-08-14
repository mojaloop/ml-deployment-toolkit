#!/usr/bin/env bash
# Usage: check-valuesfrom.sh — verify every HelmRelease in gitops/ ends its valuesFrom
# list with the environment override twins, in order:
#   { kind: ConfigMap, name: <targetNamespace>-<release>-values-override, optional: true }
#   { kind: Secret,    name: <targetNamespace>-<release>-values-override, optional: true }
# (A values override referencing only config params lands as the ConfigMap; one
# referencing .env keys lands as the Secret — same name, Secret last so it wins.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

findings=0
seen=0

while IFS= read -r f; do
  # One TSV row per HelmRelease document:
  # name, targetNamespace, valuesFrom length, last.kind, last.name, last.optional
  rows=$(yq eval-all -o=json -I0 '.' "$f" 2>/dev/null | jq -r '
      select(type == "object" and .kind == "HelmRelease") |
      [ (.metadata.name // "?"),
        (.spec.targetNamespace // .metadata.namespace // ""),
        ((.spec.valuesFrom // []) | length),
        ((.spec.valuesFrom // []) | (.[-2] // {}) | (.kind // "")),
        ((.spec.valuesFrom // []) | (.[-2] // {}) | (.name // "")),
        ((.spec.valuesFrom // []) | (.[-2] // {}) | (.optional // false)),
        ((.spec.valuesFrom // []) | (last // {}) | (.kind // "")),
        ((.spec.valuesFrom // []) | (last // {}) | (.name // "")),
        ((.spec.valuesFrom // []) | (last // {}) | (.optional // false)) ] | @tsv
    ') || { echo "$f:1: YAML parse error (yq could not read file)"; findings=$((findings+1)); continue; }
  [ -n "$rows" ] || continue

  while IFS=$'\t' read -r rel tns len pkind pname popt lkind lname lopt; do
    [ -n "$rel" ] || continue
    seen=$((seen+1))
    expected="${tns}-${rel}-values-override"
    if [ "$len" = "0" ] || [ -z "$len" ] || [ "$len" = "1" ]; then
      echo "$f: HelmRelease/$rel: valuesFrom must end with the override twins (ConfigMap+Secret $expected, both optional: true)"
      findings=$((findings+1))
      continue
    fi
    ok=1
    if [ "$pkind" != "ConfigMap" ] || [ "$lkind" != "Secret" ]; then
      echo "$f: HelmRelease/$rel: last two valuesFrom kinds are '$pkind','$lkind', want 'ConfigMap','Secret'"
      ok=0
    fi
    if [ "$pname" != "$expected" ] || [ "$lname" != "$expected" ]; then
      echo "$f: HelmRelease/$rel: override twin names are '$pname','$lname', want '$expected' for both"
      ok=0
    fi
    if [ "$popt" != "true" ] || [ "$lopt" != "true" ]; then
      echo "$f: HelmRelease/$rel: both override twins must be 'optional: true' (got '$popt','$lopt')"
      ok=0
    fi
    [ "$ok" = "1" ] || findings=$((findings+1))
  done <<EOF
$rows
EOF
done < <(find gitops -type f \( -name 'helmrelease*.yaml' -o -name '*-helmrelease.yaml' -o -name 'helmrelease*.yml' -o -name '*-helmrelease.yml' \) | sort)

if [ "$seen" -eq 0 ]; then
  echo "warning: no HelmRelease documents found under gitops/" >&2
fi

if [ "$findings" -gt 0 ]; then
  echo "check-valuesfrom: $findings finding(s) across $seen HelmRelease(s)"
  exit 1
fi
echo "check-valuesfrom: OK ($seen HelmRelease(s))"
