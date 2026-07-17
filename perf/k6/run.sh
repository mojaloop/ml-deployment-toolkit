#!/usr/bin/env bash
# Perf-run wrapper: health-gated k6 execution with pre/post deltas.
# Every number in RESULTS.md should come from a run made through this script —
# it refuses to start on a dirty system and flags runs that dirtied it.
#
# Usage:
#   TESTID=ramp-foo SCENARIO=ramp ./run.sh [extra k6 env as VAR=val...]
#   TESTID=soak-bar TPS=10 DURATION=30m ./run.sh
set -euo pipefail

cd "$(dirname "$0")"
: "${TESTID:?set TESTID}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
KUBECONFIG_ML_TEST="$REPO_ROOT/artifacts/ml-test/kubernetes/kubeconfig"
THANOS="https://thanos.int.cc1.pj1.moja-do.delma.me"
NS=mojaloop

k() { kubectl --kubeconfig "$KUBECONFIG_ML_TEST" "$@"; }

kafka_lag() {
  curl -sk --max-time 15 "$THANOS/api/v1/query" \
    --data-urlencode 'query=clamp_min(sum(kafka_consumergroup_lag{cluster_name="ml-test"}),0)' -G |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["value"][1])) if r else -1)'
}

restarts_total() {
  k -n "$NS" get pods -o json |
    python3 -c 'import json,sys; print(sum(cs.get("restartCount",0) for p in json.load(sys.stdin)["items"] for cs in p["status"].get("containerStatuses",[])))'
}

pending_pods() { k -n "$NS" get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' '; }

node_mem() { k top nodes --no-headers | awk '{printf "%s:%s ", $1, $5}'; }

echo "== pre-flight =="
for i in $(seq 1 30); do
  LAG=$(kafka_lag)
  [ "$LAG" -le 0 ] && break
  echo "  kafka lag=$LAG, waiting (attempt $i/30)..."; sleep 20
done
[ "${LAG:-1}" -le 0 ] || { echo "ABORT: kafka lag=$LAG after 10min"; exit 1; }
PRE_RESTARTS=$(restarts_total)
[ "$(pending_pods)" = "0" ] || { echo "ABORT: pending pods in $NS"; k -n "$NS" get pods --field-selector=status.phase=Pending; exit 1; }

# Settle gate: pod readiness precedes Kafka group stability — a run started
# right after a rollout measures rebalance chaos, not the system (learned the
# hard way, see ramp-target5 in RESULTS.md). Require newest container start
# to be >=180s old.
for i in $(seq 1 20); do
  YOUNGEST=$(k -n "$NS" get pods -o json | python3 -c '
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
ages=[(now-datetime.datetime.fromisoformat(cs["state"]["running"]["startedAt"].replace("Z","+00:00"))).total_seconds()
      for p in json.load(sys.stdin)["items"] for cs in p["status"].get("containerStatuses",[])
      if "running" in cs.get("state",{})]
print(int(min(ages)) if ages else 9999)')
  [ "$YOUNGEST" -ge 180 ] && break
  echo "  settle gate: newest container ${YOUNGEST}s old, waiting..."; sleep 30
done
[ "$YOUNGEST" -ge 180 ] || { echo "ABORT: pods still churning"; exit 1; }
echo "  kafka lag: 0 | restarts: $PRE_RESTARTS | settle: ${YOUNGEST}s | node mem: $(node_mem)"

echo "== run: $TESTID =="
START_UTC=$(date -u +%H:%M:%SZ)
set +e
K6_PROMETHEUS_RW_SERVER_URL="$THANOS/api/v1/receive" \
K6_PROMETHEUS_RW_TREND_STATS='p(50),p(90),p(99),avg,max' \
K6_PROMETHEUS_RW_PUSH_INTERVAL=5s \
K6_PROMETHEUS_RW_INSECURE_SKIP_TLS_VERIFY=true \
TESTID="$TESTID" k6 run -o experimental-prometheus-rw --quiet transfers.js
K6_EXIT=$?
set -e
END_UTC=$(date -u +%H:%M:%SZ)

echo "== post-flight =="
POST_RESTARTS=$(restarts_total)
DELTA=$((POST_RESTARTS - PRE_RESTARTS))
OOM=$(k -n "$NS" get pods -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    for cs in p["status"].get("containerStatuses",[]):
        t=cs.get("lastState",{}).get("terminated",{})
        if t.get("reason")=="OOMKilled": print(p["metadata"]["name"], t.get("finishedAt"))')
echo "  k6 exit: $K6_EXIT | restart delta: $DELTA | node mem: $(node_mem)"
[ -n "$OOM" ] && echo "  recent OOMKilled:"$'\n'"$OOM"

VERDICT="CLEAN"
[ "$DELTA" -gt 0 ] && VERDICT="TAINTED (restart delta=$DELTA)"
cat >> "$REPO_ROOT/perf/RESULTS.md" <<EOF

### \`$TESTID\` ($(date -u +%Y-%m-%d) ${START_UTC} to ${END_UTC}) — TODO: hypothesis/result
Health: $VERDICT. Restart delta: $DELTA. k6 exit: $K6_EXIT.
TODO: headline numbers, lag location, conclusion.
EOF
echo "== RESULTS.md skeleton appended ($VERDICT) =="
