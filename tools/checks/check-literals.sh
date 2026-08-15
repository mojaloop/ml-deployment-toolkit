#!/usr/bin/env bash
# Usage: check-literals.sh [<env-config.yaml>...] — hardcoded-literal lint. Values that config.yaml
# parameterizes (cluster.name, dns.domain, observability.*_url) must never appear verbatim in that
# environment's values/, patches/ or talos/ overlay files — reference the substitution ${TOKEN}
# instead (finding). Any OTHER config.yaml string leaf found verbatim in an overlay is a
# single-source-hygiene warning on stderr (no token exists to point to, so it cannot be a finding).
# Sample configs (examples/environments/*/config.yaml.sample) are scanned the same way against
# their *.yaml.sample overlays.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

for a in "$@"; do
  case "$a" in
    -h|--help) echo "usage: $0 [<env-config.yaml>...]"; exit 0 ;;
    -*) echo "usage: $0 [<env-config.yaml>...]" >&2; exit 2 ;;
  esac
done

findings=0

# PARAMETERIZED map: config.yaml path -> substitution token (bash 3.2 — no assoc
# arrays, one "path token" pair per line). These values have a canonical ${TOKEN}
# in cluster-config (src/modules/flux-config/main.tf), so a literal occurrence in
# an overlay is a drift bug waiting to happen.
PARAM_MAP='.cluster.name CLUSTER_NAME
.dns.domain DOMAIN
.observability.loki_url LOKI_URL
.observability.mimir_url MIMIR_URL
.observability.tempo_url TEMPO_URL'

# scan_hits <file> <value> — line numbers where <value> occurs OUTSIDE YAML
# comments (a comment mentioning the cluster name is prose, not a drift bug).
# Naive comment stripping: everything from the first '#'; '#' inside a quoted
# value is rare enough in overlay YAML to accept the false negative.
scan_hits() {
  awk -v v="$2" '{
    line = $0
    c = index(line, "#")
    if (c > 0) line = substr(line, 1, c - 1)
    if (index(line, v) > 0) print FNR
  }' "$1"
}

# overlay_files <envdir> — the env overlay files subject to the lint.
overlay_files() {
  local envdir="$1" d
  for d in "$envdir/values" "$envdir/patches" "$envdir/talos"; do
    [ -d "$d" ] || continue
    find "$d" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.yaml.sample' -o -name '*.yml.sample' \)
  done | sort
}

for cfg in "$@"; do
  if [ ! -f "$cfg" ]; then
    echo "usage error: config file not found: $cfg" >&2
    exit 2
  fi
  envdir="$(cd "$(dirname "$cfg")" && pwd)"
  files=$(overlay_files "$envdir")
  [ -n "$files" ] || continue

  # --- Parameterized values: literal occurrence = finding -------------------
  param_values=""
  OLDIFS="$IFS"; IFS='
'
  for pair in $PARAM_MAP; do
    IFS="$OLDIFS"
    path="${pair%% *}"
    token="${pair##* }"
    val=$(yq eval "$path // \"\"" "$cfg" 2>/dev/null) || { echo "$cfg:1: YAML parse error (yq could not read file)"; findings=$((findings+1)); break; }
    IFS='
'
    [ -n "$val" ] || continue
    [ "${#val}" -ge 4 ] || continue
    param_values="$param_values
$val"
    for f in $files; do
      for ln in $(scan_hits "$f" "$val"); do
        printf "%s:%s: hardcoded literal '%s' — reference \${%s} instead\n" "$f" "$ln" "$val" "$token"
        findings=$((findings + 1))
      done
    done
  done
  IFS="$OLDIFS"

  # --- Other config.yaml string leaves: verbatim occurrence = stderr warning
  # (single-source hygiene — the value has no substitution token, so the fix is
  # judgement, not mechanics).
  leaves=$(yq eval '.. | select(tag == "!!str") | [(path | join(".")), .] | @tsv' "$cfg" 2>/dev/null) || leaves=""
  OLDIFS="$IFS"; IFS='
'
  for leaf in $leaves; do
    IFS="$OLDIFS"
    lpath="${leaf%%	*}"
    lval="${leaf#*	}"
    IFS='
'
    [ "${#lval}" -ge 6 ] || continue
    # pure numbers / booleans carry no identity worth tracing
    case "$lval" in
      ''|true|false|True|False) continue ;;
    esac
    if printf '%s' "$lval" | grep -qE '^[0-9.]+$'; then continue; fi
    # already reported above as a finding
    if printf '%s\n' "$param_values" | grep -qxF -- "$lval"; then continue; fi
    for f in $files; do
      for ln in $(scan_hits "$f" "$lval"); do
        printf "warning: %s:%s: config value '%s' (%s in %s) duplicated verbatim — consider single-sourcing\n" "$f" "$ln" "$lval" "$lpath" "$cfg" >&2
      done
    done
  done
  IFS="$OLDIFS"
done

if [ "$findings" -gt 0 ]; then
  echo "check-literals: $findings finding(s)"
  exit 1
fi
echo "check-literals: OK"
