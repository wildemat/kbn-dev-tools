#!/bin/bash
set -euo pipefail

EIS_QA_URL="https://inference.eu-west-1.aws.svc.qa.elastic.cloud"
VAULT_SECRET="secret/kibana-issues/dev/inference/kibana-eis-ccm"
CLOUD_API="https://cloud.elastic.co/api/v1"

usage() {
  cat <<'EOF'
Usage: kbn-dev-ccm --stack | --sls

Environment variables:
  CCM_API_KEY   CCM key (prod or QA). If unset, auto-fetches QA key from Vault.
  CCM_NO_EIS    Set to 1 to skip EIS setup entirely.
  ES_PORT       Override ES port (default: 9201 for stack, 9200 for sls).
  KBN_PORT      Override Kibana port for stack (default: 5611).
  VAULT_ADDR    Vault address (default: https://secrets.elastic.co:8200).

Examples:
  CCM_API_KEY=essu_...     kbn-dev-ccm --stack   # Prod key, stack
  CCM_API_KEY=essu_...     kbn-dev-ccm --sls     # Prod key, serverless
  CCM_API_KEY=essu_qa_...  kbn-dev-ccm --stack   # QA key, stack
  kbn-dev-ccm --sls                               # Auto Vault QA key, sls
  CCM_NO_EIS=1 kbn-dev-ccm --stack                # No EIS
EOF
  exit 1
}

# --- Parse args ---

TARGET=""
for arg in "$@"; do
  case "$arg" in
    --stack) TARGET="stack" ;;
    --sls)   TARGET="sls" ;;
    *)       echo "Unknown argument: $arg"; usage ;;
  esac
done
[ -z "$TARGET" ] && usage

# --- Early exit: no EIS ---

if [ "${CCM_NO_EIS:-}" = "1" ]; then
  echo "CCM_NO_EIS=1 — skipping EIS setup."
  exit 0
fi

# --- Set defaults based on target ---

if [ "$TARGET" = "stack" ]; then
  ES_PORT="${ES_PORT:-9201}"
  ES_AUTH="elastic:changeme"
  ES_PROTO="http"
  CURL_ES_OPTS="-s"
  KBN_PORT="${KBN_PORT:-5611}"
else
  ES_PORT="${ES_PORT:-9200}"
  ES_AUTH="elastic_serverless:changeme"
  ES_PROTO="https"
  CURL_ES_OPTS="-s -k"
fi

ES_URL="${ES_PROTO}://localhost:${ES_PORT}"

# --- Resolve API key ---

KEY_TYPE=""
API_KEY="${CCM_API_KEY:-}"

if [ -n "$API_KEY" ]; then
  if [[ "$API_KEY" == essu_qa_* ]]; then
    KEY_TYPE="qa"
    echo "Using QA CCM key from CCM_API_KEY."
  elif [[ "$API_KEY" == essu_* ]]; then
    KEY_TYPE="prod"
    echo "Using production CCM key from CCM_API_KEY."
  else
    echo "WARNING: CCM_API_KEY doesn't match known prefix (essu_qa_* or essu_*). Treating as prod."
    KEY_TYPE="prod"
  fi
else
  KEY_TYPE="qa"
  VAULT_ADDR="${VAULT_ADDR:-https://secrets.elastic.co:8200}"
  echo "No CCM_API_KEY set. Fetching QA key from Vault..."
  API_KEY=$(VAULT_ADDR="$VAULT_ADDR" vault read -field key "$VAULT_SECRET" 2>&1) || {
    echo ""
    echo "ERROR: Failed to fetch key from Vault."
    echo ""
    echo "Make sure you are logged in:"
    echo "  VAULT_ADDR=$VAULT_ADDR vault login --method oidc"
    echo ""
    echo "Or set CCM_API_KEY manually:"
    echo "  CCM_API_KEY=essu_qa_... $0 $*"
    exit 1
  }
  API_KEY=$(echo "$API_KEY" | tr -d '[:space:]')
  if [ -z "$API_KEY" ]; then
    echo "ERROR: Vault returned an empty key."
    exit 1
  fi
  echo "Got QA key from Vault."
fi

# --- Verify ES is reachable ---

echo ""
echo "==> Checking ES at $ES_URL..."
ES_HEALTH=$(curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL" -w "\n%{http_code}" 2>&1) || {
  echo "ERROR: Cannot reach Elasticsearch at $ES_URL."
  exit 1
}
ES_HTTP=$(echo "$ES_HEALTH" | tail -1)
if [ "$ES_HTTP" != "200" ]; then
  echo "ERROR: ES returned HTTP $ES_HTTP. Is it running?"
  exit 1
fi
echo "ES is up."

# ==========================================================================
# QA PATH — same flow for both stack and sls
# ==========================================================================

