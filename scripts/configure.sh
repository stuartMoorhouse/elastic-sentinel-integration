#!/usr/bin/env bash
# Post-deploy: verify the stack is reachable and Terraform-managed objects exist,
# then record non-secret endpoints in shared/env.json.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds az jq curl terraform
load_outputs
az_preflight

kibana_ready() {
  kibana_curl GET /api/status 2>/dev/null | jq -e '.status.overall.level == "available"' >/dev/null 2>&1
}
fleet_ready() {
  kibana_curl GET /api/fleet/agent_policies 2>/dev/null | jq -e '.items | length > 0' >/dev/null 2>&1
}

log "Waiting for Kibana at $KIBANA_URL (up to 10 min)"
poll 600 15 kibana_ready || die "Kibana not available at $KIBANA_URL after 10 minutes"
log "Waiting for Fleet agent policies (up to 10 min)"
poll 600 15 fleet_ready || die "Fleet not ready (no agent policies returned)"

fail=0
check() { # description, jq-expression-that-must-be-true, json
  if jq -e "$2" <<<"$3" >/dev/null 2>&1; then log "OK      $1"; else err "MISSING $1"; fail=1; fi
}

for cid in "$CASE_CONNECTOR_ID" "$ALERT_CONNECTOR_ID"; do
  c="$(kibana_curl GET "/api/actions/connector/$cid" 2>/dev/null || echo '{}')"
  check "connector $cid ($(jq -r '.name // "?"' <<<"$c"))" '.id != null' "$c"
done

rules="$(kibana_curl GET '/api/detection_engine/rules/_find?per_page=500' 2>/dev/null || echo '{}')"
if jq -e --arg n "$RULE_NAME" '[.data[]? | select(.name == $n)] | length > 0' <<<"$rules" >/dev/null 2>&1; then
  log "OK      detection rule '$RULE_NAME'"
  jq -r --arg n "$RULE_NAME" '.data[] | select(.name == $n) | "        enabled=\(.enabled) index=\(.index // [] | join(","))"' <<<"$rules"
else
  err "MISSING detection rule '$RULE_NAME'"; fail=1
fi

policies="$(kibana_curl GET /api/fleet/agent_policies 2>/dev/null || echo '{}')"
if jq -e '[.items[]? | select(.is_managed != true)] | length > 0' <<<"$policies" >/dev/null 2>&1; then
  log "OK      Fleet agent policy: $(jq -r '[.items[] | select(.is_managed != true) | .name] | join(", ")' <<<"$policies")"
else
  err "MISSING user Fleet agent policy"; fail=1
fi

(( fail == 0 )) || die "Verification failed: Terraform-managed objects are missing. Re-run terraform apply."

tmp="$(mktemp)"
jq --arg es "$ES_URL" --arg kb "$KIBANA_URL" \
  '.elasticsearch_url=$es | .kibana_url=$kb | .infra_ready=true | .config_ready=true' \
  "$SHARED_ENV" > "$tmp" && mv "$tmp" "$SHARED_ENV"

cat <<SUM

Summary
  Kibana:        $KIBANA_URL
  Elasticsearch: $ES_URL
  Fleet:         $FLEET_URL
  Workspace:     $WORKSPACE_NAME ($RESOURCE_GROUP, $LOCATION)
  Rule:          $RULE_NAME
  shared/env.json updated (infra_ready=true, config_ready=true)
Next: scripts/run_demo.sh
SUM
