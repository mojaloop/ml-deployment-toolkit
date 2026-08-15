#!/usr/bin/env bash
# Usage: check-token-resolution.sh — role-aware undefined-token check: every ${UPPER} substitution
# token referenced in gitops/ must be resolvable from what src/modules/flux-config/main.tf actually
# puts in cluster-config/cluster-secrets for the cluster role that applies the layer. Tokens that
# only exist on hub clusters (the is_hub block) may not be referenced from non-hub layers
# (top-level gitops dirs not starting with "hub"), and a token resolvable nowhere is always a
# finding.
#
# Parsing limits (deliberate, marker-driven — keep in sync when editing main.tf):
#   - cluster-config keys come from the marker comments "# TOKEN-KEYS: common" and
#     "# TOKEN-KEYS: hub-only" in src/modules/flux-config/main.tf; the hub-only region ends at the
#     conditional's closing "} : {},". Keys are matched as `^\s+UPPER_SNAKE\s*=` assignments.
#   - secret keys are best-effort: the Makefile SECRET_KEYS list, P_* provider symbols from
#     config/schemas/params.schema.json, UPPER_SNAKE string literals in main.tf (generated
#     password names in quoted lists, lookup() keys), and UPPER_SNAKE assignments in main.tf
#     outside the hub-only marker region (dns/cert/cluster-secrets data keys). Dynamically named
#     secrets (e.g. MINIO_BUCKET_<NAME>_SECRET_KEY) cannot be derived statically and would surface
#     as findings if a gitops manifest ever referenced one directly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }

TF="src/modules/flux-config/main.tf"
SCHEMA="config/schemas/params.schema.json"
[ -f "$TF" ] || { echo "error: $TF not found" >&2; exit 2; }
[ -d gitops ] || { echo "error: gitops/ not found" >&2; exit 2; }

findings=0

# --- HUB-ONLY cluster-config keys (marker region) ---------------------------
HUB_ONLY=$(awk '
  /# TOKEN-KEYS: hub-only/ { inhub = 1; next }
  inhub && /^[[:space:]]*\} : \{\},/ { inhub = 0 }
  inhub && match($0, /^[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*=/) {
    key = $0; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]*=.*/, "", key); print key
  }' "$TF" | sort -u)

# --- COMMON cluster-config keys (marker region) -----------------------------
COMMON=$(awk '
  /# TOKEN-KEYS: common/ { incommon = 1; next }
  /# TOKEN-KEYS: hub-only/ { incommon = 0 }
  incommon && match($0, /^[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*=/) {
    key = $0; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]*=.*/, "", key); print key
  }' "$TF" | sort -u)

if [ -z "$COMMON" ] || [ -z "$HUB_ONLY" ]; then
  echo "$TF:1: TOKEN-KEYS marker comments not found (or empty regions) — token resolution cannot be verified"
  echo "check-token-resolution: 1 finding(s)"
  exit 1
fi

# --- Always-available names -------------------------------------------------
# P_* provider interface symbols
P_KEYS=""
if [ -f "$SCHEMA" ]; then
  P_KEYS=$(jq -r '(.properties.params.properties // {}) | keys[]' "$SCHEMA")
else
  echo "warning: $SCHEMA not found — P_* tokens will look unresolvable" >&2
fi

# External credential names from the Makefile SECRET_KEYS list (backslash-continued)
SECRET_KEYS=$(awk '
  /^SECRET_KEYS[[:space:]]*:=/ { collecting = 1 }
  collecting {
    line = $0
    sub(/^SECRET_KEYS[[:space:]]*:=/, "", line)
    cont = (line ~ /\\[[:space:]]*$/)
    gsub(/\\/, "", line)
    n = split(line, w, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (w[i] ~ /^[A-Z][A-Z0-9_]*$/) print w[i]
    if (!cont) collecting = 0
  }' Makefile | sort -u)
[ -n "$SECRET_KEYS" ] || echo "warning: SECRET_KEYS not found in Makefile — secret tokens will look unresolvable" >&2

# UPPER_SNAKE string literals in main.tf (generated password names, lookup() keys)
TF_LITERALS=$(grep -oE '"[A-Z][A-Z0-9_]+"' "$TF" | tr -d '"' | sort -u)

# UPPER_SNAKE assignments in main.tf outside the hub-only marker region
# (dns_credentials, cert_credentials, cluster-secrets data keys like
# DNS_PROVIDER_CREDENTIALS / HARBOR_ROBOTS_JSON that exist on every role)
TF_ASSIGNS=$(awk '
  /# TOKEN-KEYS: hub-only/ { inhub = 1; next }
  inhub && /^[[:space:]]*\} : \{\},/ { inhub = 0; next }
  !inhub && match($0, /^[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*=/) {
    key = $0; sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]*=.*/, "", key); print key
  }' "$TF" | sort -u)

RESOLVABLE_COMMON=$(printf '%s\n%s\n%s\n%s\n%s\n' \
  "$COMMON" "$P_KEYS" "$SECRET_KEYS" "$TF_LITERALS" "$TF_ASSIGNS" | sed '/^$/d' | sort -u)

# --- Scan gitops tokens ------------------------------------------------------
# Emit "file:line:token" with $${...} escapes stripped first (escaped literals
# reach the workload untouched — never substituted).
refs=$(find gitops -type f \( -name '*.yaml' -o -name '*.yml' \) | sort | xargs awk '
  {
    line = $0
    gsub(/\$\$\{[^}]*\}/, "", line)
    rest = line
    while (match(rest, /\$\{[A-Z][A-Z0-9_]*\}/)) {
      tok = substr(rest, RSTART + 2, RLENGTH - 3)
      printf "%s:%d:%s\n", FILENAME, FNR, tok
      rest = substr(rest, RSTART + RLENGTH)
    }
  }')

OLDIFS="$IFS"; IFS='
'
for ref in $refs; do
  IFS="$OLDIFS"
  loc="${ref%:*}"
  tok="${ref##*:}"
  layer="${loc#gitops/}"; layer="${layer%%/*}"
  if printf '%s\n' "$RESOLVABLE_COMMON" | grep -qxF "$tok"; then
    IFS='
'
    continue
  fi
  if printf '%s\n' "$HUB_ONLY" | grep -qxF "$tok"; then
    case "$layer" in
      hub*) ;;   # hub layer referencing a hub-only key — fine
      *)
        echo "$loc: \${$tok} is hub-only (is_hub block in $TF) but referenced in non-hub layer '$layer' — substitution fails on tooling/bare clusters"
        findings=$((findings+1)) ;;
    esac
  else
    echo "$loc: \${$tok} resolves to no cluster-config/cluster-secrets key or provider symbol — substitution will fail"
    findings=$((findings+1))
  fi
  IFS='
'
done
IFS="$OLDIFS"

if [ "$findings" -gt 0 ]; then
  echo "check-token-resolution: $findings finding(s)"
  exit 1
fi
echo "check-token-resolution: OK"
