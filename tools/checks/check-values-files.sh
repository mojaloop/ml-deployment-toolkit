#!/usr/bin/env bash
# Usage: check-values-files.sh — every values/<ns>/<release>.yaml in the three override layers
# (gitops/*/values/, providers/<provider>/templates/<role>/<template>/values/,
# <ENVIRONMENTS_ROOT>/*/values/) must correspond to an existing HelmRelease in gitops/
# (spec.targetNamespace = <ns>, metadata.name = <release>) — a values file that binds to no
# HelmRelease is a silently unused override. Every patches/<name>.yaml under templates and
# environments must name a known Flux Kustomization for the same reason.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

ENVS_ROOT="${ENVIRONMENTS_ROOT:-../environments}"

# Flux Kustomization names — mirrors the Kustomization graph declared in
# src/engine/flux-config/main.tf. Patch files are named <kustomization>.yaml;
# a name outside this list patches nothing. Keep in sync when adding layers.
# (check-token-resolution.sh and check-all.sh rely on this file being the one
# shared place the list lives in tools/checks/.)
KUSTOMIZATIONS="platform
platform-config
talos
aws
gcp
tooling
tooling-config
tooling-routes
tooling-observability
tooling-observability-routes
hub
hub-vault
hub-iam
hub-iam-config
hub-app
hub-observability-agent
hub-data-common
hub-data-mysql
hub-data-mongodb
hub-data-kafka
hub-data-redis
dns-route53
dns-cloudflare
dns-digitalocean"

findings=0

# --- Collect every (targetNamespace/name) pair declared by a HelmRelease -----
hr_pairs=""
hr_files=$(grep -rl "kind: HelmRelease" gitops --include='*.yaml' --include='*.yml' 2>/dev/null | sort || true)
for f in $hr_files; do
  pairs=$(yq eval-all 'select(.kind == "HelmRelease") | (.spec.targetNamespace // "") + "/" + (.metadata.name // "")' "$f" 2>/dev/null) || {
    echo "$f:1: YAML parse error (yq could not read file)"; findings=$((findings+1)); continue; }
  hr_pairs="$hr_pairs
$pairs"
done
hr_pairs=$(printf '%s\n' "$hr_pairs" | sed '/^\/*$/d' | sort -u)
if [ -z "$hr_pairs" ]; then
  echo "gitops:1: no HelmRelease found anywhere in gitops/ — values-file binding cannot be verified"
  findings=$((findings+1))
fi

# check_values_root <root> — validate every values file under <root>/values/
# (relative layout <ns>/<release>.yaml, pair must match a HelmRelease).
check_values_root() {
  local vroot="$1" f rel ns release
  [ -d "$vroot" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$vroot"/}"
    case "$rel" in
      */*/*)
        echo "$f:1: values file nested deeper than values/<namespace>/<release>.yaml"
        findings=$((findings+1)); continue ;;
      */*) ;;
      *)
        echo "$f:1: values file not in values/<namespace>/<release>.yaml layout"
        findings=$((findings+1)); continue ;;
    esac
    ns="${rel%%/*}"
    release="$(basename "$rel")"; release="${release%.yml}"; release="${release%.yaml}"
    if ! printf '%s\n' "$hr_pairs" | grep -qxF "$ns/$release"; then
      echo "$f:1: values file binds to no HelmRelease (targetNamespace '$ns', release '$release') — typo'd namespace or release means a silently unused override"
      findings=$((findings+1))
    fi
  done < <(find "$vroot" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
}

# check_patches_root <root> — every patch file under <root>/patches/ must be
# named <kustomization>.yaml for a known Kustomization.
check_patches_root() {
  local proot="$1" f name
  [ -d "$proot" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name="$(basename "$f")"; name="${name%.yml}"; name="${name%.yaml}"
    if ! printf '%s\n' "$KUSTOMIZATIONS" | grep -qxF "$name"; then
      echo "$f:1: patch file names no known Flux Kustomization ('$name') — it would never be applied"
      findings=$((findings+1))
    fi
  done < <(find "$proot" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
}

# (a) gitops common release defaults
for d in gitops/*/values; do
  check_values_root "$d"
done

# (b) template overrides + patches
for t in providers/*/templates/*/*; do
  [ -d "$t" ] || continue
  check_values_root "$t/values"
  check_patches_root "$t/patches"
done

# (c) environment overrides + patches
if [ -d "$ENVS_ROOT" ]; then
  for e in "$ENVS_ROOT"/*; do
    [ -d "$e" ] || continue
    check_values_root "$e/values"
    check_patches_root "$e/patches"
  done
else
  echo "warning: environments root not found, skipping env layer: $ENVS_ROOT" >&2
fi

if [ "$findings" -gt 0 ]; then
  echo "check-values-files: $findings finding(s)"
  exit 1
fi
echo "check-values-files: OK"
