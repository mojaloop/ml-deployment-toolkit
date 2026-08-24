#!/usr/bin/env bash
# make perf-seed ENV=<env>
#
# Registers every participant's MSISDN range in its own party repository and
# in the scheme ALS, then verifies a sample resolves end to end.
#
# This command owns the correctness of the test data. A load run does not
# re-check it, so an incomplete seed reported here is the only warning you get.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools yq jq k6

[ -n "${ENV:-}" ] || die "usage: make perf-seed ENV=<name>
       Environments with a topology: $(list_envs)"

TOPO="$(topology_path "$ENV")"
validate_topology "$TOPO"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CONFIG="$WORK/config.json"
build_config "$TOPO" "" "$CONFIG"

echo "== seeding $ENV =="
# Arithmetic via jq, NOT yq: yq loses integer precision at MSISDN magnitudes
# and silently returns wrong counts (20100009003 - 20100009001 + 1 == 1).
jq -r '.participants[] | "  \(.id)  \(.msisdn.start)..\(.msisdn.end)  (\(.msisdn.end - .msisdn.start + 1) identifiers)"' "$CONFIG"
echo

# OPT-IN via SHIP_LOGS=1. k6 supports a single --log-output, so shipping
# to Loki REPLACES stderr: errors stop appearing in your terminal. Default
# to visible; ship only when the run is long enough to be unattended.
LOGS_URL=""
[ "${SHIP_LOGS:-0}" = "1" ] && LOGS_URL="${PERF_LOGS_URL-$(jq -r '.observability.logs_url // ""' "$CONFIG")}"
K6_LOG=()
if [ -n "$LOGS_URL" ]; then
  # obs-ingest basic auth as URL userinfo — see run.sh for the reasoning.
  load_obs_creds "$TOPO"
  K6_LOG=(--log-output "loki=$(url_with_obs_creds "$LOGS_URL")?label.perf_step=seed&label.topology=${ENV}")
  info "logs -> $LOGS_URL (stderr is now silent)"
  echo
fi

PERF_CONFIG="$CONFIG" \
PERF_VERIFY_SAMPLES="${VERIFY_SAMPLES:-5}" \
PERF_SEED_MAX_DURATION="${SEED_MAX_DURATION:-60m}" \
PERF_SEED_ALS_TIMEOUT="${SEED_ALS_TIMEOUT:-300s}" \
  k6 run --quiet "${K6_LOG[@]+"${K6_LOG[@]}"}" "$PERF_DIR/k6/seed.js"
