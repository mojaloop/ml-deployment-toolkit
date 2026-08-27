#!/usr/bin/env bash
# Usage: check-all.sh — run every repo-state check (all except check-pristine, which is an adopter/apply-time gate) and print a PASS/FAIL summary.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }

# Environment config.yaml files feed check-interface (P_* keys are forbidden
# there), check-literals and check-placement.
ENVS_ROOT="${ENVIRONMENTS_ROOT:-../environments}"
ENV_CONFIGS=""
for c in "$ENVS_ROOT"/*/config.yaml; do
  [ -f "$c" ] && ENV_CONFIGS="$ENV_CONFIGS $c"
done

# Sample environments ship the same files with a .sample suffix — check-literals
# scans them against their own config.yaml.sample.
SAMPLE_CONFIGS=""
for c in examples/environments/*/config.yaml.sample; do
  [ -f "$c" ] && SAMPLE_CONFIGS="$SAMPLE_CONFIGS $c"
done

# Environment-layer dirs are Terraform-substituted (templatefile) — %{ directives
# are forbidden there on top of the plain token rules (--tf in check-substitution).
TF_DIRS=""
for d in "$ENVS_ROOT"/*/values "$ENVS_ROOT"/*/patches "$ENVS_ROOT"/*/talos \
         examples/environments/*/values examples/environments/*/patches examples/environments/*/talos; do
  [ -d "$d" ] && TF_DIRS="$TF_DIRS --tf $d"
done

SUMMARY=""
FAILED=0

run_check() {
  # $1 = script name, rest = args
  local name="$1" status
  shift
  echo ""
  echo "=== $name ==="
  if "$HERE/$name" "$@"; then
    status="PASS"
  else
    status="FAIL"
    FAILED=1
  fi
  SUMMARY="$SUMMARY
$(printf '  %-28s %s' "$name" "$status")"
}

run_check check-tools.sh
run_check check-substitution.sh $TF_DIRS
run_check check-valuesfrom.sh
run_check check-interface.sh $ENV_CONFIGS
run_check check-secret-placement.sh
run_check check-literals.sh $ENV_CONFIGS $SAMPLE_CONFIGS
run_check check-values-files.sh
run_check check-placement.sh $ENV_CONFIGS
run_check check-bindings.sh $ENV_CONFIGS $SAMPLE_CONFIGS
run_check check-talos-fragments.sh
run_check check-token-resolution.sh
run_check check-engine-parity.sh

echo ""
echo "=== Summary ==="
printf '%s\n' "$SUMMARY" | sed '/^$/d'

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "check-all: FAILED (one or more checks reported findings)"
  exit 1
fi
echo ""
echo "check-all: all checks passed"
