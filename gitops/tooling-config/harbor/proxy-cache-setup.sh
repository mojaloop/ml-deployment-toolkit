#!/bin/sh
set -e

apk add --no-cache curl jq > /dev/null 2>&1

HARBOR_URL="http://harbor-core:80"
HARBOR_USER="admin"
HARBOR_PASS=$(cat /secrets/password)

# OCI registry credentials (for authenticated upstream registries like ghcr.io)
OCI_USER=$(cat /oci-secrets/username)
OCI_TOKEN=$(cat /oci-secrets/password)

# Wait for Harbor API
echo "Waiting for Harbor API..."
retries=0
until curl -sf -u "$HARBOR_USER:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/health" > /dev/null 2>&1; do
  retries=$((retries + 1))
  if [ "$retries" -ge 60 ]; then
    echo "ERROR: Harbor not ready after 10 minutes"
    exit 1
  fi
  echo "  Not ready, retrying in 10s... ($retries/60)"
  sleep 10
done
echo "Harbor API is ready."

# Robot usernames become robot-<name> instead of the default robot$<name>:
# hub .env files are sourced by the Makefile, where a literal '$' in
# OCI_PROXY_USERNAME would be shell-expanded to nothing. The prefix is part
# of credential matching at auth time — set before any robot exists and
# never change it afterwards, or every existing robot login breaks.
echo "Setting robot name prefix..."
status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
  -X PUT "$HARBOR_URL/api/v2.0/configurations" \
  -u "$HARBOR_USER:$HARBOR_PASS" \
  -H "Content-Type: application/json" \
  -d '{"robot_name_prefix":"robot-"}')
if [ "$status" != "200" ]; then
  echo "ERROR setting robot_name_prefix: HTTP $status"; cat /tmp/response.json; exit 1
fi

REG_ID=""

# create_registry <name> <type> <url> [<credential_json>]
# If the registry exists with a different type, it is deleted and recreated (type is immutable).
create_registry() {
  name=$1; type=$2; url=$3; cred_json=$4

  if [ -z "$cred_json" ]; then
    cred_json="{}"
  fi

  payload="{\"name\":\"$name\",\"type\":\"$type\",\"url\":\"$url\",\"insecure\":false,\"credential\":$cred_json}"

  echo "Creating registry endpoint: $name ($type -> $url)..."

  # Check if registry already exists
  existing=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/registries" | \
    jq -r ".[] | select(.name==\"$name\")")

  if [ -n "$existing" ]; then
    existing_id=$(echo "$existing" | jq -r ".id")
    existing_type=$(echo "$existing" | jq -r ".type")

    if [ "$existing_type" != "$type" ]; then
      echo "  Type mismatch ($existing_type != $type), recreating..."
      # Delete project first (if exists), then registry
      curl -s -o /dev/null -u "$HARBOR_USER:$HARBOR_PASS" -X DELETE "$HARBOR_URL/api/v2.0/projects/$name"
      curl -s -o /dev/null -u "$HARBOR_USER:$HARBOR_PASS" -X DELETE "$HARBOR_URL/api/v2.0/registries/$existing_id"
      # Create fresh
      status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
        -X POST "$HARBOR_URL/api/v2.0/registries" \
        -u "$HARBOR_USER:$HARBOR_PASS" \
        -H "Content-Type: application/json" \
        -d "$payload")
      if [ "$status" = "201" ]; then
        echo "  Recreated: $name ($type)"
      else
        echo "  ERROR recreating $name: HTTP $status"; cat /tmp/response.json; return 1
      fi
    else
      echo "  Already exists, updating credentials..."
      update_status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
        -X PUT "$HARBOR_URL/api/v2.0/registries/$existing_id" \
        -u "$HARBOR_USER:$HARBOR_PASS" \
        -H "Content-Type: application/json" \
        -d "$payload")
      if [ "$update_status" = "200" ]; then
        echo "  Updated: $name"
      else
        echo "  ERROR updating $name: HTTP $update_status"; cat /tmp/response.json; return 1
      fi
    fi
  else
    status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
      -X POST "$HARBOR_URL/api/v2.0/registries" \
      -u "$HARBOR_USER:$HARBOR_PASS" \
      -H "Content-Type: application/json" \
      -d "$payload")
    case "$status" in
      201) echo "  Created: $name" ;;
      *)   echo "  ERROR: HTTP $status"; cat /tmp/response.json; return 1 ;;
    esac
  fi

  REG_ID=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/registries" | \
    jq -r ".[] | select(.name==\"$name\") | .id")
}

