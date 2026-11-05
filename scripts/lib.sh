#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
SHARED_ENV="$ROOT_DIR/shared/env.json"
RESULTS_DIR="$ROOT_DIR/results"

# Optional: export EXPECTED_AZ_USER=<login> to also assert the signed-in user.
EXPECTED_AZ_USER="${EXPECTED_AZ_USER:-}"
SENTINEL_API="2023-02-01"
ONBOARD_API="2024-03-01"
DEMO_TAG="elastic-sentinel-demo"
DEMO_INDEX="logs-demo-sentinel-default"

# ---------- logging ----------
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

# ---------- temp files / cleanup ----------
CURL_CFG=""
cleanup_lib() { [[ -n "$CURL_CFG" && -f "$CURL_CFG" ]] && rm -f "$CURL_CFG"; return 0; }
trap cleanup_lib EXIT

# ---------- terraform outputs ----------
tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null \
    || die "Terraform output '$1' unavailable. Has 'terraform apply' completed in $TF_DIR?"
}

load_outputs() {
  require_cmds terraform jq curl
  RESOURCE_GROUP="$(tf_out resource_group_name)"
  LOCATION="$(tf_out location)"
  VM_IP="$(tf_out vm_public_ip)"
  SSH_KEY="$(tf_out ssh_private_key_path)"
  ES_URL="$(tf_out elasticsearch_url)"; ES_URL="${ES_URL%/}"
  KIBANA_URL="$(tf_out kibana_url)"; KIBANA_URL="${KIBANA_URL%/}"
  FLEET_URL="$(tf_out fleet_url)"
  ELASTIC_USER="$(tf_out elastic_username)"
  ELASTIC_PASS="$(tf_out elastic_password)"
  WORKSPACE_ID="$(tf_out log_analytics_workspace_id)"
  WORKSPACE_NAME="$(tf_out log_analytics_workspace_name)"
  SUBSCRIPTION_ID="$(tf_out subscription_id)"
  LA_ALERT="$(tf_out sentinel_alert_logicapp_name)"
  LA_INCIDENT="$(tf_out sentinel_incident_logicapp_name)"
  LA_GET_INCIDENT="$(tf_out sentinel_get_incident_logicapp_name)"
  EH_NAMESPACE="$(tf_out event_hub_namespace)"
  EH_NAME="$(tf_out event_hub_name)"
  CASE_CONNECTOR_ID="$(tf_out kibana_case_connector_id)"
  ALERT_CONNECTOR_ID="$(tf_out kibana_alert_connector_id)"
  RULE_NAME="$(tf_out detection_rule_name)"
  # Relative key path is relative to the terraform dir
  [[ "$SSH_KEY" = /* ]] || SSH_KEY="$TF_DIR/$SSH_KEY"

  # Credentials go in a 0600 curl config so they never appear in the process list.
  CURL_CFG="$(mktemp)"
  chmod 600 "$CURL_CFG"
  local u p
  u="${ELASTIC_USER//\\/\\\\}"; u="${u//\"/\\\"}"
  p="${ELASTIC_PASS//\\/\\\\}"; p="${p//\"/\\\"}"
  printf 'user = "%s:%s"\n' "$u" "$p" > "$CURL_CFG"

  WORKSPACE_ARM_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$WORKSPACE_NAME"
  mkdir -p "$RESULTS_DIR"
}

# ---------- Azure preflight ----------
az_preflight() {
  require_cmds az
  local acct sub user
  acct="$(az account show -o json 2>/dev/null)" || die "Not logged in to Azure. Run: az login"
  sub="$(jq -r '.id' <<<"$acct")"
  user="$(jq -r '.user.name' <<<"$acct")"
  if [[ -n "$EXPECTED_AZ_USER" && "$user" != "$EXPECTED_AZ_USER" ]]; then
    die "az user is '$user', expected '$EXPECTED_AZ_USER'."
  fi
  [[ "$sub" == "$SUBSCRIPTION_ID" ]] \
    || die "az subscription is '$sub', expected '$SUBSCRIPTION_ID'. Run: az account set --subscription $SUBSCRIPTION_ID"
  log "Azure preflight OK ($user, $sub)"
}

# ---------- HTTP helpers ----------
# _http BASE METHOD PATH [JSON_BODY]  -> body on stdout; non-2xx/3xx returns 1 (body to stderr)
HTTP_CODE=""
_http() {
  local base="$1" method="$2" path="$3" data="${4:-}" out code
  out="$(mktemp)"
  local args=(-sS -K "$CURL_CFG" -o "$out" -w '%{http_code}' --connect-timeout 10 --max-time 60
    -X "$method" -H 'Content-Type: application/json' -H 'kbn-xsrf: true'
    -H 'x-elastic-internal-origin: kibana' -H 'elastic-api-version: 2023-10-31')
  [[ -n "$data" ]] && args+=(--data-binary "$data")
  if ! code="$(curl "${args[@]}" "$base$path")"; then
    rm -f "$out"
    err "Cannot reach $base (is the deployment up and the URL correct?)"
    return 2
  fi
  HTTP_CODE="$code"
  cat "$out"
  rm -f "$out"
  if (( code >= 400 )); then
    err "$method $base$path returned HTTP $code"
    return 1
  fi
}
es_curl()     { _http "$ES_URL" "$@"; }
kibana_curl() { _http "$KIBANA_URL" "$@"; }

# ---------- Azure REST / Log Analytics ----------
az_rest() { # METHOD URL [BODY]
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    az rest --method "$method" --url "$url" --body "$body" -o json
  else
    az rest --method "$method" --url "$url" -o json
  fi
}
sentinel_url() { # path-after-workspace  e.g. /providers/Microsoft.SecurityInsights/incidents
  printf 'https://management.azure.com%s%s?api-version=%s' "$WORKSPACE_ARM_ID" "$1" "${2:-$SENTINEL_API}"
}
la_query() { # KQL -> JSON array on stdout
  az monitor log-analytics query -w "$WORKSPACE_ID" --analytics-query "$1" -o json
}

# ---------- env.json ----------
env_set() { # jq-filter with --argjson style args passed via env: env_set '.key = true'
  local tmp
  tmp="$(mktemp)"
  jq "$1" "$SHARED_ENV" > "$tmp" && mv "$tmp" "$SHARED_ENV"
}

# poll TIMEOUT_SECS INTERVAL_SECS cmd...  (returns 0 as soon as cmd succeeds)
poll() {
  local timeout="$1" interval="$2" end; shift 2
  end=$(( $(date +%s) + timeout ))
  while true; do
    if "$@"; then return 0; fi
    (( $(date +%s) >= end )) && return 1
    sleep "$interval"
  done
}
