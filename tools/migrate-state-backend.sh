#!/usr/bin/env bash
# Usage: CONFIRM=yes tools/migrate-state-backend.sh <env>
#
# Migrates an environment's two Terraform state files (infra, config) from the
# local backend (artifacts/<env>/state/*.tfstate) to the S3-compatible backend
# declared in <env>/state-backend.yaml. OPERATOR ACTION — never run
# automatically: without CONFIRM=yes it only prints what it would do.
#
# Procedure per stack (the stack directories are shared by every environment,
# so the currently-initialized backend may belong to a DIFFERENT env — step 1
# rebinds to THIS env's local state first, step 2 migrates):
#   1. terraform init -reconfigure  -backend-config="path=<state>/<stack>.tfstate"
#      (with the s3 override file removed — plain local backend)
#   2. write backend_s3_override.tf + generated backend-<stack>.hcl, then
#      terraform init -migrate-state -force-copy -backend-config=<generated>
#
# Preconditions: state-backend.yaml declares type s3; STATE_S3_ACCESS_KEY /
# STATE_S3_SECRET_KEY in .env; the bucket exists (tooling MinIO: declare it
# under the tooling env's object_storage.buckets and apply there first).
# The local state files are left in place as a fallback copy — remove them
# manually once the remote state is verified (make list ENV=<env>).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENVIRONMENTS_ROOT="${ENVIRONMENTS_ROOT:-../environments}"
ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-../artifacts}"

ENV="${1:-}"
[ -n "$ENV" ] || { echo "usage: CONFIRM=yes $0 <env>" >&2; exit 2; }
ENV_DIR="$ENVIRONMENTS_ROOT/$ENV"
SB="$ENV_DIR/state-backend.yaml"
STATE_DIR="$ARTIFACTS_ROOT/$ENV/state"

[ -f "$SB" ] || { echo "error: $SB not found — declare the s3 backend first (see config/schemas/state-backend.schema.json)" >&2; exit 2; }
[ "$(yq eval '.type' "$SB")" = "s3" ] || { echo "error: $SB type is not s3 — nothing to migrate to" >&2; exit 2; }

# .env supplies STATE_S3_* for the generator.
if [ -f "$ENV_DIR/.env" ]; then
  set -a; . "$ENV_DIR/.env"; set +a
fi

abs_state_dir="$(cd "$STATE_DIR" 2>/dev/null && pwd)" || { echo "error: $STATE_DIR not found — nothing to migrate" >&2; exit 2; }

for stack in infra config; do
  local_state="$abs_state_dir/$stack.tfstate"
  echo ""
  echo "== $ENV / $stack"
  if [ ! -f "$local_state" ]; then
    echo "   no local state at $local_state — skipping (fresh env: just run make init)"
    continue
  fi
  echo "   1) cd src/$stack && rm -f backend_s3_override.tf && terraform init -reconfigure -input=false -backend-config=\"path=$local_state\""
  echo "   2) tools/generate-backend.sh $ENV $stack \"$abs_state_dir\""
  echo "   3) cd src/$stack && terraform init -migrate-state -force-copy -input=false -backend-config=\"$abs_state_dir/backend-$stack.hcl\""
  if [ "${CONFIRM:-}" != "yes" ]; then
    echo "   (dry run — set CONFIRM=yes to execute)"
    continue
  fi
  ( cd "src/$stack" && rm -f backend_s3_override.tf \
    && terraform init -reconfigure -input=false -backend-config="path=$local_state" >/dev/null )
  ENVIRONMENTS_ROOT="$ENVIRONMENTS_ROOT" ARTIFACTS_ROOT="$ARTIFACTS_ROOT" \
    tools/generate-backend.sh "$ENV" "$stack" "$abs_state_dir"
  ( cd "src/$stack" \
    && terraform init -migrate-state -force-copy -input=false -backend-config="$abs_state_dir/backend-$stack.hcl" )
  echo "   migrated. Local copy kept at $local_state — verify with 'make list ENV=$ENV', then archive/remove it."
done

echo ""
if [ "${CONFIRM:-}" != "yes" ]; then
  echo "Dry run complete. Re-run with CONFIRM=yes to migrate."
fi
