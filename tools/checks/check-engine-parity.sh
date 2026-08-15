#!/usr/bin/env bash
# Usage: check-engine-parity.sh — behavioral A/B test of the two substitution engines the toolkit
# relies on agreeing: Terraform templatefile() (environment-layer files) and Flux postBuild
# envsubst (gitops manifests). Runs both engines over the same fixtures in a temp dir and
# compares: (a) bare ${UPPER} tokens substitute, (b) $${LITERAL} escapes survive as ${LITERAL},
# (c) bare $word is untouched, (d) an undefined ${MISSING} fails BOTH engines. Any divergence is
# a finding. If either binary is absent the check exits 0 with a stderr warning — the tool gate
# (check-tools.sh) reports missing tools separately.
set -euo pipefail

[ $# -eq 0 ] || { echo "usage: $0 (no arguments)" >&2; exit 2; }

if ! command -v terraform >/dev/null 2>&1; then
  echo "warning: terraform not installed — engine parity cannot be verified, skipping" >&2
  echo "check-engine-parity: SKIPPED"
  exit 0
fi
if ! command -v flux >/dev/null 2>&1; then
  echo "warning: flux not installed — engine parity cannot be verified, skipping" >&2
  echo "check-engine-parity: SKIPPED"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-engine-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
findings=0

# trim_trailing — drop trailing blank lines (BSD/GNU portable, unlike sed loops)
trim_trailing() {
  awk '{l[NR]=$0} END{n=NR; while (n>0 && l[n] ~ /^[[:space:]]*$/) n--; for (i=1;i<=n;i++) print l[i]}'
}

# --- Fixture 1: substitution, escape, bare-dollar ---------------------------
# terraform console evaluates templatefile() without init or configuration;
# path.module resolves to the working directory.
printf 'host: ${X}\nesc: $${LITERAL}\nbare: $word\n' > "$WORK/f.tmpl"

tf_out=$(cd "$WORK" && echo 'templatefile("${path.module}/f.tmpl", {X="val"})' | terraform console 2>"$WORK/tf.err") || {
  echo "fixture-1: terraform console failed to render the fixture:"
  sed 's/^/  /' "$WORK/tf.err"
  findings=$((findings+1))
  tf_out=""
}
# terraform console renders multi-line strings as a <<EOT ... EOT heredoc —
# strip the markers and trailing blank lines to get the raw rendered text.
tf_norm=$(printf '%s\n' "$tf_out" | sed -e '/^<<EOT$/d' -e '/^EOT$/d' | trim_trailing)

flux_out=$(X=val flux envsubst --strict < "$WORK/f.tmpl" 2>"$WORK/flux.err") || {
  echo "fixture-1: flux envsubst failed to render the fixture:"
  sed 's/^/  /' "$WORK/flux.err"
  findings=$((findings+1))
  flux_out=""
}
flux_norm=$(printf '%s\n' "$flux_out" | trim_trailing)

if [ -n "$tf_norm" ] && [ -n "$flux_norm" ] && [ "$tf_norm" != "$flux_norm" ]; then
  # each diverging line is a finding
  div=$(diff <(printf '%s\n' "$tf_norm") <(printf '%s\n' "$flux_norm") | grep -c '^[<>]' || true)
  [ "$div" -gt 0 ] || div=1
  echo "fixture-1: engines diverge on token/escape/bare-dollar handling:"
  diff <(printf '%s\n' "$tf_norm") <(printf '%s\n' "$flux_norm") | sed 's/^/  /' || true
  echo "  (terraform templatefile output vs flux envsubst output)"
  findings=$((findings + div))
else
  echo "ok: fixture-1 — \${UPPER} substitution, \$\${LITERAL} escape, bare \$word identical in both engines"
fi

# --- Fixture 2: undefined ${MISSING} must fail BOTH engines -----------------
printf 'm: ${MISSING}\n' > "$WORK/missing.tmpl"

tf_rc=0
(cd "$WORK" && echo 'templatefile("${path.module}/missing.tmpl", {})' | terraform console >/dev/null 2>&1) || tf_rc=$?
flux_rc=0
flux envsubst --strict < "$WORK/missing.tmpl" >/dev/null 2>&1 || flux_rc=$?

if [ "$tf_rc" -eq 0 ]; then
  echo "fixture-2: terraform templatefile silently accepted undefined \${MISSING} (must fail)"
  findings=$((findings+1))
fi
if [ "$flux_rc" -eq 0 ]; then
  echo "fixture-2: flux envsubst --strict silently accepted undefined \${MISSING} (must fail)"
  findings=$((findings+1))
fi
if [ "$tf_rc" -ne 0 ] && [ "$flux_rc" -ne 0 ]; then
  echo "ok: fixture-2 — undefined \${MISSING} fails both engines"
fi

if [ "$findings" -gt 0 ]; then
  echo "check-engine-parity: $findings finding(s)"
  exit 1
fi
echo "check-engine-parity: OK"
