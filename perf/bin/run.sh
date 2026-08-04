#!/usr/bin/env bash
# make perf-run ENV=<env> SCENARIO=<name> [overrides...]
#
# Resolves topology + scenario + overrides, runs k6, and writes a result.
#
# The result deliberately does NOT contain the topology. It records which
# environment ran and what test ran; the endpoints live in
# environments/<env>/perf-topology.yaml and are managed like any other
# deployment config. A result is therefore reproducible only if you also hold
# that config — the same property `make plan-apply` has.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools yq jq k6

[ -n "${ENV:-}" ] || die "usage: make perf-run ENV=<env> SCENARIO=<name>"
[ -n "${SCENARIO:-}" ] || die "usage: make perf-run ENV=<env> SCENARIO=<name>
       Available for ${ENV}: $(list_scenarios "$ENV")"

TOPO="$(topology_path "$ENV")"
SCEN="$(scenario_path "$ENV" "$SCENARIO")"

validate_topology "$TOPO"
validate_pairs "$TOPO" "$SCEN"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_DIR="$RESULT_ROOT/$ENV/$SCENARIO/$RUN_ID"
mkdir -p "$OUT_DIR"

# The resolved config carries endpoint URLs, so it lives in a temp dir for the
# duration of the run and is never written into the result.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CONFIG="$WORK/config.json"
build_config "$TOPO" "$SCEN" "$CONFIG"
build_scenario_snapshot "$SCEN" "$OUT_DIR/scenario-snapshot.yaml"

# WHAT was deployed, beside WHAT was run. Captured before load starts, from
# the environment's own files — no cluster access, so this never weakens the
# client-side-only guarantee.
capture_deployment "$ENV" "$OUT_DIR/deployment"

echo "== $SCENARIO on $ENV =="
info "run id     $RUN_ID"
info "shape      $(jq -r '.load.shape' "$CONFIG")"
info "gate       $(jq -r '"\(.slo.success_rate * 100)% within \(.slo.target)s"' "$CONFIG")"
info "result     ${OUT_DIR#"$REPO_ROOT/"}"
echo

# --- pre-run health snapshot ----------------------------------------------
# Optional throughout. Without cluster access the run proceeds and the result
# records that health was not observed — it is never a blocker.
KUBECONFIG_PATH="$(kubeconfig_from "$TOPO" || true)"
NS="$(yq -r '.cluster.namespace // "mojaloop"' "$TOPO")"
restarts_now() {
  [ -n "$KUBECONFIG_PATH" ] && [ -f "$KUBECONFIG_PATH" ] || return 1
  kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NS" get pods -o json 2>/dev/null \
    | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0' 2>/dev/null
}
PRE_RESTARTS="$(restarts_now || echo "")"

# --- telemetry sinks -------------------------------------------------------
# All optional: without them the run still produces a complete result, only
# the live dashboards go dark. Declared in the topology because they are a
# property of the environment; the env vars exist to override per invocation.
#
# Note the asymmetry. k6 pushes METRICS and its own LOGS. It emits no spans,
# so traces_url is recorded for linking and nothing is exported to it — the
# spans come from the hub and DFSP services via their own agents.
METRICS_URL="${PERF_METRICS_URL-$(jq -r '.observability.metrics_url // ""' "$CONFIG")}"
TRACES_URL="$(jq -r '.observability.traces_url // ""' "$CONFIG")"
INSECURE="$(jq -r '.observability.insecure_skip_tls_verify // false' "$CONFIG")"

# OPT-IN via SHIP_LOGS=1. k6 supports a single --log-output, so shipping to
# Loki REPLACES stderr: errors stop appearing in your terminal. Default to
# visible; ship only when the run is long enough to be unattended.
LOGS_URL=""
[ "${SHIP_LOGS:-0}" = "1" ] && LOGS_URL="${PERF_LOGS_URL-$(jq -r '.observability.logs_url // ""' "$CONFIG")}"

