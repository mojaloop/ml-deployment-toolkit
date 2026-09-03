#!/bin/sh
# Full RBAC e2e over a deployed hub, host-side, real FQDN flows with real CA
# trust (no -k anywhere): hub-admin and DFSP-operator Kratos sessions
# (invitation and recovery links through the deployment's mail catcher), the
# machine JWT from the external hydra, own-vs-foreign Keto isolation, the
# anonymous-blocked UI with login redirect, the portal shell and its
# permit-gated micro-frontends behind role-bound grants, the participant
# source sync, and CORS preflight. Hostnames are pinned per gateway with
# --resolve, so the suite runs from any machine that reaches the gateway IPs.
#
#   tools/e2e-authz.sh <env> [environments-root] [artifacts-root]
#
# Tolerates re-runs on the same cluster.
set -u

ENV_NAME=${1:?usage: e2e-authz.sh <env> [environments-root] [artifacts-root]}
TOOLKIT="$(cd "$(dirname "$0")/.." && pwd)"
ENVROOT=${2:-$TOOLKIT/../environments}
ARTROOT=${3:-$TOOLKIT/../artifacts}
CFG="$ENVROOT/$ENV_NAME/config.yaml"
export KUBECONFIG="$ARTROOT/$ENV_NAME/kubernetes/kubeconfig"

DOM=$(yq -r .dns.domain "$CFG")
ADMIN_EMAIL=$(yq -r .app.hub.admin_email "$CFG")
INT_IP=$(kubectl -n platform-system get gateway gw-int -o jsonpath='{.status.addresses[0].value}')
EXT_IP=$(kubectl -n platform-system get gateway gw-ext -o jsonpath='{.status.addresses[0].value}')
[ -n "$DOM" ] && [ -n "$INT_IP" ] && [ -n "$EXT_IP" ] || { echo "unresolved domain or gateway IPs"; exit 1; }

K="kubectl -n ory"
CL=http://moja-centralledger-service.mojaloop.svc.cluster.local
# Internal surfaces ride gw-int; the MCM API and hydra are external names
RI="--resolve mcm.int.$DOM:443:$INT_IP --resolve kratos.int.$DOM:443:$INT_IP --resolve auth.int.$DOM:443:$INT_IP --resolve mailpit.int.$DOM:443:$INT_IP --resolve portal.int.$DOM:443:$INT_IP --resolve portal-api.int.$DOM:443:$INT_IP --resolve iam-api.int.$DOM:443:$INT_IP --resolve portal-iam.int.$DOM:443:$INT_IP --resolve portal-transfers.int.$DOM:443:$INT_IP --resolve portal-settlements.int.$DOM:443:$INT_IP --resolve portal-positions.int.$DOM:443:$INT_IP"
RE="--resolve mcm-api.ext.$DOM:443:$EXT_IP --resolve hydra.ext.$DOM:443:$EXT_IP"
API="https://mcm-api.ext.$DOM"
UI="https://mcm.int.$DOM"
MAILPIT="https://mailpit.int.$DOM"
TMP=$(mktemp -d)
PASS=0; FAIL=0

t() { # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS  $1 ($3)"
  else FAIL=$((FAIL+1)); echo "FAIL  $1 (expected $2, got $3)"; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# The in-cluster caller for admin APIs no gateway exposes. Its sleep runs out,
# so it is replaced whenever it is not Running.
[ "$($K get pod dbg -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] || {
  $K delete pod dbg --ignore-not-found --wait=true
  $K run dbg --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 14400
  $K wait --for=condition=Ready pod/dbg --timeout=60s
}
kadmin() { $K exec dbg -- curl -s "$@"; }

# Session via a fresh admin-API recovery link, the identity is looked up by email
session_for() { # session_for <email> <jar>
  ID=$(kadmin http://kratos-admin/admin/identities | python3 -c "
import sys,json
for i in json.load(sys.stdin):
    if i['traits'].get('email')=='$1': print(i['id'])")
  [ -n "$ID" ] || { echo "no identity for $1" >&2; return 1; }
  LINK=$(kadmin -X POST http://kratos-admin/admin/recovery/link \
    -H "Content-Type: application/json" \
    -d "{\"identity_id\":\"$ID\",\"expires_in\":\"1h\"}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["recovery_link"])')
  rm -f "$2"
  curl -s $RI -L -c "$2" -b "$2" -o /dev/null "$LINK"
  curl -s $RI -b "$2" "https://kratos.int.$DOM/sessions/whoami" | grep -q "$1"
}

echo "== hub admin session =="
session_for "$ADMIN_EMAIL" "$TMP/admin.jar" || { echo "admin session failed"; exit 1; }
ADMIN="-b $TMP/admin.jar"

echo "== admin matrix =="
t "admin list dfsps"            200 "$(code $RE $ADMIN $API/api/dfsps)"
if ! curl -s $RE $ADMIN "$API/api/dfsps" | grep -q '"dfsp1"'; then
  t "admin create dfsp1" 200 "$(code $RE $ADMIN -X POST -H 'Content-Type: application/json' -d '{"dfspId":"dfsp1","name":"DFSP One","email":"op1@example.com"}' $API/api/dfsps)"
  t "admin create dfsp2" 200 "$(code $RE $ADMIN -X POST -H 'Content-Type: application/json' -d '{"dfspId":"dfsp2","name":"DFSP Two","email":"op2@example.com"}' $API/api/dfsps)"
fi
t "admin credentials denied (operators-only)" 403 "$(code $RE $ADMIN -X POST $API/api/dfsps/dfsp1/credentials)"

echo "== operator onboarding through the courier =="
# A fresh DFSP mints a fresh invitation; on a cluster that has it already the
# invitation is long spent and the session comes from a recovery link instead
FRESH=""
if ! curl -s $RE $ADMIN "$API/api/dfsps" | grep -q '"dfsp3"'; then
  t "admin create dfsp3" 200 "$(code $RE $ADMIN -X POST -H 'Content-Type: application/json' -d '{"dfspId":"dfsp3","name":"DFSP Three","email":"op3@example.com"}' $API/api/dfsps)"
  FRESH=1
  sleep 10
fi
if [ -n "$FRESH" ]; then
  INV=$(curl -s $RI "$MAILPIT/api/v1/messages" | python3 -c '
import sys,json
for m in json.load(sys.stdin).get("messages",[]):
    if any(a.get("Address")=="op3@example.com" for a in m.get("To",[])): print(m["ID"]); break' 2>/dev/null)
  t "operator invited by email" 1 "$([ -n "$INV" ] && echo 1 || echo 0)"
  OP3_OK=""
  if [ -n "$INV" ]; then
    LINK=$(curl -s $RI "$MAILPIT/api/v1/message/$INV" | python3 -c '
import sys,json,re
d=json.load(sys.stdin)
m=re.search(r"https://[^\s\"<]+recovery[^\s\"<]+", d.get("HTML","") or d.get("Text",""))
print(m.group(0).replace("&amp;","&") if m else "")')
    if [ -n "$LINK" ]; then
      rm -f "$TMP/op3.jar"
      curl -s $RI -L -c "$TMP/op3.jar" -b "$TMP/op3.jar" -o /dev/null "$LINK"
      curl -s $RI -b "$TMP/op3.jar" "https://kratos.int.$DOM/sessions/whoami" | grep -q op3@example.com && OP3_OK=1
    fi
  fi
  t "operator session via the emailed link" 1 "$([ -n "$OP3_OK" ] && echo 1 || echo 0)"
fi

echo "== operator matrix =="
session_for op1@example.com "$TMP/op1.jar" || { echo "op1 session failed"; exit 1; }
OP1="-b $TMP/op1.jar"
t "op1 list dfsps"              200 "$(code $RE $OP1 $API/api/dfsps)"
ROWS=$(curl -s $RE $OP1 "$API/api/dfsps" | python3 -c 'import sys,json; print(",".join(sorted(r["id"] for r in json.load(sys.stdin))))')
t "op1 list scoped to own dfsp" dfsp1 "$ROWS"
t "op1 view foreign denied"     403 "$(code $RE $OP1 $API/api/dfsps/dfsp2/status)"
t "op1 create dfsp denied"      403 "$(code $RE $OP1 -X POST -H 'Content-Type: application/json' -d '{"dfspId":"x","name":"x","email":"x@x.com"}' $API/api/dfsps)"
t "op1 own credentials"         201 "$(code $RE $OP1 -X POST -o $TMP/creds.json $API/api/dfsps/dfsp1/credentials)"
curl -s $RE $OP1 -X POST -o "$TMP/creds.json" "$API/api/dfsps/dfsp1/credentials" >/dev/null
t "op1 foreign credentials denied" 403 "$(code $RE $OP1 -X POST $API/api/dfsps/dfsp2/credentials)"

echo "== machine =="
CID=$(python3 -c 'import json; print(json.load(open("'"$TMP"'/creds.json"))["clientId"])')
SEC=$(python3 -c 'import json; print(json.load(open("'"$TMP"'/creds.json"))["clientSecret"])')
t "token from external hydra"   200 "$(code $RE -u "$CID:$SEC" -d 'grant_type=client_credentials&audience=connection-manager-api' -o $TMP/token.json https://hydra.ext.$DOM/oauth2/token)"
curl -s $RE -u "$CID:$SEC" -d 'grant_type=client_credentials&audience=connection-manager-api' -o "$TMP/token.json" "https://hydra.ext.$DOM/oauth2/token"
TOK="Authorization: Bearer $(python3 -c 'import json; print(json.load(open("'"$TMP"'/token.json"))["access_token"])')"
t "machine own status"          200 "$(code $RE -H "$TOK" $API/api/dfsps/dfsp1/status)"
t "machine foreign denied"      403 "$(code $RE -H "$TOK" $API/api/dfsps/dfsp2/status)"
t "machine peer jwscerts"       200 "$(code $RE -H "$TOK" $API/api/dfsps/jwscerts)"
t "machine list denied (cookie-only)" 401 "$(code $RE -H "$TOK" $API/api/dfsps)"
t "machine credentials denied"  401 "$(code $RE -H "$TOK" -X POST $API/api/dfsps/dfsp1/credentials)"
t "health anonymous"            200 "$(code $RE $API/api/health)"
t "machine JWT on UI host denied" 401 "$(code $RI -H "$TOK" $UI/)"

echo "== UI =="
t "UI anonymous json 401"       401 "$(code $RI $UI/)"
t "UI browser login redirect"   302 "$(code $RI -H 'Accept: text/html' $UI/)"
t "UI deep-link redirect"       302 "$(code $RI -H 'Accept: text/html' $UI/dfsps)"
t "UI with session"             200 "$(code $RI $OP1 $UI/)"

echo "== portal =="
PORTAL="https://portal.int.$DOM"
AID=$(kadmin http://kratos-admin/admin/identities | python3 -c "
import sys,json
for i in json.load(sys.stdin):
    if i['traits'].get('email')=='$ADMIN_EMAIL': print(i['id'])")
# Portal access rides one membership: the roles a deployment composed already
# carry the view permission for the shell and for each micro-frontend, so
# taking the role away and giving it back is the whole test, made the way an
# operator makes it.
iam() { # iam <method> <path> [body]
  $K exec dbg -- curl -s -o /dev/null -X "$1" \
    ${3:+-H 'Content-Type: application/json' -d "$3"} \
    "http://iam-ml-iam-services-provisioning$2"
}
iam DELETE "/subjects/$AID/assignments" '{"role":"hub-admin"}'
t "portal anonymous json 401"   401 "$(code $RI $PORTAL/)"
t "portal browser login redirect" 302 "$(code $RI -H 'Accept: text/html' $PORTAL/)"
t "shell without a role denied"  403 "$(code $RI $ADMIN $PORTAL/)"
t "mfe without a role denied"   403 "$(code $RI $ADMIN https://portal-iam.int.$DOM/)"
iam POST "/subjects/$AID/assignments" '{"role":"hub-admin"}'
t "shell via the role"          200 "$(code $RI $ADMIN $PORTAL/)"
t "mfe roles via the role"      200 "$(code $RI $ADMIN https://portal-iam.int.$DOM/)"
t "mfe transfers"               200 "$(code $RI $ADMIN https://portal-transfers.int.$DOM/)"
t "mfe settlements"             200 "$(code $RI $ADMIN https://portal-settlements.int.$DOM/)"
t "mfe positions"               200 "$(code $RI $ADMIN https://portal-positions.int.$DOM/)"
t "mfe federation bundle"       200 "$(code $RI $ADMIN https://portal-iam.int.$DOM/app.js)"
t "shell remotes manifest"      200 "$(code $RI $ADMIN $PORTAL/remotes.json)"
t "op1 mfe denied (holds no portal role)" 403 "$(code $RI $OP1 https://portal-iam.int.$DOM/)"

echo "== the role screen's data: roles, pickers and holdings =="
IAPI="https://iam-api.int.$DOM"
t "roles listed with what each leaves open" Participant "$(curl -s $RI $ADMIN $IAPI/roles \
  | python3 -c 'import sys,json; roles={r["name"]: r["open"] for r in json.load(sys.stdin)["roles"]}; print(",".join(roles["dfsp-operator"]))')"
t "picker offers the participants that exist" 1 "$(curl -s $RI $ADMIN "$IAPI/resources?resourceName=Participant" \
  | python3 -c 'import sys,json; rows=json.load(sys.stdin)["resources"]; print(1 if {"resourceName":"Participant","id":"dfsp1"} in rows else 0)')"
t "holdings answer with the resources each names" hub-admin "$(curl -s $RI $ADMIN $IAPI/users/$AID/assignments \
  | python3 -c 'import sys,json; held=json.load(sys.stdin)["assignments"]; print(",".join(a["role"] for a in held if a["resources"]=={}))')"

echo "== the scope reaches the service, and only the gateway writes it =="
t "forged scope ignored" dfsp1 "$(curl -s $RE $OP1 -H 'X-Scope: dfsps=*' "$API/api/dfsps" | python3 -c 'import sys,json; print(",".join(sorted(r["id"] for r in json.load(sys.stdin))))')"

echo "== a resource is grantable the moment it exists =="
t "dfsp2 offered by the IAM" 1 "$($K exec dbg -- curl -s 'http://iam-ml-iam-services-provisioning/resources?resourceName=Participant' | grep -c '"id": *"dfsp2"')"
iam POST "/subjects/$AID/assignments" '{"role":"dfsp-operator","resources":{"Participant":"dfsp2"}}'
t "admin now sees dfsp2 rows" 200 "$(code $RE $ADMIN $API/api/dfsps/dfsp2/status)"
iam DELETE "/subjects/$AID/assignments" '{"role":"dfsp-operator","resources":{"Participant":"dfsp2"}}'

echo "== the switch's participants reach the picker through the declared source =="
# Real onboarding: the hub's currency accounts and settlement model, then the
# participant, created in central-ledger, which only the source sync ever
# tells the platform about
for a in HUB_RECONCILIATION HUB_MULTILATERAL_SETTLEMENT; do
  $K exec dbg -- curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d '{"currency":"XOF","type":"'$a'"}' $CL/participants/Hub/accounts
done
$K exec dbg -- curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d '{
  "name":"DEFERREDNET","settlementGranularity":"NET","settlementInterchange":"MULTILATERAL",
  "settlementDelay":"DEFERRED","requireLiquidityCheck":true,"type":"POSITION",
  "autoPositionReset":true,"ledgerAccountType":"POSITION","settlementAccountType":"SETTLEMENT"
}' $CL/settlementModels
$K exec dbg -- curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d '{"name":"pinkbank","currency":"XOF"}' $CL/participants
t "participant onboarded in the switch" 1 "$($K exec dbg -- curl -s $CL/participants | grep -c '"name":"pinkbank"')"
SYNCED=0
for _ in $(seq 1 12); do
  $K exec dbg -- curl -s 'http://iam-ml-iam-services-provisioning/resources?resourceName=Participant' \
    | grep -q '"id": *"pinkbank"' && { SYNCED=1; break; }
  sleep 5
done
t "onboarded participant offered by the IAM" 1 "$SYNCED"

echo "== the ledger surface: the list is whole for whoever holds it =="
LAPI="https://portal-api.int.$DOM"
t "admin reads the whole list" 1 "$(curl -s $RI $ADMIN $LAPI/participants | grep -c '"name":"pinkbank"')"
t "op1 holds no listing" 403 "$(code $RI $OP1 $LAPI/participants)"
t "vocabulary served whole" 1 "$($K exec dbg -- curl -s 'http://iam-ml-iam-services-provisioning/resource-names' | grep -c '"url": *"http://moja-centralledger-service.mojaloop.svc.cluster.local/participants"')"

echo "== CORS =="
t "preflight" 200 "$(code $RE -X OPTIONS -H "Origin: $UI" -H 'Access-Control-Request-Method: GET' $API/api/dfsps)"
ACAO=$(curl -s $RE -o /dev/null -D - -X OPTIONS -H "Origin: $UI" -H 'Access-Control-Request-Method: GET' "$API/api/dfsps" | grep -ci 'access-control-allow-origin')
t "preflight allow-origin header" 1 "$ACAO"

echo
echo "==== $PASS passed, $FAIL failed ===="
rm -rf "$TMP"
[ "$FAIL" = 0 ]
