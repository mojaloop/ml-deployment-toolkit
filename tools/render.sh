#!/usr/bin/env bash
# Usage: render.sh <env> — OFFLINE, byte-deterministic render of the full
# three-layer merge for one environment (design doc §3 "Rendering and audit").
# No cluster, no cloud credentials, no .env values in the output.
#
# Output (default <RENDER_ROOT>/<env>/, i.e. ../rendered/<env>/ — deliberately
# apart from secret-bearing artifacts/<env>/):
#   resolved.yaml   — the materialized configuration document, exported from a
#                     plan of src/render (the REAL config-loader merge, plus
#                     all its preconditions run at render time)
#   source.yaml     — the gitops artifact pin (url, version, digest)
#   values/<ns>/<release>.yaml — merged Helm values chain per release
#                     (common -> template -> environment, Helm semantics:
#                     maps deep-merge, lists REPLACE)
#   manifests/<layer>.yaml — `kubectl kustomize` of every top-most gitops layer
# Plus validation (no output): pool talos fragments merged through
# `talosctl gen config` + `talosctl validate`. Machine configs are validated
# but NOT emitted: gen config mints fresh cluster secrets on every run, so its
# output is both non-deterministic and secret-bearing.
#
# Substitution tokens (${...}) are left in place everywhere: the render shows
# COMPOSITION, not parameter resolution — which also keeps it secret-free and
# committable.
#
# Environment knobs:
#   ENVIRONMENTS_ROOT (../environments)   ARTIFACTS_ROOT (../artifacts)
#   RENDER_ROOT (../rendered)             OUT (override output dir; explain uses it)
#   MASK=environment|template  — render with that layer's override surfaces
#     masked (tools/explain.sh diffs it against the full render):
#       environment: env values/ + talos/ skipped; placement.yaml pool
#                    overrides stripped for the resolved document
#       template:    template values/ + talos/ skipped (the template's
#                    placement SHAPE cannot be masked — it is the base)
#   RESOLVE_DIGEST=1 — resolve the artifact tag to a digest via crane
#     (needs network + registry access; default records the tag pin only)
#
# Merge semantics note (values): Helm merges maps deep and REPLACES lists
# wholesale. yq v4's `*` operator does exactly that — verified against a
# fixture; explode(.) resolves anchors/aliases per input BEFORE merging.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENVIRONMENTS_ROOT="${ENVIRONMENTS_ROOT:-../environments}"
RENDER_ROOT="${RENDER_ROOT:-../rendered}"
MASK="${MASK:-}"

if [ $# -ne 1 ] || [ -z "${1:-}" ]; then
  echo "usage: $0 <env>   (reads ${ENVIRONMENTS_ROOT}/<env>/, writes ${RENDER_ROOT}/<env>/)" >&2
  exit 2
fi
case "$MASK" in ""|environment|template) ;; *)
  echo "error: MASK must be empty, 'environment' or 'template' (got '$MASK')" >&2; exit 2 ;;
esac

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
# Template roots move with the provider-package regroup; probe both layouts.
TPL_DIR=""
for d in "providers/$provider/templates/$role/$template" "config/templates/$provider/$role/$template"; do
  [ -d "$d" ] && { TPL_DIR="$d"; break; }
done
[ -n "$TPL_DIR" ] || { echo "error: template directory not found for $provider/$role/$template" >&2; exit 2; }

OUT="${OUT:-$RENDER_ROOT/$ENV}"
if [ -z "${MASK}" ] && [ ! -d "$RENDER_ROOT/.git" ]; then
  mkdir -p "$RENDER_ROOT"
  git -C "$RENDER_ROOT" init -q
  printf '%s\n' "# Rendered per-environment merge results (make render ENV=<env>)." \
    "# Byte-deterministic golden files: commit them, and review template or" \
    "# dtk_version bumps as diffs of this tree." > "$RENDER_ROOT/README.md"
fi
# Disposable output — start clean so stale renders never linger.
rm -rf "$OUT"
mkdir -p "$OUT/values" "$OUT/manifests"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/render.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

errors=0

# ---------------------------------------------------------------------------
# 0. Resolved configuration document — plan the resource-free src/render stack
#    and extract its `resolved` output. Never applied; plan alone runs every
#    config-loader precondition (validation at render time).
# ---------------------------------------------------------------------------
render_env_dir="$(cd "$ENV_DIR" && pwd)"
if [ "$MASK" = "environment" ]; then
  # Shadow environment: same identity (config.yaml), placement map kept (the
  # expansion needs real targets), pool OVERRIDES stripped, no overlays.
  mkdir -p "$WORK/shadow-env/$ENV"
  cp "$CFG" "$WORK/shadow-env/$ENV/config.yaml"
  if [ -f "$ENV_DIR/placement.yaml" ]; then
    yq eval 'del(.pools)' "$ENV_DIR/placement.yaml" > "$WORK/shadow-env/$ENV/placement.yaml"
  fi
  render_env_root="$(cd "$WORK/shadow-env" && pwd)"
else
  render_env_root="$(cd "$ENVIRONMENTS_ROOT" && pwd)"
fi

dtk_tag=$(git describe --tags --exact-match 2>/dev/null || true)