if [ "$KEY_TYPE" = "qa" ]; then
  echo ""
  echo "--- QA Path ($TARGET) ---"

  # Check inference URL
  EIS_ENDPOINT=$(curl $CURL_ES_OPTS -u "$ES_AUTH" \
    "$ES_URL/_cluster/settings?include_defaults=true&flat_settings=true" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(
  d.get('persistent',{}).get('xpack.inference.elastic.url','') or
  d.get('transient',{}).get('xpack.inference.elastic.url','') or
  d.get('defaults',{}).get('xpack.inference.elastic.url','')
)" 2>/dev/null || echo "")

  if [ -z "$EIS_ENDPOINT" ]; then
    echo ""
    echo "WARNING: xpack.inference.elastic.url is not configured on ES."
    echo "QA keys require the inference URL flag when starting ES:"
    echo ""
    if [ "$TARGET" = "stack" ]; then
      echo "  yarn es snapshot --license trial -E xpack.inference.elastic.url=$EIS_QA_URL"
    else
      echo "  yarn es serverless -E xpack.inference.elastic.url=$EIS_QA_URL"
    fi
    echo ""
    echo "Restart ES with that flag, then re-run this script."
    exit 1
  fi

  echo "EIS endpoint: $EIS_ENDPOINT"

  # Check if already enabled
  CCM_STATUS=$(curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL/_inference/_ccm" 2>/dev/null || echo "{}")
  ALREADY=$(echo "$CCM_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('enabled',False))" 2>/dev/null || echo "False")
  if [ "$ALREADY" = "True" ]; then
    echo "CCM is already enabled. Nothing to do."
    exit 0
  fi

  # Push key
  echo ""
  echo "==> Pushing QA CCM key to ES..."
  RESULT_HTTP=$(curl $CURL_ES_OPTS -o /dev/null -w "%{http_code}" -u "$ES_AUTH" -X PUT "$ES_URL/_inference/_ccm" \
    -H "Content-Type: application/json" \
    -d "{\"api_key\": \"$API_KEY\"}")

  if [[ "$RESULT_HTTP" -ge 200 && "$RESULT_HTTP" -lt 300 ]]; then
    echo "Success (HTTP $RESULT_HTTP)."
  else
    echo "ERROR: PUT _inference/_ccm returned HTTP $RESULT_HTTP"
    curl $CURL_ES_OPTS -u "$ES_AUTH" -X PUT "$ES_URL/_inference/_ccm" \
      -H "Content-Type: application/json" \
      -d "{\"api_key\": \"$API_KEY\"}"
    echo ""
    exit 1
  fi

  echo ""
  echo "==> Verifying..."
  curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL/_inference/_ccm"
  echo ""
  echo ""
  echo "Done (QA, $TARGET)."
  exit 0
fi

# ==========================================================================
# PROD PATH — Stack (via Kibana Cloud Connect API)
# ==========================================================================

if [ "$TARGET" = "stack" ]; then
  echo ""
  echo "--- Prod Path (stack via Kibana) ---"

  KBN_HOST="http://localhost:${KBN_PORT}"

  # Auto-detect base path
  REDIRECT_URL=$(curl -s -o /dev/null -w "%{redirect_url}" "$KBN_HOST/" 2>/dev/null || echo "")
  BASE_PATH=$(echo "$REDIRECT_URL" | python3 -c "
from urllib.parse import urlparse
import sys
p = urlparse(sys.stdin.read().strip()).path.rstrip('/')
print(p if p else '')
" 2>/dev/null || echo "")
  KBN_URL="${KBN_HOST}${BASE_PATH}"
  echo "Kibana: $KBN_URL"

  KBN_HEADERS=(-H "Content-Type: application/json" -H "kbn-xsrf: true" -H "x-elastic-internal-origin: Kibana")

  echo ""
  echo "==> Disconnecting existing cluster (if any)..."
  curl -s -u "$ES_AUTH" -X DELETE "$KBN_URL/internal/cloud_connect/cluster" \
    "${KBN_HEADERS[@]}" > /dev/null 2>&1 || true

  echo "==> Authenticating with Cloud Connect..."
  AUTH_RESPONSE=$(curl -s -u "$ES_AUTH" -X POST "$KBN_URL/internal/cloud_connect/authenticate" \
    "${KBN_HEADERS[@]}" \
    -d "{\"apiKey\":\"$API_KEY\"}")

  echo "$AUTH_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$AUTH_RESPONSE"

  SUCCESS=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null || echo "")
  if [ "$SUCCESS" != "True" ]; then
    echo "ERROR: Authentication failed."
    exit 1
  fi

  echo ""
  echo "==> Enabling EIS..."
  EIS_RESPONSE=$(curl -s -u "$ES_AUTH" -X PUT "$KBN_URL/internal/cloud_connect/cluster_details" \
    "${KBN_HEADERS[@]}" \
    -d '{"services":{"eis":{"enabled":true}}}')

  echo "$EIS_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$EIS_RESPONSE"

  echo ""
  echo "==> Verifying..."
  curl -s -u "$ES_AUTH" "$ES_URL/_inference/_ccm"
  echo ""
  echo ""
  echo "Done (prod, stack)."
  exit 0
fi

# ==========================================================================
# PROD PATH — Serverless (direct Cloud API + ES)
# ==========================================================================

echo ""
echo "--- Prod Path (serverless via Cloud API) ---"

echo ""
echo "==> Fetching cluster info..."
CLUSTER_INFO=$(curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL")
LICENSE_INFO=$(curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL/_license")

CLUSTER_UUID=$(echo "$CLUSTER_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['cluster_uuid'])")
CLUSTER_NAME=$(echo "$CLUSTER_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['cluster_name'])")
CLUSTER_VERSION=$(echo "$CLUSTER_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['version']['number'])")
LICENSE_TYPE=$(echo "$LICENSE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['license']['type'])")
LICENSE_UID=$(echo "$LICENSE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['license']['uid'])")

echo "Cluster: $CLUSTER_UUID ($CLUSTER_NAME) v$CLUSTER_VERSION — license: $LICENSE_TYPE"

echo ""
echo "==> Onboarding cluster with Cloud API..."
ONBOARD_RESPONSE=$(curl -s -X POST "$CLOUD_API/cloud-connected/clusters?create_api_key=true" \
  -H "Authorization: apiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"self_managed_cluster\": {\"id\": \"$CLUSTER_UUID\", \"name\": \"$CLUSTER_NAME\", \"version\": \"$CLUSTER_VERSION\"}, \"license\": {\"type\": \"$LICENSE_TYPE\", \"uid\": \"$LICENSE_UID\"}}")

echo "$ONBOARD_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$ONBOARD_RESPONSE"

CC_CLUSTER_ID=$(echo "$ONBOARD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null) || {
  echo "ERROR: Failed to onboard cluster."
  exit 1
}
CC_KEY=$(echo "$ONBOARD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

# If EIS is already enabled on the Cloud API side, disable first to get a fresh key
EIS_ALREADY=$(echo "$ONBOARD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('services',{}).get('eis',{}).get('enabled',False))" 2>/dev/null || echo "False")
if [ "$EIS_ALREADY" = "True" ]; then
  echo ""
  echo "EIS already enabled on Cloud API. Disabling first to get a fresh key..."
  curl -s -X PATCH "$CLOUD_API/cloud-connected/clusters/$CC_CLUSTER_ID" \
    -H "Authorization: apiKey $CC_KEY" \
    -H "Content-Type: application/json" \
    -d '{"services": {"eis": {"enabled": false}}}' > /dev/null
  echo "Waiting for Cloud API to process..."
  sleep 3
fi

echo ""
echo "==> Enabling EIS..."
MAX_RETRIES=5
RETRY_DELAY=3
EIS_RESPONSE=""
for attempt in $(seq 1 $MAX_RETRIES); do
  EIS_RESPONSE=$(curl -s -X PATCH "$CLOUD_API/cloud-connected/clusters/$CC_CLUSTER_ID" \
    -H "Authorization: apiKey $CC_KEY" \
    -H "Content-Type: application/json" \
    -d '{"services": {"eis": {"enabled": true}}}')

  if echo "$EIS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('keys',{}).get('eis') else 1)" 2>/dev/null; then
    break
  fi

  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    echo "Cloud API not ready (attempt $attempt/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  fi
done

echo "$EIS_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$EIS_RESPONSE"

EIS_KEY=$(echo "$EIS_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('keys',{}).get('eis',''))" 2>/dev/null || echo "")

if [ -z "$EIS_KEY" ]; then
  echo "ERROR: Cloud API did not return an EIS key."
  exit 1
fi

echo ""
echo "==> Pushing EIS key to ES..."
RESULT_HTTP=$(curl $CURL_ES_OPTS -o /dev/null -w "%{http_code}" -u "$ES_AUTH" -X PUT "$ES_URL/_inference/_ccm" \
  -H "Content-Type: application/json" \
  -d "{\"api_key\": \"$EIS_KEY\"}")

if [[ "$RESULT_HTTP" -ge 200 && "$RESULT_HTTP" -lt 300 ]]; then
  echo "Success (HTTP $RESULT_HTTP)."
else
  echo "ERROR: PUT _inference/_ccm returned HTTP $RESULT_HTTP"
  curl $CURL_ES_OPTS -u "$ES_AUTH" -X PUT "$ES_URL/_inference/_ccm" \
    -H "Content-Type: application/json" \
    -d "{\"api_key\": \"$EIS_KEY\"}"
  echo ""
  exit 1
fi

echo ""
echo "==> Verifying..."
curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL/_inference/_ccm"
echo ""
echo ""
echo "Done (prod, serverless)."
