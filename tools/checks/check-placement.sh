#!/usr/bin/env bash
# Usage: check-placement.sh [<env-config.yaml>...] — env-aware node-pool placement contract.
# Node labels derive mechanically from pool names (<P_NODE_ROLE_LABEL_KEY>=<pool>, see
# config/definitions/workload-classes.yaml), so every node-role value gitops selects on must be a
# pool that actually exists for the environment. Per env config the effective pool set is:
#   names in providers/<infra.provider>/templates/<cluster.role>/<template>/placement.yaml node_groups
#   MINUS env placement.yaml pools overridden with enabled: false
#   PLUS  env placement.yaml pools keys not in the template (enabled != false)
# gitops references where the label key is ${P_NODE_ROLE_LABEL_KEY} or literal node-role:
#   HARD (nodeSelector map entries, matchLabels, required matchExpressions) with a value outside
#        the pool set = finding — the workload can never schedule;
#   SOFT (preferredDuringSchedulingIgnoredDuringExecution matchExpressions, tolerations) outside
#        the pool set = stderr warning only — soft affinity degrades by design.
# ${...} values are skipped (not statically checkable). With no env args, falls back to
# warning-only validation against the union of all template pool names.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

for a in "$@"; do
  case "$a" in
    -h|--help) echo "usage: $0 [<env-config.yaml>...]"; exit 0 ;;
    -*) echo "usage: $0 [<env-config.yaml>...]" >&2; exit 2 ;;
  esac
done
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

NRK='${P_NODE_ROLE_LABEL_KEY}'
findings=0

# --- Collect node-role references from gitops -------------------------------
# One "kind<TAB>file<TAB>value" per line. kind = hard|soft, classified by the
# YAML path of the reference (preferred* / tolerations => soft).
REFS=""
while IFS= read -r f; do
  # style A — label as a map KEY (nodeSelector entries, matchLabels)
  a=$(yq eval-all ".. | select(type == \"!!map\") | select(has(\"node-role\") or has(\"$NRK\")) | [(path | join(\"/\")), (.[\"node-role\"] // .[\"$NRK\"])] | select(.[1] | tag == \"!!str\") | @tsv" "$f" 2>/dev/null) || {
    echo "$f:1: YAML parse error (yq could not read file)"; findings=$((findings+1)); continue; }
  # style B — {key: <label>, value: v} / {key: <label>, values: [...]}
  # (tolerations, nodeAffinity matchExpressions); values joined with commas.
  b=$(yq eval-all ".. | select(type == \"!!map\") | select(.key == \"node-role\" or .key == \"$NRK\") | [(path | join(\"/\")), ([(.value // \"\")] + (.values // []) | map(select(tag == \"!!str\")) | join(\",\"))] | @tsv" "$f" 2>/dev/null) || true

  OLDIFS="$IFS"; IFS='
'
  for row in $a $b; do
    IFS="$OLDIFS"
    p="${row%%	*}"
    vlist="${row#*	}"
    kind="hard"
    case "$p" in
      *preferredDuringSchedulingIgnoredDuringExecution*|*tolerations*) kind="soft" ;;
    esac
    for v in $(printf '%s' "$vlist" | tr ',' '\n'); do
      [ -n "$v" ] || continue
      REFS="$REFS
$kind	$f	$v"
    done
    IFS='
'
  done
  IFS="$OLDIFS"
done < <(find gitops -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
REFS=$(printf '%s\n' "$REFS" | sed '/^$/d' | sort -u)

# ref_line <file> <value> — best-effort line number for a finding (prefer a
# quoted occurrence, the usual shape of tolerations/matchExpressions values)
ref_line() {
  local ln
  ln=$(grep -n -- "\"$2\"" "$1" 2>/dev/null | head -1 | cut -d: -f1 || true)
  [ -n "$ln" ] || ln=$(grep -n -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1 || true)
  printf '%s' "$ln"
}

# validate_refs <pool-set> <label> <hard-is-finding(0|1)>
validate_refs() {
  local pools="$1" label="$2" hard_finds="$3" kind f v ln
  [ -n "$REFS" ] || return 0
  OLDIFS="$IFS"; IFS='
'
  for row in $REFS; do
    IFS="$OLDIFS"
    kind="${row%%	*}"
    f=$(printf '%s' "$row" | cut -f2)
    v="${row##*	}"
    case "$v" in
      *'$'*) IFS='
'; continue ;;   # templated value — cannot validate statically
    esac
    if ! printf '%s\n' "$pools" | grep -qxF "$v"; then
      ln=$(ref_line "$f" "$v")
      if [ "$kind" = "hard" ] && [ "$hard_finds" = "1" ]; then
        echo "$f:${ln:-1}: hard node-role selector '$v' is not a pool of $label — the workload can never schedule there"
        findings=$((findings+1))
      else
        echo "warning: $f:${ln:-1}: soft node-role reference '$v' is not a pool of $label (soft affinity degrades by design)" >&2
      fi
    fi
    IFS='
'
  done
  IFS="$OLDIFS"
}

if [ $# -eq 0 ]; then
  # Fallback: no environment context — union of every template's pool names,
  # warning-only (a value alien to ALL templates is at best suspicious).
  union=""
  for t in providers/*/templates/*/*/placement.yaml; do
    [ -f "$t" ] || continue
    union="$union
$(yq eval '.node_groups[].name' "$t" 2>/dev/null || true)"
  done
  union=$(printf '%s\n' "$union" | sed '/^$/d' | sort -u)
  if [ -z "$union" ]; then
    echo "warning: no template placement.yaml files found — nothing to validate against" >&2
  else
    validate_refs "$union" "any template (union of all pool names)" 0
  fi
else
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
      echo "$cfg:1: missing infra.provider / cluster.role / template — pool contract cannot be derived"
      findings=$((findings+1))
      continue
    fi
    tpl="providers/$provider/templates/$role/$template/placement.yaml"
    if [ ! -f "$tpl" ]; then
      echo "$cfg:1: selected template has no placement.yaml ($tpl)"
      findings=$((findings+1))
      continue
    fi
    pools=$(yq eval '.node_groups[].name' "$tpl" | sed '/^$/d')

    # env placement.yaml pool overrides (placement.yaml.sample for examples)
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

    validate_refs "$pools" "env '$envname' ($provider/$role/$template; pools: $(printf '%s' "$pools" | tr '\n' ' ' | sed 's/ $//'))" 1
  done
fi

if [ "$findings" -gt 0 ]; then
  echo "check-placement: $findings finding(s)"
  exit 1
fi
echo "check-placement: OK"
