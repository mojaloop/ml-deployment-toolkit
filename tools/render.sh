#!/usr/bin/env bash
# Usage: render.sh <env> — OFFLINE render of everything an author just wrote, no
# cluster required:
#   a. values chains : for every HelmRelease in gitops/, merge the three-layer
#      chain (release default -> template layer -> environment layer) with Helm
#      semantics and write it to <artifacts>/<env>/render/values/<tns>/<rel>.yaml
#   b. manifests     : `kubectl kustomize` every top-most gitops layer into
#      <artifacts>/<env>/render/manifests/<layer>.yaml
#   c. talos         : validate pool fragment merges offline via
#      `talosctl gen config` + `talosctl validate`
# Roots default to ../environments and ../artifacts, overridable via
# ENVIRONMENTS_ROOT / ARTIFACTS_ROOT.
#
# Merge semantics: Helm merges maps deep and REPLACES lists wholesale. yq v4's
# `*` operator does exactly that — verified against a fixture:
#   m1: {a: {list: [1,2], map: {x: 1}}}  m2: {a: {list: [9], map: {y: 2}}}
#   yq eval-all '. as $item ireduce ({}; . * $item)' m1 m2
#     => {a: {list: [9], map: {x: 1, y: 2}}}   (list replaced, map deep-merged)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENVIRONMENTS_ROOT="${ENVIRONMENTS_ROOT:-../environments}"
ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-../artifacts}"

