#!/usr/bin/env bash
# Shared resolution for the perf commands.
#
# WHERE THINGS LIVE
#   ../environments/<env>/perf-topology.yaml     where the participants are
#   ../environments/<env>/perf-scenarios/*.yaml  what tests to run against them
#   perf-result/<env>/<scenario>/<ts>/           results (in this repo)
#   perf/                                        this code, and nothing else
#
# Configuration sits beside the deployment configuration it belongs to, in the
# adopter-owned environment repo OUTSIDE this clone (sibling layout; override
# the root via ENVIRONMENTS_ROOT). Results never embed it: a result records
# WHICH environment and WHAT test, never where the endpoints were. That means
# a result is reproducible only if you also hold the environment's repo —
# exactly the property `make plan-apply` already has.
#
# Dependencies: yq, jq, k6.

set -euo pipefail

PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$PERF_DIR/.." && pwd)"
# Environments live OUTSIDE the clone as project-root siblings.
ENV_ROOT="${ENVIRONMENTS_ROOT:-$REPO_ROOT/../environments}"
RESULT_ROOT="$REPO_ROOT/perf-result"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

require_tools() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "$t is required but not on PATH"
  done
}

list_envs() {
  ls -1 "$ENV_ROOT" 2>/dev/null | while read -r e; do
    [ -f "$ENV_ROOT/$e/perf-topology.yaml" ] && echo "$e"
  done | tr '\n' ' '
}

topology_path() {
  local env="$1"
  local path="$ENV_ROOT/${env}/perf-topology.yaml"
  [ -f "$path" ] || die "no topology at $path
       Copy examples/environments/hub/perf-topology.yaml.sample (in the clone) and edit it.
       Environments with a topology: $(list_envs)"
  echo "$path"
}

list_scenarios() {
  local env="$1"
  ls -1 "$ENV_ROOT/${env}/perf-scenarios/" 2>/dev/null | sed 's/\.yaml$//' | tr '\n' ' '
}

scenario_path() {
  local env="$1" name="$2"
  local path="$ENV_ROOT/${env}/perf-scenarios/${name}.yaml"
  [ -f "$path" ] || die "no scenario at $path
       Available for ${env}: $(list_scenarios "$env")"
  echo "$path"
}

# Fail before generating load rather than halfway through it. Every check here
# is one whose failure would otherwise be reported as a switch problem.
validate_topology() {
  local topo="$1"
  local n; n="$(yq -r '.participants | length' "$topo")"
  [ "$n" -ge 1 ] || die "topology declares no participants"

  local dupes; dupes="$(yq -r '.participants[].id' "$topo" | sort | uniq -d)"
  [ -z "$dupes" ] || die "duplicate participant ids: $dupes"

  local i=0
  while [ "$i" -lt "$n" ]; do
    local id start end
    id="$(yq -r ".participants[$i].id" "$topo")"
    start="$(yq -r ".participants[$i].msisdn.start" "$topo")"
    end="$(yq -r ".participants[$i].msisdn.end" "$topo")"
    [ "$id" != "null" ] && [ -n "$id" ] || die "participant [$i] has no id"
    [ "$start" != "null" ] && [ "$end" != "null" ] || die "$id: msisdn.start/end required"
    [ "$end" -ge "$start" ] || die "$id: msisdn.end ($end) is below msisdn.start ($start)"
    for u in register_sim register_als discovery quotes transfers; do
      local v; v="$(yq -r ".participants[$i].urls.$u // \"\"" "$topo")"
      [ -n "$v" ] || die "$id: urls.$u is missing — every endpoint must be declared in full"
      case "$v" in
        http://*|https://*) ;;
        *) die "$id: urls.$u must be a complete URL including scheme, got '$v'" ;;
      esac
    done
    i=$((i + 1))
  done

  # Overlapping ranges make a lookup ambiguous: two participants claiming the
  # same identifier means the ALS answers for one of them arbitrarily.
  local overlap
  overlap="$(yq -r '.participants[] | "\(.msisdn.start) \(.msisdn.end) \(.id)"' "$topo" \
    | sort -n \
    | awk '{ if (NR>1 && $1 <= prev_end) printf "%s overlaps %s\n", $3, prev_id; prev_end=$2; prev_id=$3 }')"
  [ -z "$overlap" ] || die "overlapping MSISDN ranges: $overlap"
}

# Every pair must reference participants that exist, or the run fails per
# iteration with an error that looks nothing like its cause.
validate_pairs() {
  local topo="$1" scen="$2"
  local ids; ids="$(yq -r '.participants[].id' "$topo")"
  local n; n="$(yq -r '.pairs | length' "$scen")"
  [ "$n" -ge 1 ] || die "scenario declares no pairs"
  local i=0
  while [ "$i" -lt "$n" ]; do
    for side in source dest; do
      local v; v="$(yq -r ".pairs[$i].$side" "$scen")"
      grep -qxF "$v" <<<"$ids" || die "pair[$i].$side '$v' is not a participant in this topology"
    done
    i=$((i + 1))
  done
}

