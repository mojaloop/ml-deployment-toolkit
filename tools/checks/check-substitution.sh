#!/usr/bin/env bash
# Usage: check-substitution.sh [--tf <dir>]... [<dir>]...  — lint ${...} substitution token syntax in gitops/, config/patches/talos/ and any extra dirs (--tf marks a dir as Terraform-substituted, where %{ is also forbidden).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Scan roots: "tf:<dir>" or "plain:<dir>", one per line (bash 3.2 — no assoc arrays).
SCAN_LIST="plain:gitops
plain:config/patches/talos"

while [ $# -gt 0 ]; do
  case "$1" in
    --tf)
      [ $# -ge 2 ] || { echo "usage: $0 [--tf <dir>]... [<dir>]..." >&2; exit 2; }
      SCAN_LIST="$SCAN_LIST
tf:$2"
      shift 2 ;;
    -h|--help)
      echo "usage: $0 [--tf <dir>]... [<dir>]..."; exit 0 ;;
    -*)
      echo "usage: $0 [--tf <dir>]... [<dir>]..." >&2; exit 2 ;;
    *)
      SCAN_LIST="$SCAN_LIST
plain:$1"
      shift ;;
  esac
done

findings=0

scan_file() {
  # $1 = file, $2 = "tf" or "plain"
  local f="$1" mode="$2" tfcheck out
  # %{ is checked only in --tf-marked (environment-layer) dirs. DTK-internal
  # *.tpl files are Terraform-native templates (never seen by Flux) — the
  # engine-parity %{ rule never applies to them.
  tfcheck=0
  if [ "$mode" = "tf" ]; then tfcheck=1; fi
  # *.tpl files are also exempt from the UPPER_SNAKE token rule: their ${...}
  # are templatefile() variables internal to DTK, not adopter-facing
  # substitution parameters. Operator forms would be HCL errors there anyway.
  lcheck=1
  case "$f" in
    *.tpl) tfcheck=0; lcheck=0 ;;
  esac
  out=$(awk -v tfcheck="$tfcheck" -v lcheck="$lcheck" '
    {
      line = $0
      # drop escaped literals $${...} — never substitutions
      gsub(/\$\$\{[^}]*\}/, "", line)
      if (tfcheck == 1) {
        tfl = line
        gsub(/%%\{/, "", tfl)                       # %%{ is an escaped literal
        if (tfl ~ /%\{/)
          printf "%s:%d: Terraform directive %%{ forbidden in Terraform-substituted file\n", FILENAME, FNR
      }
      rest = line
      while (match(rest, /\$\{[^}]*\}/)) {
        tok = substr(rest, RSTART + 2, RLENGTH - 3)
        if (tok !~ /^[A-Z][A-Z0-9_]*$/) {
          if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            if (lcheck == 1)
              printf "%s:%d: lowercase substitution token (target is UPPER_SNAKE): ${%s}\n", FILENAME, FNR, tok
          } else
            printf "%s:%d: forbidden operator form in substitution token: ${%s}\n", FILENAME, FNR, tok
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }' "$f")
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    findings=$((findings + $(printf '%s\n' "$out" | wc -l | tr -d ' ')))
  fi
}

OLDIFS="$IFS"; IFS='
'
for entry in $SCAN_LIST; do
  IFS="$OLDIFS"
  mode="${entry%%:*}"
  dir="${entry#*:}"
  if [ ! -d "$dir" ]; then
    echo "warning: directory not found, skipping: $dir" >&2
    IFS='
'
    continue
  fi
  # *.yaml.sample: examples/environments mirrors adopter env dirs with a .sample
  # suffix — same substitution rules apply.
  # ALL file types: generator-inlined scripts are substitution surface too —
  # a ${lower} in a .sh file fails strict post-build substitution in-cluster
  # exactly like one in a manifest (the harbor proxy-cache script proved it).
  files=$(find "$dir" -type f | sort)
  for f in $files; do
    scan_file "$f" "$mode"
  done
  IFS='
'
done
IFS="$OLDIFS"

if [ "$findings" -gt 0 ]; then
  echo "check-substitution: $findings finding(s)"
  exit 1
fi
echo "check-substitution: OK"