if [ $# -ne 1 ] || [ -z "${1:-}" ]; then
  echo "usage: $0 <env>   (reads ${ENVIRONMENTS_ROOT}/<env>/, writes ${ARTIFACTS_ROOT}/<env>/render/)" >&2
  exit 2
fi
ENV="$1"
ENV_DIR="$ENVIRONMENTS_ROOT/$ENV"
CFG="$ENV_DIR/config.yaml"
[ -f "$CFG" ] || { echo "error: $CFG not found" >&2; exit 2; }

provider=$(yq eval '.infra.provider // ""' "$CFG")
role=$(yq eval '.cluster.role // ""' "$CFG")
template=$(yq eval '.template // ""' "$CFG")
if [ -z "$provider" ] || [ -z "$role" ] || [ -z "$template" ]; then
  echo "error: $CFG must set infra.provider, cluster.role and template (got '$provider'/'$role'/'$template')" >&2
  exit 2
fi
TPL_DIR="config/templates/$provider/$role/$template"
[ -d "$TPL_DIR" ] || echo "warning: template dir $TPL_DIR not found — template layer will be absent" >&2

OUT="$ARTIFACTS_ROOT/$ENV/render"
# Disposable output — start clean so stale renders never linger.
rm -rf "$OUT/values" "$OUT/manifests"
mkdir -p "$OUT/values" "$OUT/manifests"

errors=0

# ---------------------------------------------------------------------------
# a. Values chains
# ---------------------------------------------------------------------------
values_rendered=0

render_chain() {
  # render_chain <layer> <tns> <rel>
  local layer="$1" tns="$2" rel="$3"
  local c1="gitops/$layer/values/$tns/$rel.yaml"
  local c2="$TPL_DIR/values/$tns/$rel.yaml"
  local c3="$ENV_DIR/values/$tns/$rel.yaml"
  local inputs="" f n=0
  for f in "$c1" "$c2" "$c3"; do
    if [ -f "$f" ]; then
      inputs="$inputs $f"
      n=$((n+1))
    fi
  done
  [ "$n" -gt 0 ] || return 0   # nothing to merge for this release

  local dst="$OUT/values/$tns/$rel.yaml"
  mkdir -p "$OUT/values/$tns"
  {
    echo "# Rendered by tools/render.sh — merged values chain for $tns/$rel (env: $ENV)"
    echo "# Merge order (Helm semantics: maps deep-merge, lists REPLACE):"
    for f in "$c1" "$c2" "$c3"; do
      if [ -f "$f" ]; then echo "#   + $f"; else echo "#   - $f (absent)"; fi
    done
    echo "# Substitution tokens (\${...}) are left in place: this render shows the"
    echo "# values chain, not the parameter resolution."
  } > "$dst"
  # shellcheck disable=SC2086  # inputs are repo paths without whitespace
  if yq eval-all '. as $item ireduce ({}; . * $item)' $inputs >> "$dst" 2>/dev/null; then
    values_rendered=$((values_rendered+1))
  else
    echo "FAIL values $tns/$rel: yq merge failed for:$inputs" >&2
    rm -f "$dst"
    errors=$((errors+1))
  fi
}

hr_files=$(find gitops -type f \( -name 'helmrelease*.yaml' -o -name '*-helmrelease.yaml' \) | sort)
for f in $hr_files; do
  layer=${f#gitops/}
  layer=${layer%%/*}
  rows=$(yq eval-all -o=json -I0 '.' "$f" 2>/dev/null | jq -r '
      select(type == "object" and .kind == "HelmRelease") |
      [ (.metadata.name // ""), (.spec.targetNamespace // .metadata.namespace // "") ] | @tsv') \
    || { echo "FAIL values: cannot parse $f" >&2; errors=$((errors+1)); continue; }
  [ -n "$rows" ] || continue
  while IFS=$'\t' read -r rel tns; do
    [ -n "$rel" ] && [ -n "$tns" ] || continue
    render_chain "$layer" "$tns" "$rel"
  done <<EOF
$rows
EOF
done

# ---------------------------------------------------------------------------
# b. Manifests — kustomize every TOP-MOST layer directory (a directory whose
#    kustomization.yaml is not already included by an ancestor's kustomization).
# ---------------------------------------------------------------------------
manifests_rendered=0
kdirs=$(find gitops -name kustomization.yaml -exec dirname {} \; | sort)
for d in $kdirs; do
  # Skip if any proper ancestor (under gitops/) also carries a kustomization.yaml.
  skip=0
  p=$(dirname "$d")
  while [ "$p" != "gitops" ] && [ "$p" != "." ] && [ "$p" != "/" ]; do
    if [ -f "$p/kustomization.yaml" ]; then skip=1; break; fi
    p=$(dirname "$p")
  done
  [ "$skip" -eq 0 ] || continue

  flat=$(printf '%s' "${d#gitops/}" | tr '/' '-')   # e.g. dns/route53 -> dns-route53
  dst="$OUT/manifests/$flat.yaml"
  if kubectl kustomize "$d" > "$dst" 2> "$dst.err"; then
    rm -f "$dst.err"
    manifests_rendered=$((manifests_rendered+1))
  else
    echo "FAIL manifests $d:" >&2
    sed 's/^/  /' "$dst.err" >&2
    rm -f "$dst" "$dst.err"
    errors=$((errors+1))
  fi
done

# ---------------------------------------------------------------------------
# c. Talos pool fragments — merge template-then-env fragments per pool through
#    `talosctl gen config`, then validate the resulting machine config.
# ---------------------------------------------------------------------------
talos_pools=0
frag_dirs=""
[ -d "$TPL_DIR/talos" ] && frag_dirs="$TPL_DIR/talos"
[ -d "$ENV_DIR/talos" ] && frag_dirs="$frag_dirs $ENV_DIR/talos"

pools=""
if [ -n "$frag_dirs" ]; then
  # shellcheck disable=SC2086
  pools=$(find $frag_dirs -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) \
            -exec basename {} \; 2>/dev/null | sed 's/\.ya\{0,1\}ml$//' | sort -u)
fi

if [ -z "$pools" ]; then
  echo "talos: no pool fragments found (checked ${TPL_DIR}/talos and ${ENV_DIR}/talos) — skipping"
else
  for pool in $pools; do
    # bash 3.2 + set -u: empty-array expansion is fatal, so collect the
    # --config-patch flags in the positional parameters instead.
    set --
    for dir in $frag_dirs; do        # template first, env second — env wins
      for ext in yaml yml; do
        [ -f "$dir/$pool.$ext" ] && set -- "$@" --config-patch "@$dir/$pool.$ext"
      done
    done
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/render-talos.XXXXXX")
    if talosctl gen config render-check https://10.0.0.1:6443 \
         --output-dir "$tmp" "$@" >/dev/null 2>"$tmp/gen.err" \
       && talosctl validate -m cloud -c "$tmp/controlplane.yaml" >/dev/null 2>"$tmp/val.err"; then
      echo "talos pool $pool: PASS"
      talos_pools=$((talos_pools+1))
    else
      echo "talos pool $pool: FAIL" >&2
      cat "$tmp/gen.err" "$tmp/val.err" 2>/dev/null | sed 's/^/  /' >&2
      errors=$((errors+1))
    fi
    rm -rf "$tmp"
  done
fi

# ---------------------------------------------------------------------------
echo ""
echo "render($ENV): values rendered $values_rendered, manifests $manifests_rendered, talos pools $talos_pools"
if [ "$errors" -gt 0 ]; then
  echo "render($ENV): $errors error(s)" >&2
  exit 1
fi
