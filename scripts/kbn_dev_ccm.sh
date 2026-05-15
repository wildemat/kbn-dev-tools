#!/bin/bash
set -euo pipefail

EIS_QA_URL="https://inference.eu-west-1.aws.svc.qa.elastic.cloud"
VAULT_SECRET="secret/kibana-issues/dev/inference/kibana-eis-ccm"
CLOUD_API_PROD="https://cloud.elastic.co/api/v1"
CLOUD_API_QA="https://console.qa.cld.elstc.co/api/v1"

usage() {
  cat <<'EOF'
Usage: kbn-dev-ccm --stack | --sls

Environment variables:
  CCM_API_KEY   CCM key (prod or QA). If unset, auto-fetches QA key from Vault.
  CCM_NO_EIS    Set to 1 to skip EIS setup entirely.
  ES_PORT       Override ES port (default: 9201 for stack, 9200 for sls).
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
# Cloud API onboarding flow — used by:
#   - prod keys (always)
#   - portal-generated QA keys (after the direct-push QA path returns 403)
# Arg: $1 = Cloud API base URL (prod or QA)
# Reads globals: API_KEY, ES_URL, ES_AUTH, CURL_ES_OPTS
# Returns 0 on success, 1 on failure (no `exit`).
# ==========================================================================

do_cloud_api_onboard() {
  local cloud_api="$1"
  local cluster_info license_info cluster_uuid cluster_name cluster_version
  local license_type license_uid onboard_response cc_cluster_id cc_key
  local eis_already eis_response eis_key result_http attempt
  local max_retries=5 retry_delay=3

  echo ""
  echo "==> Fetching cluster info..."
  cluster_info=$(curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL")
  license_info=$(curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL/_license")

  cluster_uuid=$(echo "$cluster_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['cluster_uuid'])")
  cluster_name=$(echo "$cluster_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['cluster_name'])")
  cluster_version=$(echo "$cluster_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['version']['number'])")
  license_type=$(echo "$license_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['license']['type'])")
  license_uid=$(echo "$license_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['license']['uid'])")

  echo "Cluster: $cluster_uuid ($cluster_name) v$cluster_version — license: $license_type"

  echo ""
  echo "==> Onboarding cluster with Cloud API ($cloud_api)..."
  onboard_response=$(curl -s -X POST "$cloud_api/cloud-connected/clusters?create_api_key=true" \
    -H "Authorization: apiKey $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"self_managed_cluster\": {\"id\": \"$cluster_uuid\", \"name\": \"$cluster_name\", \"version\": \"$cluster_version\"}, \"license\": {\"type\": \"$license_type\", \"uid\": \"$license_uid\"}}")

  echo "$onboard_response" | python3 -m json.tool 2>/dev/null || echo "$onboard_response"

  cc_cluster_id=$(echo "$onboard_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null) || {
    echo "ERROR: Failed to onboard cluster."
    return 1
  }
  cc_key=$(echo "$onboard_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

  eis_already=$(echo "$onboard_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('services',{}).get('eis',{}).get('enabled',False))" 2>/dev/null || echo "False")
  if [ "$eis_already" = "True" ]; then
    echo ""
    echo "EIS already enabled on Cloud API. Disabling first to get a fresh key..."
    curl -s -X PATCH "$cloud_api/cloud-connected/clusters/$cc_cluster_id" \
      -H "Authorization: apiKey $cc_key" \
      -H "Content-Type: application/json" \
      -d '{"services": {"eis": {"enabled": false}}}' > /dev/null
    echo "Waiting for Cloud API to process..."
    sleep 3
  fi

  echo ""
  echo "==> Enabling EIS..."
  eis_response=""
  for attempt in $(seq 1 $max_retries); do
    eis_response=$(curl -s -X PATCH "$cloud_api/cloud-connected/clusters/$cc_cluster_id" \
      -H "Authorization: apiKey $cc_key" \
      -H "Content-Type: application/json" \
      -d '{"services": {"eis": {"enabled": true}}}')

    if echo "$eis_response" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('keys',{}).get('eis') else 1)" 2>/dev/null; then
      break
    fi

    if [ "$attempt" -lt "$max_retries" ]; then
      echo "Cloud API not ready (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
      sleep $retry_delay
    fi
  done

  echo "$eis_response" | python3 -m json.tool 2>/dev/null || echo "$eis_response"

  eis_key=$(echo "$eis_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('keys',{}).get('eis',''))" 2>/dev/null || echo "")

  if [ -z "$eis_key" ]; then
    echo "ERROR: Cloud API did not return an EIS key."
    return 1
  fi

  echo ""
  echo "==> Pushing EIS key to ES..."
  result_http=$(curl $CURL_ES_OPTS -o /dev/null -w "%{http_code}" -u "$ES_AUTH" -X PUT "$ES_URL/_inference/_ccm" \
    -H "Content-Type: application/json" \
    -d "{\"api_key\": \"$eis_key\"}")

  if [[ "$result_http" -ge 200 && "$result_http" -lt 300 ]]; then
    echo "Success (HTTP $result_http)."
  else
    echo "ERROR: PUT _inference/_ccm returned HTTP $result_http"
    curl $CURL_ES_OPTS -u "$ES_AUTH" -X PUT "$ES_URL/_inference/_ccm" \
      -H "Content-Type: application/json" \
      -d "{\"api_key\": \"$eis_key\"}"
    echo ""
    return 1
  fi

  echo ""
  echo "==> Verifying..."
  curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL/_inference/_ccm"
  echo ""
  return 0
}

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

  # Try direct push — works for Vault-provisioned keys that are pre-scoped
  # for direct EIS validation. Portal-generated QA keys lack that scope and
  # will 403 here; we fall back to the Cloud API onboarding flow below.
  echo ""
  echo "==> Pushing QA CCM key to ES..."
  RESPONSE_FILE=$(mktemp)
  trap 'rm -f "$RESPONSE_FILE"' EXIT
  RESULT_HTTP=$(curl $CURL_ES_OPTS -o "$RESPONSE_FILE" -w "%{http_code}" -u "$ES_AUTH" -X PUT "$ES_URL/_inference/_ccm" \
    -H "Content-Type: application/json" \
    -d "{\"api_key\": \"$API_KEY\"}")
  RESPONSE_BODY=$(cat "$RESPONSE_FILE")

  if [[ "$RESULT_HTTP" -ge 200 && "$RESULT_HTTP" -lt 300 ]]; then
    echo "Success (HTTP $RESULT_HTTP)."
    echo ""
    echo "==> Verifying..."
    curl $CURL_ES_OPTS -u "$ES_AUTH" "$ES_URL/_inference/_ccm"
    echo ""
    echo ""
    echo "Done (QA direct, $TARGET)."
    exit 0
  fi

  echo "Direct push returned HTTP $RESULT_HTTP:"
  echo "$RESPONSE_BODY"
  echo ""

  # 403 with the EIS auth-permission pattern => portal-generated key.
  # Re-route through the QA Cloud API onboarding flow.
  if [[ "$RESULT_HTTP" == "403" ]] && echo "$RESPONSE_BODY" | grep -qE 'authorization_request|API key does not have required permissions'; then
    echo "Key lacks direct EIS permissions — looks like a portal-generated cluster key."
    echo "Falling back to QA Cloud API onboarding flow..."
    if do_cloud_api_onboard "$CLOUD_API_QA"; then
      echo ""
      echo "Done (QA via Cloud API onboarding, $TARGET)."
      exit 0
    fi
    exit 1
  fi

  echo "ERROR: PUT _inference/_ccm failed (HTTP $RESULT_HTTP) and the error doesn't match the known portal-key 403 pattern."
  exit 1
fi

# ==========================================================================
# PROD PATH — Stack + Serverless (Cloud API onboarding + ES push)
# ==========================================================================

echo ""
echo "--- Prod Path ($TARGET via Cloud API) ---"

if do_cloud_api_onboard "$CLOUD_API_PROD"; then
  echo ""
  echo "Done (prod, $TARGET)."
  exit 0
fi
exit 1
