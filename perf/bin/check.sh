#!/usr/bin/env bash
# make perf-check ENV=<env>
#
# Standalone readiness gate. NOT run automatically before a load test — system
# readiness is its own concern, and a measurement tool should not decide when
# your cluster is fit to measure.
#
# What it protects against: starting a run moments after a rollout, which
# measures consumer-group rebalancing rather than the system, and produces a
# number that looks real and is not.
#
# Requires cluster access. Everything else in this suite does not.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools yq kubectl

[ -n "${ENV:-}" ] || die "usage: make perf-check ENV=<name>
       Environments with a topology: $(list_envs)"
TOPO="$(topology_path "$ENV")"

KUBECONFIG_PATH="$(kubeconfig_from "$TOPO" || true)"
[ -n "$KUBECONFIG_PATH" ] || die "topology has no cluster.kubeconfig — nothing to check"
[ -f "$KUBECONFIG_PATH" ] || die "kubeconfig not found: $KUBECONFIG_PATH"

NS="$(yq -r '.cluster.namespace // "mojaloop"' "$TOPO")"
KAFKA_NS="$(yq -r '.cluster.kafka.namespace // "data"' "$TOPO")"
KAFKA_PORT="$(yq -r '.cluster.kafka.port // 9404' "$TOPO")"
KAFKA_SVC="$(yq -r '.cluster.kafka.service // ""' "$TOPO")"
SETTLE_MIN="${SETTLE_SECONDS:-180}"

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

FAILED=0
report() { # name, status, detail
  printf "  %-34s %-8s %s\n" "$1" "$2" "${3:-}"
  [ "$2" = "FAIL" ] && FAILED=1
  return 0
}

echo "== readiness: $ENV (namespace $NS) =="

# --- pending pods ----------------------------------------------------------
PENDING="$(k -n "$NS" get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$PENDING" = "0" ]; then report "pending pods" "OK" "0"
else report "pending pods" "FAIL" "$PENDING pending"; fi

# --- settle time -----------------------------------------------------------
# Pod readiness precedes consumer-group stability. A container that started
# seconds ago means its group is still rebalancing, and a run begun now
# measures that, not the system.
YOUNGEST="$(k -n "$NS" get pods -o json 2>/dev/null | python3 -c '
import json,sys,datetime
now = datetime.datetime.now(datetime.timezone.utc)
ages = [(now - datetime.datetime.fromisoformat(cs["state"]["running"]["startedAt"].replace("Z","+00:00"))).total_seconds()
        for p in json.load(sys.stdin)["items"]
        for cs in p["status"].get("containerStatuses", [])
        if "running" in cs.get("state", {})]
print(int(min(ages)) if ages else 999999)')"
if [ "$YOUNGEST" -ge "$SETTLE_MIN" ]; then report "settle since last start" "OK" "${YOUNGEST}s"
else report "settle since last start" "FAIL" "${YOUNGEST}s (want >=${SETTLE_MIN}s)"; fi

# --- recent restarts -------------------------------------------------------
RESTARTS="$(k -n "$NS" get pods -o json 2>/dev/null | python3 -c '
import json,sys
print(sum(cs.get("restartCount",0) for p in json.load(sys.stdin)["items"] for cs in p["status"].get("containerStatuses",[])))')"
report "restart count (informational)" "INFO" "$RESTARTS"

# --- kafka lag on transfer-path topics only --------------------------------
# Audit topics carry their own steady-state lag and must never gate this
# check; gating on total lag makes the gate unpassable on a healthy system.
TOPICS="$(yq -r '.cluster.kafka.topics[]? ' "$TOPO" | tr '\n' '|' | sed 's/|$//')"
if [ -z "$TOPICS" ]; then
  report "kafka lag" "SKIP" "no cluster.kafka.topics declared"
else
  if [ -z "$KAFKA_SVC" ]; then
    KAFKA_SVC="$(k -n "$KAFKA_NS" get svc -o json 2>/dev/null | python3 -c "
import json,sys
port = int('$KAFKA_PORT')
for s in json.load(sys.stdin).get('items', []):
    for p in s['spec'].get('ports', []):
        if p.get('port') == port:
            print(s['metadata']['name']); raise SystemExit
" || true)"
  fi

  if [ -z "$KAFKA_SVC" ]; then
    report "kafka lag" "SKIP" "no service exposing port $KAFKA_PORT in ns $KAFKA_NS"
  else
    PF_PORT=$((20000 + RANDOM % 10000))
    k -n "$KAFKA_NS" port-forward "svc/$KAFKA_SVC" "$PF_PORT:$KAFKA_PORT" >/dev/null 2>&1 &
    PF_PID=$!
    # Always reap the tunnel, including on error or interrupt.
    trap 'kill '"$PF_PID"' 2>/dev/null || true' EXIT INT TERM
    for _ in $(seq 1 20); do
      curl -sf -m 1 "http://127.0.0.1:$PF_PORT/metrics" >/dev/null 2>&1 && break
      sleep 0.5
    done

    LAG="$(curl -sf -m 10 "http://127.0.0.1:$PF_PORT/metrics" 2>/dev/null \
      | awk -v re="$TOPICS" '
          /^kafka_consumergroup_lag\{/ {
            if (match($0, /topic="[^"]*"/)) {
              t = substr($0, RSTART+7, RLENGTH-8)
              if (t ~ "^(" re ")$") {
                # The exporter emits -1 for a group with no committed offset.
                # That is "unknown", not "zero backlog" — counting it as
                # negative would let real lag on another topic cancel out.
                if ($NF > 0) sum += $NF; else if ($NF < 0) unknown++
              }
            }
          }
          END { printf "%d %d", sum + 0, unknown + 0 }')"
    LAG_UNKNOWN="${LAG##* }"
    LAG="${LAG%% *}"

    kill "$PF_PID" 2>/dev/null || true
    trap - EXIT INT TERM

    if [ -z "$LAG" ]; then report "kafka lag (transfer path)" "SKIP" "exporter unreachable"
    elif [ "$LAG" -le "${MAX_LAG:-0}" ]; then report "kafka lag (transfer path)" "OK" "$LAG${LAG_UNKNOWN:+ (+$LAG_UNKNOWN group(s) with no committed offset)}"
    else report "kafka lag (transfer path)" "FAIL" "$LAG messages outstanding"; fi
  fi
fi

echo
if [ "$FAILED" = "0" ]; then
  echo "READY"
else
  echo "NOT READY — a run started now measures the system settling, not the system."
  exit 1
fi
