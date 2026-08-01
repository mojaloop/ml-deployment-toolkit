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
# The mutation runs separately from validation so a broken yq expression is
# reported as a test error rather than counted as a successful rejection.
expect_reject() {
  local name="$1" mutation="$2" out doc rc
  if ! doc=$(yq e "$mutation" "$BASE" | yq -o json e '.' - 2>&1); then
    echo "FAIL: '$name' — mutation itself failed: $doc"
    FAIL=$((FAIL + 1))
    return
  fi
  out=$(printf '%s' "$doc" | python3 tools/validate.py "$SCHEMA" 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: '$name' was accepted but should have been rejected"
    FAIL=$((FAIL + 1))
  else
    echo "ok: $name  -> $(head -1 <<<"$out")"
    PASS=$((PASS + 1))
  fi
}

expect_accept() {
  local name="$1" file="$2" out rc
  out=$(yq -o json e '.' "$file" | python3 tools/validate.py "$SCHEMA" 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "ok: $name accepted"
    PASS=$((PASS + 1))
  else
    echo "FAIL: '$name' rejected: $out"
    FAIL=$((FAIL + 1))
  fi
}

echo "--- positive cases ---"
expect_accept "tooling sample" environments/mlf-lab1-cc1/config.yaml.sample
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
expect_reject "lb_ipam without range"      'del(.cluster.lb_ipam.range)'
expect_reject "lb_ipam range without dash" '.cluster.lb_ipam.range = "192.168.0.10"'
expect_reject "unknown key in cert"        '.cert.bogus = "x"'
expect_reject "unknown key in artifact"    '.artifact.bogus = "x"'
expect_reject "invalid cert provider"      '.cert.provider = "vault-pki"' 

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