K6_OUT=()
if [ -n "$METRICS_URL" ]; then
  K6_OUT=(-o experimental-prometheus-rw)
  export K6_PROMETHEUS_RW_SERVER_URL="$METRICS_URL"
  export K6_PROMETHEUS_RW_TREND_STATS="${PERF_TREND_STATS:-p(50),p(90),p(95),p(99),avg,max}"
  export K6_PROMETHEUS_RW_PUSH_INTERVAL="${PERF_PUSH_INTERVAL:-5s}"
  export K6_PROMETHEUS_RW_INSECURE_SKIP_TLS_VERIFY="$INSECURE"
  info "metrics -> $METRICS_URL (testid=$RUN_ID)"
else
  info "metrics -> not pushed (set observability.metrics_url in the topology)"
fi

if [ -n "$LOGS_URL" ]; then
  K6_OUT+=(--log-output "loki=${LOGS_URL}?label.testid=${RUN_ID}&label.scenario=${SCENARIO}&label.env=${ENV}")
  info "logs    -> $LOGS_URL (testid=$RUN_ID; stderr is now silent)"
fi

[ -n "$TRACES_URL" ] && info "traces  -> $TRACES_URL (produced by the services, not pushed by k6)"
echo

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
PERF_CONFIG="$CONFIG" \
PERF_RUN_ID="$RUN_ID" \
PERF_SCENARIO="$SCENARIO" \
PERF_TOPOLOGY="$ENV" \
PERF_OUT_DIR="$OUT_DIR" \
PERF_GENERATOR_HOST="$(generator_host)" \
PERF_LOGS_SHIPPED="$([ -n "$LOGS_URL" ] && echo 1 || echo 0)" \
  k6 run --quiet "${K6_OUT[@]+"${K6_OUT[@]}"}" "$PERF_DIR/k6/transfer.js"
K6_EXIT=$?
set -e
ENDED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- post-run health -------------------------------------------------------
# A disturbed run is a tainted RESULT, not a blocked one, so this is recorded
# beside the numbers rather than used as a gate.
POST_RESTARTS="$(restarts_now || echo "")"
if [ -n "$PRE_RESTARTS" ] && [ -n "$POST_RESTARTS" ]; then
  DELTA=$((POST_RESTARTS - PRE_RESTARTS))
  OOM="$(kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NS" get pods -o json 2>/dev/null \
    | jq -c '[.items[]
        | .metadata.name as $pod
        | .status.containerStatuses[]?
        | select(.lastState.terminated.reason == "OOMKilled")
        | {pod: $pod, finishedAt: .lastState.terminated.finishedAt}]' 2>/dev/null || echo '[]')"
  jq -n --arg s "$STARTED" --arg e "$ENDED" --argjson d "$DELTA" --argjson oom "$OOM" \
    '{observed:true, started:$s, ended:$e, restart_delta:$d, oom_killed:$oom,
      tainted: ($d > 0 or ($oom|length) > 0)}' > "$OUT_DIR/health.json"
else
  jq -n --arg s "$STARTED" --arg e "$ENDED" \
    '{observed:false, started:$s, ended:$e,
      note:"no cluster access — system health during this run is unknown"}' \
    > "$OUT_DIR/health.json"
fi

# --- notes stub ------------------------------------------------------------
# Prompts, never placeholders masquerading as results: summary.json already
# holds every number, so nothing here is load-bearing if left unwritten.
if [ ! -f "$OUT_DIR/notes.md" ]; then
  cat > "$OUT_DIR/notes.md" <<EOF
# $SCENARIO — $RUN_ID ($ENV)

Numbers: \`summary.json\`. Test as run: \`scenario-snapshot.yaml\`. Health: \`health.json\`.
Endpoints are not recorded here — see \`environments/$ENV/perf-topology.yaml\`.

## Hypothesis

## What changed since the last run

## Reading

## Conclusion
EOF
fi

echo
TAINTED="$(jq -r '.tainted // false' "$OUT_DIR/health.json")"
if [ "$TAINTED" = "true" ]; then
  echo "HEALTH: TAINTED — $(jq -r '.restart_delta' "$OUT_DIR/health.json") restarts during the run."
  echo "        Per-process counters reset on restart; treat these figures with suspicion."
elif [ "$(jq -r '.observed' "$OUT_DIR/health.json")" = "false" ]; then
  echo "HEALTH: not observed (no cluster access)."
else
  echo "HEALTH: clean."
fi
echo "result: ${OUT_DIR#"$REPO_ROOT/"}"

exit $K6_EXIT
