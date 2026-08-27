#!/usr/bin/env bash
# Usage: check-valuesfrom.sh — verify every HelmRelease in gitops/ carries the full
# four-layer chain tail (common -> provider -> template -> environment), in order:
#   { kind: ConfigMap, name: <targetNamespace>-<release>-values-provider, optional: true }
#   { kind: ConfigMap, name: <targetNamespace>-<release>-values-template, optional: true }
#   { kind: ConfigMap, name: <targetNamespace>-<release>-values-override, optional: true }
#   { kind: Secret,    name: <targetNamespace>-<release>-values-override, optional: true }
# (The provider slot carries the provider-wide gitops delta; the template slot the
# selected template's values/ deltas; an environment override referencing only config
# params lands as the ConfigMap; one referencing .env keys lands as the Secret —
# same name, Secret last so it wins.) A missing slot is a component the adopter
# cannot override without forking the clone. Regenerate with
# tools/generate-valuesfrom.sh — the chain is generated mechanically, never
# hand-written.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

findings=0
seen=0

while IFS= read -r f; do
  # One TSV row per HelmRelease document: name, targetNamespace, valuesFrom
  # length, then (kind, name, optional) for each of the last FOUR entries.
  rows=$(yq eval-all -o=json -I0 '.' "$f" 2>/dev/null | jq -r '
      select(type == "object" and .kind == "HelmRelease") |
      [ (.metadata.name // "?"),
        (.spec.targetNamespace // .metadata.namespace // ""),
        ((.spec.valuesFrom // []) | length),
        ((.spec.valuesFrom // []) | (.[-4] // {}) | (.kind // "")),
        ((.spec.valuesFrom // []) | (.[-4] // {}) | (.name // "")),
        ((.spec.valuesFrom // []) | (.[-4] // {}) | (.optional // false)),
        ((.spec.valuesFrom // []) | (.[-3] // {}) | (.kind // "")),
        ((.spec.valuesFrom // []) | (.[-3] // {}) | (.name // "")),
        ((.spec.valuesFrom // []) | (.[-3] // {}) | (.optional // false)),
        ((.spec.valuesFrom // []) | (.[-2] // {}) | (.kind // "")),
        ((.spec.valuesFrom // []) | (.[-2] // {}) | (.name // "")),
        ((.spec.valuesFrom // []) | (.[-2] // {}) | (.optional // false)),
        ((.spec.valuesFrom // []) | (last // {}) | (.kind // "")),
        ((.spec.valuesFrom // []) | (last // {}) | (.name // "")),
        ((.spec.valuesFrom // []) | (last // {}) | (.optional // false)) ] | @tsv
    ') || { echo "$f:1: YAML parse error (yq could not read file)"; findings=$((findings+1)); continue; }
  [ -n "$rows" ] || continue

  while IFS=$'\t' read -r rel tns len vkind vname vopt tkind tname topt pkind pname popt lkind lname lopt; do
    [ -n "$rel" ] || continue
    seen=$((seen+1))
    exp_v="${tns}-${rel}-values-provider"
    exp_t="${tns}-${rel}-values-template"
    exp_o="${tns}-${rel}-values-override"
    if [ -z "$len" ] || [ "$len" -lt 4 ]; then
      echo "$f: HelmRelease/$rel: valuesFrom must end with the four-layer tail (ConfigMap $exp_v, ConfigMap $exp_t, ConfigMap $exp_o, Secret $exp_o — all optional: true)"
      findings=$((findings+1))
      continue
    fi
    ok=1
    if [ "$vkind" != "ConfigMap" ] || [ "$tkind" != "ConfigMap" ] || [ "$pkind" != "ConfigMap" ] || [ "$lkind" != "Secret" ]; then
      echo "$f: HelmRelease/$rel: last four valuesFrom kinds are '$vkind','$tkind','$pkind','$lkind', want 'ConfigMap','ConfigMap','ConfigMap','Secret'"
      ok=0
    fi
    if [ "$vname" != "$exp_v" ]; then
      echo "$f: HelmRelease/$rel: provider slot name is '$vname', want '$exp_v'"
      ok=0
    fi
    if [ "$tname" != "$exp_t" ]; then
      echo "$f: HelmRelease/$rel: template slot name is '$tname', want '$exp_t'"
      ok=0
    fi
    if [ "$pname" != "$exp_o" ] || [ "$lname" != "$exp_o" ]; then
      echo "$f: HelmRelease/$rel: override twin names are '$pname','$lname', want '$exp_o' for both"
      ok=0
    fi
    if [ "$vopt" != "true" ] || [ "$topt" != "true" ] || [ "$popt" != "true" ] || [ "$lopt" != "true" ]; then
      echo "$f: HelmRelease/$rel: all four tail entries must be 'optional: true' (got '$vopt','$topt','$popt','$lopt')"
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