if terraform -chdir=src/render init -input=false >"$WORK/init.log" 2>&1 \
   && terraform -chdir=src/render plan -input=false -refresh=false \
        -var "env_name=$ENV" \
        -var "environments_dir=$render_env_root" \
        -var "dtk_tag=$dtk_tag" \
        -out="$WORK/render.tfplan" >"$WORK/plan.log" 2>&1; then
  terraform -chdir=src/render show -json "$WORK/render.tfplan" \
    | jq -S '.planned_values.outputs.resolved.value' > "$WORK/resolved.json"
  {
    echo "# Rendered by tools/render.sh — materialized configuration for env: $ENV"
    echo "# The single merge result both Terraform and Flux consume (keys sorted;"
    echo "# no secrets — .env never reaches the renderer)."
    yq -p json -o yaml '.' "$WORK/resolved.json"
  } > "$OUT/resolved.yaml"
  echo "resolved: OK"
else
  echo "FAIL resolved: config-loader plan failed (validation errors are the point of render-time checks):" >&2
  grep -E "Error|error_message|Invalid" "$WORK/init.log" "$WORK/plan.log" 2>/dev/null | head -40 | sed 's/^/  /' >&2 || true
  tail -5 "$WORK/plan.log" 2>/dev/null | sed 's/^/  /' >&2 || true
  errors=$((errors+1))
fi

# ---------------------------------------------------------------------------
# 0b. Artifact pin — the digest anchors the audit; a tag only names it.
# ---------------------------------------------------------------------------
art_url=$(yq eval '.artifact.url // ""' "$CFG")
art_ver=$(yq eval '.artifact.version // ""' "$CFG")
digest="(unresolved — run with RESOLVE_DIGEST=1 and registry access to pin)"
if [ "${RESOLVE_DIGEST:-0}" = "1" ] && [ -n "$art_url" ] && command -v crane >/dev/null 2>&1; then
  digest=$(crane digest "${art_url#oci://}:$art_ver" 2>/dev/null) || digest="(resolution failed)"
fi
{
  echo "# Distribution source pin for env: $ENV"
  echo "artifact:"
  echo "  url: \"$art_url\""
  echo "  version: \"$art_ver\""
  echo "  digest: \"$digest\""
} > "$OUT/source.yaml"

# ---------------------------------------------------------------------------
# a. Values chains
# ---------------------------------------------------------------------------
values_rendered=0

render_chain() {
  # render_chain <layer> <tns> <rel>
  local layer="$1" tns="$2" rel="$3"
  # Chain slots, in precedence order. Labels are LAYER-SYMBOLIC (path relative
  # to each layer root) so the rendered bytes survive tree reorganizations —
  # the regroup's empty-diff guarantee depends on it. The header always
  # reflects file PRESENCE (identical under MASK, so explain diffs stay
  # noise-free); masking only removes a layer from the merge inputs.
  local slots="common:gitops/$layer/values/$tns/$rel.yaml"
  slots="$slots provider:providers/$provider/gitops-delta/values/$tns/$rel.yaml"
  slots="$slots template:$TPL_DIR/values/$tns/$rel.yaml"
  slots="$slots environment:$ENV_DIR/values/$tns/$rel.yaml"

  local inputs="" label f n=0 s
  for s in $slots; do
    label="${s%%:*}"
    f="${s#*:}"
    if [ -f "$f" ]; then
      n=$((n+1))
      [ "$MASK" = "$label" ] || inputs="$inputs $f"
    fi
  done
  [ "$n" -gt 0 ] || return 0   # nothing to merge for this release
  [ -n "$inputs" ] || return 0 # only the masked layer contributes — chain absent without it

  local dst="$OUT/values/$tns/$rel.yaml"
  mkdir -p "$OUT/values/$tns"
  {
    echo "# Rendered by tools/render.sh — merged values chain for $tns/$rel (env: $ENV)"
    echo "# Merge order (Helm semantics: maps deep-merge, lists REPLACE):"
    for s in $slots; do
      label="${s%%:*}"
      f="${s#*:}"
      if [ -f "$f" ]; then
        echo "#   + $label:values/$tns/$rel.yaml"
      else
        echo "#   - $label (absent)"
      fi
    done
    echo "# Substitution tokens (\${...}) are left in place: this render shows the"
    echo "# values chain, not the parameter resolution."
  } > "$dst"
  # shellcheck disable=SC2086  # inputs are repo paths without whitespace
  if yq eval-all 'explode(.) as $item ireduce ({}; . * $item)' $inputs >> "$dst" 2>/dev/null \
     && yq eval 'true' "$dst" >/dev/null 2>&1; then
    values_rendered=$((values_rendered+1))
  else
    echo "FAIL values $tns/$rel: merge failed or output unparseable for:$inputs" >&2
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
# c. Talos pool fragments (validation only) — merge template-then-env
#    fragments per pool through `talosctl gen config`, then validate.
#    Skipped under MASK (the full render already validated them).
# ---------------------------------------------------------------------------
talos_pools=0
if [ -z "$MASK" ]; then
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
fi

# ---------------------------------------------------------------------------
echo ""
echo "render($ENV${MASK:+, mask=$MASK}): resolved config, values $values_rendered, manifests $manifests_rendered, talos pools $talos_pools -> $OUT"
if [ "$errors" -gt 0 ]; then
  echo "render($ENV): $errors error(s)" >&2
  exit 1
fi