# Overrides arrive as make variables. Empty means "not set" — never a value.
# Applied in exactly one place so the snapshot is a complete record of the run.
apply_overrides() {
  local doc; doc="$(cat)"
  local o='{}'
  [ -n "${TPS:-}" ]             && o="$(jq --argjson v "$TPS" '.load.tps = $v' <<<"$o")"
  [ -n "${DURATION:-}" ]        && o="$(jq --arg v "$DURATION" '.load.duration = $v' <<<"$o")"
  [ -n "${WARMUP:-}" ]          && o="$(jq --arg v "$WARMUP" '.load.warmup = $v' <<<"$o")"
  [ -n "${STEPS:-}" ]           && o="$(jq --arg v "$STEPS" '.load.steps = ($v | split(",") | map(tonumber))' <<<"$o")"
  [ -n "${STEP_DURATION:-}" ]   && o="$(jq --arg v "$STEP_DURATION" '.load.step_duration = $v' <<<"$o")"
  [ -n "${SHAPE:-}" ]           && o="$(jq --arg v "$SHAPE" '.load.shape = $v' <<<"$o")"
  [ -n "${CURRENCY:-}" ]        && o="$(jq --arg v "$CURRENCY" '.workload.currency = $v' <<<"$o")"
  [ -n "${AMOUNT:-}" ]          && o="$(jq --arg v "$AMOUNT" '.workload.amount = $v' <<<"$o")"
  [ -n "${REQUEST_TIMEOUT:-}" ] && o="$(jq --arg v "$REQUEST_TIMEOUT" '.request_timeout = $v' <<<"$o")"
  [ -n "${SLO_TARGET:-}" ]      && o="$(jq --argjson v "$SLO_TARGET" '.slo.target = $v' <<<"$o")"
  [ -n "${TRACE_SAMPLE_MS:-}" ] && o="$(jq --argjson v "$TRACE_SAMPLE_MS" '.trace_sample_every_ms = $v' <<<"$o")"
  jq -s '.[0] * .[1]' <(echo "$doc") <(echo "$o")
}

# The document k6 consumes: topology + scenario + overrides. Contains endpoint
# URLs, so it is written to a temporary location and never into a result.
build_config() {
  local topo="$1" scen="${2:-}" out="$3"
  if [ -n "$scen" ]; then
    yq -o=json eval-all 'select(fi==0) * select(fi==1)' "$topo" "$scen" | apply_overrides > "$out"
  else
    yq -o=json '.' "$topo" | apply_overrides > "$out"
  fi
}

# What is archived with a result: the test as it actually ran, with overrides
# applied. Deliberately excludes the topology — a result records which
# environment, not where its endpoints were.
build_scenario_snapshot() {
  local scen="$1" out="$2"
  yq -o=json '.' "$scen" | apply_overrides | yq -P '.' > "$out"
}

# WHAT WAS DEPLOYED when this ran. Without it a result is a number with no
# subject: two runs a fortnight apart are incomparable, and the change under
# test — which is exactly what values/ and patches/ carry — is unrecorded.
#
# environments/<env>/ lives outside this repository (its own adopter repo), so
# NONE of this is recoverable from THIS repo afterwards. Copied, not referenced.
#
# Copied from disk rather than read back from the cluster. These files are the
# deployment inputs, and a copy needs no kubeconfig, so provenance does not
# cost the client-side-only property (1.3).
capture_deployment() {
  local env="$1" out="$2"
  mkdir -p "$out"

  # Six keys, never the whole file. The rest of config.yaml is WHERE things
  # are — VIPs, DNS, registry, object storage, alerting targets — which a
  # result must not carry (9.3). These six are WHAT ran: the sizing profile,
  # the artifact tag, the data-layer modes, the API flavour, and the physical
  # placement that decides which host's disks the run competed for.
  local cfg="$ENV_ROOT/$env/config.yaml"
  if [ -f "$cfg" ]; then
    yq -P '{
      "version":  .version,
      "template": .template,
      "infra":    .infra,
      "artifact": .artifact,
      "data":     .data,
      "app":      {"api_type": .app.api_type}
    }' "$cfg" > "$out/config.yaml"
  fi

  # Helm value overrides and kustomize patches, verbatim. The source layout is
  # mirrored rather than flattened so `diff -r` between two results'
  # deployment/ directories reads as the change between the runs.
  #
  # Both directories are optional: an environment that overrides nothing is
  # not an error, and an absent directory must not abort a run.
  local d
  for d in values patches; do
    compgen -G "$ENV_ROOT/$env/$d/*.yaml" >/dev/null 2>&1 || continue
    mkdir -p "$out/$d"
    cp "$ENV_ROOT/$env/$d"/*.yaml "$out/$d/"
  done
}

# Where the generator ran belongs in the report: it is inside every latency
# figure, and comparing runs from different vantage points is meaningless.
generator_host() {
  echo "$(hostname 2>/dev/null || echo unknown)"
}

kubeconfig_from() {
  local topo="$1"
  local kc; kc="$(yq -r '.cluster.kubeconfig // ""' "$topo")"
  [ -n "$kc" ] || return 1
  case "$kc" in
    /*) echo "$kc" ;;
    *)  echo "$REPO_ROOT/$kc" ;;
  esac
}
