#!/usr/bin/env bash
# Usage: explain.sh <env> [environment|template] — "where did this value come
# from", v1 (design doc §3 rule 5): render the environment with one layer's
# override surfaces MASKED, diff against the full render. Everything the diff
# shows is what that layer contributes; everything identical came from the
# layers below it.
#
#   explain.sh <env> environment   (default) — what the environment layer
#     contributes: placement.yaml pool overrides, values/, talos/ overlays
#   explain.sh <env> template — what the selected template's values/ and
#     talos/ overlays contribute (its placement SHAPE is the base topology
#     and cannot be masked)
#
# The full render is (re)built into <RENDER_ROOT>/<env>/ as a side effect, so
# explain always compares against the current tree, never a stale render.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RENDER_ROOT="${RENDER_ROOT:-../rendered}"

ENV="${1:-}"
LAYER="${2:-environment}"
if [ -z "$ENV" ]; then
  echo "usage: $0 <env> [environment|template]" >&2
  exit 2
fi
case "$LAYER" in
  environment|template) ;;
  params|generic)
    echo "error: layer '$LAYER' cannot be masked — provider params are schema-required" \
         "and the generic layer is the base everything diffs against. Maskable: environment, template." >&2
    exit 2 ;;
  *) echo "usage: $0 <env> [environment|template]" >&2; exit 2 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/explain.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "explain($ENV): full render..."
tools/render.sh "$ENV" >/dev/null

echo "explain($ENV): render with layer '$LAYER' masked..."
MASK="$LAYER" OUT="$WORK/masked" tools/render.sh "$ENV" >/dev/null

echo ""
echo "=== Contribution of layer '$LAYER' for env '$ENV' ==="
echo "(diff: render WITHOUT the layer -> full render; '+' lines are what the layer adds/overrides)"
echo ""
if diff -r -u "$WORK/masked" "$RENDER_ROOT/$ENV"; then
  echo "(no difference — layer '$LAYER' overrides nothing for this environment)"
fi
