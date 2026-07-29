#!/usr/bin/env bash
# Migrate an environment from the single-stack layout (src/) to the two-stack
# layout (src/infra + src/config) WITHOUT recreating any infrastructure.
#
#   tools/migrate-state.sh <env> [--apply]
#
# Default is a dry run: it prints every state operation without executing it.
# Pass --apply to perform the migration. A timestamped backup of the original
# state is always written to artifacts/<env>/terraform/ before any change.
#
# What it does:
#   1. Backs up the existing terraform.tfstate.
#   2. Copies it to infra.tfstate and config.tfstate.
#   3. Removes config-stack resources from infra.tfstate and vice versa, so each
#      stack owns exactly its own resources (nothing is destroyed — `state rm`
#      only forgets, and the resources remain owned by the other stack).
#
# Resource ownership after the split:
#   infra.tfstate  : module.proxmox | module.digitalocean | module.aws,
#                    module.flux_bootstrap, module.config (data only)
#   config.tfstate : module.flux_config, module.config (data only)
#
# After migrating, rewrite environments/<env>/config.yaml to the new schema
# (see _/configuration/adopter-journey.md), then run:
#   make validate ENV=<env> && make plan ENV=<env>
# and confirm the infra plan is a no-op before applying.

set -euo pipefail

ENV_NAME="${1:-}"
MODE="${2:---dry-run}"

if [[ -z "$ENV_NAME" ]]; then
  echo "usage: $0 <env> [--apply]" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$REPO_ROOT/artifacts/$ENV_NAME/terraform"
OLD_STATE="$STATE_DIR/terraform.tfstate"
INFRA_STATE="$STATE_DIR/infra.tfstate"
CONFIG_STATE="$STATE_DIR/config.tfstate"
STAMP="$(date +%Y%m%d-%H%M%S)"

run() {
  if [[ "$MODE" == "--apply" ]]; then
    echo "+ $*"
    "$@"
  else
    echo "(dry-run) $*"
  fi
}

if [[ ! -f "$OLD_STATE" ]]; then
  echo "ERROR: $OLD_STATE not found — nothing to migrate." >&2
  exit 1
fi

echo "Migrating '$ENV_NAME' to the two-stack layout"
echo "  old state : $OLD_STATE"
echo "  ->  infra : $INFRA_STATE"
echo "  -> config : $CONFIG_STATE"
echo

# Resources currently in state (read without mapfile — absent in bash 3.2/macOS)
CONFIG_RESOURCES=()
INFRA_RESOURCES=()
COUNT=0
while IFS= read -r r; do
  [[ -z "$r" ]] && continue
  COUNT=$((COUNT + 1))
  case "$r" in
    module.flux_config*) CONFIG_RESOURCES+=("$r") ;;
    *)                   INFRA_RESOURCES+=("$r") ;;
  esac
done < <(terraform state list -state="$OLD_STATE" 2>/dev/null || true)

if [[ $COUNT -eq 0 ]]; then
  echo "ERROR: no resources found in $OLD_STATE" >&2
  exit 1
fi

echo "Infra stack keeps ${#INFRA_RESOURCES[@]} resource(s); config stack takes ${#CONFIG_RESOURCES[@]}."
echo

run cp "$OLD_STATE" "$STATE_DIR/terraform.tfstate.backup-$STAMP"
run cp "$OLD_STATE" "$INFRA_STATE"
run cp "$OLD_STATE" "$CONFIG_STATE"

# Strip the other stack's resources from each copy.
for r in "${CONFIG_RESOURCES[@]}"; do
  run terraform state rm -state="$INFRA_STATE" "$r"
done
for r in "${INFRA_RESOURCES[@]}"; do
  run terraform state rm -state="$CONFIG_STATE" "$r"
done

# Re-address the Kratos/Hydra secrets. They were six discrete resources; they are
# now entries in one for_each map. Without these moves Terraform destroys the old
# addresses and generates fresh values — rotating kratos_secrets_cipher makes
# stored credential and recovery material undecryptable, and rotating
# hydra_secrets_system invalidates every issued token and consent grant.
GENERATED_MOVES=(
  kratos_secrets_cipher
  kratos_secrets_cookie
  kratos_secrets_csrf_cookie
  kratos_secrets_default
  hydra_secrets_system
  hydra_secrets_cookie
)
for name in "${GENERATED_MOVES[@]}"; do
  old="module.flux_config[0].random_password.${name}[0]"
  new="module.flux_config[0].random_password.generated[\"${name}\"]"
  if printf '%s\n' "${CONFIG_RESOURCES[@]}" | grep -qxF "$old"; then
    run terraform state mv -state="$CONFIG_STATE" "$old" "$new"
  fi
done

echo
if [[ "$MODE" == "--apply" ]]; then
  echo "Done. Next:"
else
  echo "Dry run complete — re-run with --apply to perform it. Then:"
fi
OLD_CLUSTER_NAME="$(yq -r '.cluster.name // ""' "$REPO_ROOT/environments/$ENV_NAME/config.yaml" 2>/dev/null || true)"
if [[ -n "$OLD_CLUSTER_NAME" && "$OLD_CLUSTER_NAME" != "$ENV_NAME" ]]; then
  cat <<WARN

  !! This environment's cluster.name ('$OLD_CLUSTER_NAME') differs from its
     directory name ('$ENV_NAME'). Keep cluster.name EXACTLY as it is in the
     rewritten config. It is the external-dns TXT owner id, the Vault backup
     prefix, and the VM name prefix — renaming it orphans every DNS record the
     cluster published and forces VM replacement.
WARN
fi

cat <<EOF
  1. Rewrite environments/$ENV_NAME/config.yaml to the new schema.
     Carry cluster.name over verbatim (see warning above, if any).
  2. Move secrets: keep only external credentials in .env; existing internal
     passwords stay honored if their UPPER_CASE names remain in .env
     (generation only kicks in for names that are absent or empty).
  3. make validate ENV=$ENV_NAME
  4. make plan ENV=$ENV_NAME  — the INFRA plan must show no changes.
     Kustomization resources will show as replacements in the CONFIG plan
     (they move from individual resources to a for_each map): this is safe,
     Flux keeps reconciling from the identical manifests.
EOF
