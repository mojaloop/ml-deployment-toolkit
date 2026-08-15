#!/usr/bin/env bash
# Usage: check-talos-fragments.sh — every talos patch fragment (config/patches/talos/,
# config/templates/<provider>/<role>/<name>/talos/, <env>/talos/) must:
#   1. parse as YAML once ${...} tokens are stubbed
#   2. not be a JSON6902 patch (strategic-merge fragments only; Talos rejects
#      JSON6902 on multi-document configs)
#   3. carry a valid document identity: bare docs must be v1alpha1-shaped
#      (machine/cluster/debug/persist top-level keys only); docs with kind:
#      must name a known Talos document kind — a typo'd kind/name silently
#      APPENDS a new document instead of patching the intended one
#   4. not restate append-semantics lists: Talos APPENDS lists by default, so
#      the same list path stated with an identical entry in two sources that
#      reach the same nodes (base patches + a pool fragment, or the template
#      and environment fragment of one pool) duplicates it on merge. Keyed
#      lists (network interfaces/vlans) and replace-tagged lists (pod/service
#      subnets, audit policy) are exempt. Same path in two sources WITHOUT a
#      shared entry is a stderr warning (verify the entries stay disjoint).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }

TMP=$(mktemp "${TMPDIR:-/tmp}/talos-frag.XXXXXX")
trap 'rm -f "$TMP"' EXIT

findings=0
scanned=0

check_fragment() {
  local f="$1"
  scanned=$((scanned+1))
  # Stub substitution tokens (escaped and live) with a plain scalar before parsing.
  # *.tpl files are Terraform-native templates: drop directive-only %{...} lines
  # (for/endfor/if/endif, with optional ~ strip markers) and stub inline %{...}.
  case "$f" in
    *.tpl)
      sed -e '/^[[:space:]]*%{[^}]*}[[:space:]]*$/d' \
          -e 's/%{[^}]*}/x/g' \
          -e 's/\$\${[^}]*}/x/g' -e 's/\${[^}]*}/x/g' "$f" > "$TMP"
      ;;
    *)
      sed -e 's/\$\${[^}]*}/x/g' -e 's/\${[^}]*}/x/g' "$f" > "$TMP"
      ;;
  esac

  if ! yq eval-all '.' "$TMP" >/dev/null 2>&1; then
    echo "$f:1: does not parse as YAML (after stubbing \${...} tokens)"
    findings=$((findings+1))
    return
  fi

  # JSON6902 patch = top-level sequence whose items carry op: keys — forbidden here.
  local is6902
  is6902=$(yq eval-all 'select(type == "!!seq") | [.[] | select(type == "!!map") | has("op")] | any' "$TMP" 2>/dev/null || echo "false")
  if printf '%s\n' "$is6902" | grep -qx "true"; then
    ln=$(grep -nE '^[[:space:]]*-[[:space:]]*op:' "$f" | head -1 | cut -d: -f1 || true)
    echo "$f:${ln:-1}: JSON6902 patch is forbidden in talos dirs (use strategic-merge fragments)"
    findings=$((findings+1))
  fi
}

