#!/usr/bin/env bash
# Usage: check-bindings.sh [<env-config.yaml>...] — pool-keyed binding names must bind.
# Companion to check-placement.sh (which validates gitops -> pool references); this one
# validates FILE-NAME bindings that are keyed on pool names and today would silently
# no-op when misspelled:
#   1. talos fragments   — talos/<pool>.yaml in the selected template and in the
#      environment: matched via lookup by instance group (src/infra + proxmox module),
#      so a typo'd filename never applies to any node. Template fragments must name a
#      pool of the template's own placement.yaml; environment fragments must name a
#      pool of the environment's EFFECTIVE pool set (template pools minus enabled:false
#      overrides plus env-added pools).
#   2. proxmox VM pool overrides — proxmox/<pool>.yaml (proxmox.yaml itself is the
#      env-wide provider sidecar and exempt): same rule, same failure mode.
# The values/patches half of the orphaned-binding surface (values/<ns>/<release>.yaml
# must bind to a HelmRelease, patches/<name>.yaml to a Flux Kustomization) lives in
# check-values-files.sh; Terraform enforces the same contracts at plan time.
# With no env args: template-layer fragments are still checked against their own
# template's pools. Accepts config.yaml and config.yaml.sample paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

for a in "$@"; do
  case "$a" in
    -h|--help) echo "usage: $0 [<env-config.yaml>...]"; exit 0 ;;
    -*) echo "usage: $0 [<env-config.yaml>...]" >&2; exit 2 ;;
  esac
done

# Template roots move with the provider-package regroup; probe both layouts.
template_glob() {
  # prints existing template dirs: <root>/<provider>/<role>/<name>
  for d in providers/*/templates/*/* config/templates/*/*/*; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

template_dir_for() {
  # template_dir_for <provider> <role> <template>
  for d in "providers/$1/templates/$2/$3" "config/templates/$1/$2/$3"; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

findings=0

# pool_files <dir> <subdir> — basenames (sans extension) of pool-keyed files
pool_files() {
  local d="$1/$2"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -exec basename {} \; | sed 's/\.ya\{0,1\}ml$//' | { grep -vx 'proxmox' || true; }
}

check_dir_bindings() {
  # check_dir_bindings <base-dir> <pool-set> <what>
  local base="$1" pools="$2" what="$3" sub f
  for sub in talos proxmox; do
    for f in $(pool_files "$base" "$sub"); do
      if ! printf '%s\n' "$pools" | grep -qxF "$f"; then
        echo "$base/$sub/$f.yaml: names no pool of $what — this fragment silently never applies (pools: $(printf '%s' "$pools" | tr '\n' ' ' | sed 's/ $//'))"
        findings=$((findings+1))
      fi
    done
  done
}

# --- 1. Template-layer fragments vs the template's own pool set --------------
while IFS= read -r t; do
  [ -n "$t" ] || continue
  pl="$t/placement.yaml"
  [ -f "$pl" ] || continue
  pools=$(yq eval '.node_groups[].name' "$pl" 2>/dev/null | sed '/^$/d' | sort -u) || continue
  [ -n "$pools" ] || continue
  check_dir_bindings "$t" "$pools" "template $(basename "$(dirname "$(dirname "$t")")")/$(basename "$(dirname "$t")")/$(basename "$t")"
done < <(template_glob | sort -u)

# --- 2. Environment-layer fragments vs the effective pool set ----------------
for cfg in "$@"; do
  if [ ! -f "$cfg" ]; then
    echo "usage error: config file not found: $cfg" >&2
    exit 2
  fi
  envdir="$(cd "$(dirname "$cfg")" && pwd)"
  envname="$(basename "$envdir")"
  provider=$(yq eval '.infra.provider // ""' "$cfg" 2>/dev/null) || provider=""
  role=$(yq eval '.cluster.role // ""' "$cfg" 2>/dev/null) || role=""
  template=$(yq eval '.template // ""' "$cfg" 2>/dev/null) || template=""
  if [ -z "$provider" ] || [ -z "$role" ] || [ -z "$template" ]; then
    echo "$cfg:1: missing infra.provider / cluster.role / template — pool bindings cannot be derived"
    findings=$((findings+1))
    continue
  fi
  if ! tdir=$(template_dir_for "$provider" "$role" "$template"); then
    echo "$cfg:1: selected template directory not found ($provider/$role/$template)"
    findings=$((findings+1))
    continue
  fi
  pools=$(yq eval '.node_groups[].name' "$tdir/placement.yaml" 2>/dev/null | sed '/^$/d')

  envpl=""
  for c in "$envdir/placement.yaml" "$envdir/placement.yaml.sample"; do
    [ -f "$c" ] && { envpl="$c"; break; }
  done
  if [ -n "$envpl" ]; then
    for k in $(yq eval '.pools // {} | keys | .[]' "$envpl" 2>/dev/null); do
      # NOTE: not `.enabled // true` — yq's // treats false as empty and
      # would flip an explicit `enabled: false` back to true.
      enabled=$(yq eval ".pools.\"$k\".enabled" "$envpl")
      if [ "$enabled" = "false" ]; then
        pools=$(printf '%s\n' "$pools" | grep -vxF "$k" || true)
      else
        pools="$pools
$k"
      fi
    done
  fi
  pools=$(printf '%s\n' "$pools" | sed '/^$/d' | sort -u)

  check_dir_bindings "$envdir" "$pools" "env '$envname' ($provider/$role/$template)"
done

if [ "$findings" -gt 0 ]; then
  echo "check-bindings: $findings finding(s)"
  exit 1
fi
echo "check-bindings: OK"
