#!/usr/bin/env bash
# Negative tests for the config schema: each case must be REJECTED.
# Run: tools/test-validation.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEMA=config/schemas/environment.schema.json
BASE=environments/mlf-lab1-cc1/config.yaml.sample
PASS=0
FAIL=0

# expect_reject <name> <yq mutation expression>
expect_reject() {
  local name="$1" mutation="$2" out
  out=$(yq e "$mutation" "$BASE" | yq -o json e '.' - | python3 tools/validate.py "$SCHEMA" 2>&1)
  if [[ $? -eq 0 ]]; then
    echo "FAIL: '$name' was accepted but should have been rejected"
    FAIL=$((FAIL + 1))
  else
    echo "ok: $name  -> $(head -1 <<<"$out")"
    PASS=$((PASS + 1))
  fi
}

expect_accept() {
  local name="$1" file="$2" out
  out=$(yq -o json e '.' "$file" | python3 tools/validate.py "$SCHEMA" 2>&1)
  if [[ $? -eq 0 ]]; then
    echo "ok: $name accepted"
    PASS=$((PASS + 1))
  else
    echo "FAIL: '$name' rejected: $out"
    FAIL=$((FAIL + 1))
  fi
}

echo "--- positive cases ---"
expect_accept "cc sample" environments/mlf-lab1-cc1/config.yaml.sample
expect_accept "hub sample" environments/mlf-lab1-sw1/config.yaml.sample

echo "--- negative cases ---"
expect_reject "unknown top-level key"      '.bogus = "x"'
expect_reject "unknown key in cluster"     '.cluster.bogus = "x"'
expect_reject "invalid cluster role"       '.cluster.role = "switch"'
expect_reject "invalid infra provider"     '.infra.provider = "vsphere"'
expect_reject "invalid dns provider"       '.dns.provider = "bind"'
expect_reject "missing version"            'del(.version)'
expect_reject "missing cluster"            'del(.cluster)'
expect_reject "missing template"           'del(.template)'
expect_reject "missing dns.domain"         'del(.dns.domain)'
expect_reject "invalid data mode"          '.data.mysql.mode = "managed"'
expect_reject "invalid registry provider"  '.registry.provider = "dockerhub"'
expect_reject "template as number"         '.template = 5'

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