# Fixed root + target-state roots (silently absent until later phases).
for dir in config/patches/talos config/templates/*/*/*/talos "${ENVIRONMENTS_ROOT:-../environments}"/*/talos; do
  [ -d "$dir" ] || continue
  while IFS= read -r f; do
    check_fragment "$f"
  done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.tpl' \) | sort)
done

if [ "$scanned" -eq 0 ]; then
  echo "warning: no talos fragments found to check" >&2
fi

# --- Lints 3 + 4: document identity and duplicate-append detection ----------
deep_out=$(python3 - "${ENVIRONMENTS_ROOT:-../environments}" <<'PYEOF'
import glob, re, sys, yaml, itertools, os

env_root = sys.argv[1]
V1ALPHA1_KEYS = {"version", "machine", "cluster", "debug", "persist"}
# Talos 1.8-1.10 multi-doc kinds (update when Talos adds documents).
KNOWN_KINDS = {
    "SideroLinkConfig", "EventSinkConfig", "KmsgLogConfig", "WatchdogTimerConfig",
    "ExtensionServiceConfig", "UserVolumeConfig", "RawVolumeConfig",
    "ExistingVolumeConfig", "SwapVolumeConfig", "ZswapConfig", "VolumeConfig",
    "EthernetConfig", "TrustedRootsConfig", "PCIDriverRebindConfig",
    "NetworkDefaultActionConfig", "NetworkRuleConfig",
}
# Lists exempt from append-duplication: replace-tagged or merged by key.
EXEMPT_PATHS = {
    "cluster.network.podSubnets", "cluster.network.serviceSubnets",
    "cluster.apiServer.auditPolicy", "machine.network.interfaces",
}
findings, warnings = [], []

def stub(txt):
    txt = re.sub(r"%\{[^}]*\}", "x", txt)
    return re.sub(r"\$?\$\{[^}]*\}", "x", txt)

def list_paths(node, path, out):
    if isinstance(node, dict):
        for k, v in node.items():
            list_paths(v, path + [str(k)], out)
    elif isinstance(node, list):
        p = ".".join(path)
        if p not in EXEMPT_PATHS and not any(p.startswith(e + ".") for e in EXEMPT_PATHS):
            scalars = frozenset(str(x) for x in node if isinstance(x, (str, int, float, bool)))
            out[p] = scalars
            if len(scalars) < sum(1 for x in node if isinstance(x, (str, int, float, bool))):
                findings.append(f"{cur_file}:1: list '{p}' contains duplicate entries within one fragment")

def load(f):
    try:
        return [d for d in yaml.safe_load_all(stub(open(f).read())) if d is not None]
    except Exception:
        return []  # parse failures already reported by lint 1

def identity_check(f, docs):
    for d in docs:
        if not isinstance(d, dict):
            continue
        kind = d.get("kind")
        if kind is None:
            unknown = set(d) - V1ALPHA1_KEYS - {"apiVersion"}
            if unknown:
                findings.append(f"{f}:1: bare fragment has non-v1alpha1 top-level keys {sorted(unknown)} — a typo here patches nothing")
        elif kind not in KNOWN_KINDS:
            findings.append(f"{f}:1: unknown Talos document kind '{kind}' — Talos would silently APPEND a new document (typo?)")
        elif d.get("name"):
            warnings.append(f"{f}: {kind}/{d['name']} — a name matching no existing document appends a new one; verify it")

def paths_of(f):
    global cur_file
    cur_file = f
    out = {}
    for d in load(f):
        if isinstance(d, dict) and d.get("kind") is None:
            list_paths(d, [], out)
    return out

def compare(fa, pa, fb, pb, ctx):
    for p in set(pa) & set(pb):
        shared = pa[p] & pb[p]
        if shared:
            findings.append(f"{fb}:1: list '{p}' restates entry {sorted(shared)} already stated in {fa} ({ctx}) — Talos APPENDS: this duplicates on merge")
        else:
            warnings.append(f"{ctx}: both {fa} and {fb} append to '{p}' — verify entries stay disjoint")

base_files = sorted(glob.glob("config/patches/talos/*.yaml") + glob.glob("config/patches/talos/*.tpl"))
base_paths = [(f, paths_of(f)) for f in base_files]
for f, _ in base_paths:
    identity_check(f, load(f))

pool_sources = {}  # pool -> [(file, paths)]
for f in sorted(glob.glob("config/templates/*/*/*/talos/*.yaml") + glob.glob(f"{env_root}/*/talos/*.yaml")):
    pool = os.path.splitext(os.path.basename(f))[0]
    docs = load(f)
    identity_check(f, docs)
    pool_sources.setdefault(pool, []).append((f, paths_of(f)))

for pool, sources in pool_sources.items():
    for (fa, pa), (fb, pb) in itertools.combinations(sources, 2):
        compare(fa, pa, fb, pb, f"pool {pool}")
    for fb, pb in sources:
        for fa, pa in base_paths:
            compare(fa, pa, fb, pb, f"pool {pool} vs base patches")

for w in warnings:
    print(f"WARN {w}", file=sys.stderr)
for x in findings:
    print(x)
PYEOF
) || true
if [ -n "$deep_out" ]; then
  printf '%s\n' "$deep_out"
  findings=$((findings + $(printf '%s\n' "$deep_out" | wc -l | tr -d ' ')))
fi

if [ "$findings" -gt 0 ]; then
  echo "check-talos-fragments: $findings finding(s) in $scanned fragment(s)"
  exit 1
fi
echo "check-talos-fragments: OK ($scanned fragment(s))"