create_project() {
  name=$1; registry_id=$2
  echo "Creating proxy cache project: $name (registry_id=$registry_id)..."

  status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
    -X POST "$HARBOR_URL/api/v2.0/projects" \
    -u "$HARBOR_USER:$HARBOR_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\":\"$name\",\"registry_id\":$registry_id,\"metadata\":{\"public\":\"false\"}}")

  case "$status" in
    201) echo "  Created: $name" ;;
    409) echo "  Already exists: $name" ;;
    *)   echo "  ERROR: HTTP $status"; cat /tmp/response.json; return 1 ;;
  esac

  # Converge visibility on every run: projects are private — pulls require a
  # robot account (or admin). POST only sets metadata at creation, so
  # pre-existing public projects must be flipped explicitly.
  status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
    -X PUT "$HARBOR_URL/api/v2.0/projects/$name" \
    -u "$HARBOR_USER:$HARBOR_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"metadata\":{\"public\":\"false\"}}")
  if [ "$status" = "200" ]; then
    echo "  Visibility: private"
  else
    echo "  ERROR setting $name private: HTTP $status"; cat /tmp/response.json; return 1
  fi
}

# create_robot <name> <secret>
# System-level, never-expiring, pull-only across all projects (namespace
# "*"), so new proxy-cache projects need no robot change. The secret is
# PATCHed to the Terraform-generated value on every run — create once,
# converge always — which is what makes rotation work.
create_robot() {
  name=$1; secret=$2
  echo "Provisioning robot account: robot-$name..."

  robot_id=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/robots?page_size=100" | \
    jq -r ".[] | select(.name==\"robot-$name\") | .id")

  if [ -z "$robot_id" ]; then
    payload="{\"name\":\"$name\",\"level\":\"system\",\"duration\":-1,\"disable\":false,\"description\":\"toolkit pull robot\",\"permissions\":[{\"kind\":\"project\",\"namespace\":\"*\",\"access\":[{\"resource\":\"repository\",\"action\":\"pull\"}]}]}"
    status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
      -X POST "$HARBOR_URL/api/v2.0/robots" \
      -u "$HARBOR_USER:$HARBOR_PASS" \
      -H "Content-Type: application/json" \
      -d "$payload")
    if [ "$status" = "201" ]; then
      robot_id=$(jq -r ".id" /tmp/response.json)
      echo "  Created: robot-$name (id=$robot_id)"
    else
      echo "  ERROR creating robot-$name: HTTP $status"; cat /tmp/response.json; return 1
    fi
  else
    echo "  Already exists (id=$robot_id)"
  fi

  status=$(curl -s -o /tmp/response.json -w "%{http_code}" \
    -X PATCH "$HARBOR_URL/api/v2.0/robots/$robot_id" \
    -u "$HARBOR_USER:$HARBOR_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"secret\":\"$secret\"}")
  if [ "$status" = "200" ]; then
    echo "  Secret converged."
  else
    echo "  ERROR setting secret for robot-$name: HTTP $status"; cat /tmp/response.json; return 1
  fi
}

echo ""
echo "=== Configuring proxy caches ==="

# Docker Hub (public — no credentials needed)
create_registry "docker-hub" "docker-hub" "https://hub.docker.com"
create_project "docker-hub" "$REG_ID"

# GitHub Container Registry (authenticated — uses github-ghcr adapter with token)
create_registry "ghcr" "github-ghcr" "https://ghcr.io" "{\"type\":\"basic\",\"access_key\":\"$OCI_USER\",\"access_secret\":\"$OCI_TOKEN\"}"
create_project "ghcr" "$REG_ID"

# Quay.io (public)
create_registry "quay" "docker-registry" "https://quay.io"
create_project "quay" "$REG_ID"

# Kubernetes Registry (public)
create_registry "k8s-registry" "docker-registry" "https://registry.k8s.io"
create_project "k8s" "$REG_ID"

echo ""
echo "=== Provisioning robot accounts ==="
# robots.json: [{"name": ..., "secret": ...}, ...] from registry.robots in
# config.yaml (empty array when none declared). Additive only — robots
# removed from config are left untouched in Harbor.
jq -c '.[]' /robot-secrets/robots.json | while read -r robot; do
  name=$(echo "$robot" | jq -r '.name')
  secret=$(echo "$robot" | jq -r '.secret')
  create_robot "$name" "$secret" || exit 1
done

echo ""
echo "=== Proxy cache setup complete ==="
echo "Pull-through mirrors available at harbor.${domain}:"
echo "  docker.io       -> /docker-hub/<image>"
echo "  ghcr.io         -> /ghcr/<image>"
echo "  quay.io         -> /quay/<image>"
echo "  registry.k8s.io -> /k8s/<image>"
