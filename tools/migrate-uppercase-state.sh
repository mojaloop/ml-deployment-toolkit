#!/usr/bin/env bash
# One-time state migration for the UPPER_SNAKE substitution-key refactor.
#
# The config-layering refactor renamed the for_each keys of the generated
# internal passwords (random_password.generated / random_password.harbor_robot)
# from lower_snake to UPPER_SNAKE. Without a state move, the next apply would
# regenerate every internal password — rotating live database and service
# credentials. This script rewrites the state addresses in place.
#
# The helm value-override ConfigMaps also changed keys (release ->
# namespace-release); those are NOT moved here on purpose: they are
# regenerable, and destroy/create on next apply is harmless.
#
# Usage: tools/migrate-uppercase-state.sh <env> [--apply]
#   Dry-run by default: prints the `terraform state mv` commands it would run.
#   Respects ENVIRONMENTS_ROOT / ARTIFACTS_ROOT (default ../environments,
#   ../artifacts relative to the repo root).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${1:-}"
MODE="${2:-}"
[ -n "$ENV_NAME" ] || { echo "usage: $0 <env> [--apply]" >&2; exit 2; }

ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-$REPO_ROOT/../artifacts}"
STATE="$ARTIFACTS_ROOT/$ENV_NAME/terraform/config.tfstate"
[ -f "$STATE" ] || { echo "error: no config stack state at $STATE" >&2; exit 2; }

cd "$REPO_ROOT/src/config"
terraform init -reconfigure -input=false -backend-config="path=$STATE" >/dev/null

moved=0
while IFS= read -r addr; do
  # addr looks like: module.flux_config[0].random_password.generated["mysql_root_password"]
  key="${addr##*[\"]}"; key="${key%\"]}"
  upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  [ "$key" = "$upper" ] && continue
  target="${addr%\"$key\"]}\"$upper\"]"
  if [ "$MODE" = "--apply" ]; then
    terraform state mv "$addr" "$target"
  else
    echo "would run: terraform state mv '$addr' '$target'"
  fi
  moved=$((moved + 1))
done < <(terraform state list 2>/dev/null | grep -E 'random_password\.(generated|harbor_robot)\[' || true)

if [ "$moved" -eq 0 ]; then
  echo "nothing to migrate (no lower-case password keys in state)"
elif [ "$MODE" != "--apply" ]; then
  echo ""
  echo "$moved address(es) would be moved. Re-run with --apply to do it."
else
  echo "$moved address(es) moved."
fi
