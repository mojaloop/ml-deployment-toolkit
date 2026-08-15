#!/usr/bin/env bash
# Usage: support-bundle.sh <env> — build a WHITELIST-based support bundle for one
# environment. The artifacts tree holds plaintext machine secrets, kubeconfig,
# talosconfig and Terraform state, so this script never tars a directory
# wholesale: it stages an explicit whitelist and then verifies the finished
# archive contains nothing sensitive before handing it over.
#
# Included (and ONLY this):
#   environment/config.yaml, placement.yaml, talos.yaml, proxmox/   (never .env)
#   render/          — <artifacts>/<env>/render/ if present (offline render output)
#   meta.txt         — date, git describe/rev-parse of this clone, tool versions
#
# Output: <artifacts>/<env>/support-bundle-<UTC timestamp>.tar.gz (mode 0600).
# Exits 2 (and deletes the archive) if the post-build listing contains a path
# matching .env, tfstate, kubeconfig, talosconfig, or a secrets path segment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENVIRONMENTS_ROOT="${ENVIRONMENTS_ROOT:-../environments}"
ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-../artifacts}"

if [ $# -ne 1 ] || [ -z "${1:-}" ]; then
  echo "usage: $0 <env>   (reads ${ENVIRONMENTS_ROOT}/<env>/, writes ${ARTIFACTS_ROOT}/<env>/support-bundle-<ts>.tar.gz)" >&2
  exit 2
fi
ENV="$1"
ENV_DIR="$ENVIRONMENTS_ROOT/$ENV"
ART_DIR="$ARTIFACTS_ROOT/$ENV"
[ -d "$ENV_DIR" ] || { echo "error: environment dir $ENV_DIR not found" >&2; exit 2; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TOP="support-bundle-$ENV"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/support-bundle.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
BUNDLE_DIR="$STAGE/$TOP"
mkdir -p "$BUNDLE_DIR/environment"

# --- environment whitelist (explicit file list — .env is deliberately absent) --
for f in config.yaml placement.yaml talos.yaml; do
  if [ -f "$ENV_DIR/$f" ]; then
    cp "$ENV_DIR/$f" "$BUNDLE_DIR/environment/$f"
  else
    echo "note: $ENV_DIR/$f not present — omitted" >&2
  fi
done
if [ -d "$ENV_DIR/proxmox" ]; then
  cp -R "$ENV_DIR/proxmox" "$BUNDLE_DIR/environment/proxmox"
fi

# Assert the staging tree picked up no .env (belt and braces before tarring).
if find "$STAGE" -name '.env*' | grep -q .; then
  echo "error: staging tree contains a .env file — refusing to build bundle" >&2
  exit 2
fi

# --- rendered artifacts (offline render output only, never the artifacts root) --
if [ -d "$ART_DIR/render" ]; then
  cp -R "$ART_DIR/render" "$BUNDLE_DIR/render"
else
  echo "note: $ART_DIR/render not present — run tools/render.sh $ENV to include it" >&2
fi

# --- meta.txt ------------------------------------------------------------------
{
  echo "support bundle for environment: $ENV"
  echo "generated (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo ""
  echo "toolkit clone:"
  echo "  git describe : $(git describe --tags --always --dirty 2>/dev/null || echo 'n/a (not a git clone)')"
  echo "  git rev-parse: $(git rev-parse HEAD 2>/dev/null || echo 'n/a')"
  echo "  git branch   : $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'n/a')"
  echo ""
  echo "tool versions (tools/checks/check-tools.sh):"
  if [ -x tools/checks/check-tools.sh ]; then
    tools/checks/check-tools.sh 2>&1 | sed 's/^/  /' || true
  else
    # Direct probes as fallback.
    for t in yq jq kubectl helm talosctl flux terraform python3; do
      if command -v "$t" >/dev/null 2>&1; then
        v=$("$t" --version 2>&1 | head -1 || true)
        echo "  $t: $v"
      else
        echo "  $t: not installed"
      fi
    done
  fi
} > "$BUNDLE_DIR/meta.txt"

# --- build ---------------------------------------------------------------------
mkdir -p "$ART_DIR"
OUTFILE="$ART_DIR/support-bundle-$STAMP.tar.gz"
tar -czf "$OUTFILE" -C "$STAGE" "$TOP"
chmod 0600 "$OUTFILE"

# --- post-build verification: list the archive, refuse on any sensitive path ---
# "secrets" is matched as a path segment (optionally talos-/machine- prefixed or
# with an extension) so machine secrets can never slip through, while legitimate
# chart names such as external-secrets in the rendered values do not trip it.
LISTING=$(tar -tzf "$OUTFILE")
FORBIDDEN='(^|/)\.env|tfstate|kubeconfig|talosconfig|(^|/)(talos-|machine-)?secrets(\.[^/]*)?(/|$)'
if printf '%s\n' "$LISTING" | grep -iE "$FORBIDDEN" >&2; then
  echo "error: archive would contain sensitive path(s) above — refusing, bundle deleted" >&2
  rm -f "$OUTFILE"
  exit 2
fi

echo "support bundle written: $OUTFILE (mode 0600)"
echo "included files:"
printf '%s\n' "$LISTING" | sed 's/^/  /'
