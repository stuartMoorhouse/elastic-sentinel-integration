#!/usr/bin/env bash
# Runs acceptance checks 1-9 and writes results/validation-<timestamp>.json.
# Check 10 (terraform destroy leaves nothing behind) is manual.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds az jq curl terraform
load_outputs
az_preflight

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$RESULTS_DIR/validation-$STAMP.json"
RESULTS='[]'
FAILED=0

record() { # num name status detail
  printf '%-8s %s. %s - %s\n' "[$3]" "$1" "$2" "$4"
  RESULTS="$(jq --argjson n "$1" --arg name "$2" --arg s "$3" --arg d "$4" \
    '. + [{check:$n, name:$name, status:$s, detail:$d}]' <<<"$RESULTS")"
  [[ "$3" == "PASS" ]] || FAILED=1
}

RUN_EPOCH="$(jq -r '.started_epoch // empty' "$RESULTS_DIR/last_run.json" 2>/dev/null || true)"
if [[ -z "$RUN_EPOCH" ]]; then
  warn "results/last_run.json missing (run_demo.sh not executed?); using now-15m as the window start"
  RUN_EPOCH=$(( $(date +%s) - 900 ))
fi
RUN_ISO="$(date -u -r "$RUN_EPOCH" +%FT%TZ 2>/dev/null || date -u -d "@$RUN_EPOCH" +%FT%TZ)"

# 1 -- Elastic deployment healthy
check1() {
  local k h
  k="$(kibana_curl GET /api/status 2>/dev/null | jq -r '.status.overall.level // "unknown"')" || k="unreachable"
  h="$(es_curl GET /_cluster/health 2>/dev/null | jq -r '.status // "unknown"')" || h="unreachable"
  if [[ "$k" == "available" && ( "$h" == "green" || "$h" == "yellow" ) ]]; then
    record 1 "Elastic deployment healthy" PASS "kibana=$k es=$h"
  else
    record 1 "Elastic deployment healthy" FAIL "kibana=$k es=$h"
  fi
}

# 2 -- Sentinel onboarded
check2() {
  local st
  if st="$(az_rest GET "https://management.azure.com$WORKSPACE_ARM_ID/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=$ONBOARD_API" 2>&1)"; then
    record 2 "Sentinel onboarded" PASS "$(jq -r '.name' <<<"$st")"
  else
    record 2 "Sentinel onboarded" FAIL "$(head -c 300 <<<"$st")"
  fi
}

# 3 -- Fleet agent healthy
check3() {
  poll 300 15 _agent_healthy \
    && record 3 "Fleet agent healthy" PASS "$AGENT_SUMMARY" \
    || record 3 "Fleet agent healthy" TIMEOUT "${AGENT_SUMMARY:-no agents}"
}
AGENT_SUMMARY=""
_agent_healthy() {
  local r
  r="$(kibana_curl GET '/api/fleet/agents?perPage=100' 2>/dev/null)" || return 1
  AGENT_SUMMARY="$(jq -r '[.items[]? | "\(.local_metadata.host.hostname // .id)=\(.status)"] | join(",")' <<<"$r")"
  jq -e '[.items[]? | select(.status == "online" or .status == "healthy")] | length > 0' <<<"$r" >/dev/null
}

# 4 -- connectors exist and test action succeeds
check4() {
  local cid type params res ok=1 detail=""
  for cid in "$CASE_CONNECTOR_ID" "$ALERT_CONNECTOR_ID"; do
    type="$(kibana_curl GET "/api/actions/connector/$cid" 2>/dev/null | jq -r '.connector_type_id // empty')" || type=""
    if [[ -z "$type" ]]; then ok=0; detail+="$cid missing; "; continue; fi
    case "$type" in
      .cases-webhook)
        params='{"subAction":"pushToService","subActionParams":{"incident":{"title":"Connector test","description":"validate.sh connector test","externalId":null,"tags":["'"$DEMO_TAG"'"]},"comments":[]}}' ;;
      *)
        params='{"body":"{\"test\":\"validate.sh connector test\"}"}' ;;
    esac
    res="$(kibana_curl POST "/api/actions/connector/$cid/_execute" "{\"params\":$params}" 2>&1)" || res='{"status":"error"}'
    if [[ "$(jq -r '.status // "error"' <<<"$res" 2>/dev/null)" == "ok" ]]; then
      detail+="$cid($type) ok; "
    else
      ok=0; detail+="$cid($type) $(jq -rc '.message // .' <<<"$res" 2>/dev/null | head -c 200); "
    fi
  done
  (( ok )) && record 4 "Connectors exist and test succeeds" PASS "$detail" \
           || record 4 "Connectors exist and test succeeds" FAIL "$detail"
}

# 5 -- alert for the rule
ALERT_COUNT=0
_alert_found() {
  local q r
  q="$(jq -n --arg n "$RULE_NAME" --arg t "$RUN_ISO" \
    '{size:0, track_total_hits:true, query:{bool:{filter:[{term:{"kibana.alert.rule.name":$n}},{range:{"@timestamp":{gte:$t}}}]}}}')"
  r="$(es_curl POST '/.alerts-security.alerts-default/_search?ignore_unavailable=true' "$q" 2>/dev/null)" || return 1
  ALERT_COUNT="$(jq -r '.hits.total.value // 0' <<<"$r")"
  (( ALERT_COUNT > 0 ))
}
check5() {
  poll 300 15 _alert_found \
    && record 5 "Detection alert fired" PASS "$ALERT_COUNT alert(s) for '$RULE_NAME' since $RUN_ISO" \
    || record 5 "Detection alert fired" TIMEOUT "no alert for '$RULE_NAME' within 5 min (rule must be enabled; run_demo.sh executed?)"
}

# 6 -- alert in ElasticAlerts_CL and Sentinel incident
_la_rows() { # kql -> sets LA_JSON, succeeds if non-empty
  LA_JSON="$(la_query "$1" 2>/dev/null)" || return 1
  jq -e 'length > 0' <<<"$LA_JSON" >/dev/null
}
check6() {
  local d=""
  if poll 600 30 _la_rows "ElasticAlerts_CL | take 5"; then d="ElasticAlerts_CL rows=$(jq length <<<"$LA_JSON")"
  else record 6 "Alert in ElasticAlerts_CL and Sentinel incident" TIMEOUT "no ElasticAlerts_CL rows within 10 min"; return; fi
  # Incident title comes from the NRT rule; match Elastic-related titles created since the run.
  if poll 600 30 _la_rows "SecurityIncident | where CreatedTime >= datetime($RUN_ISO) | where Title has 'Elastic' or Title has '$RULE_NAME' | take 5"; then
    record 6 "Alert in ElasticAlerts_CL and Sentinel incident" PASS "$d; incident=$(jq -r '.[0].Title' <<<"$LA_JSON")"
  else
    record 6 "Alert in ElasticAlerts_CL and Sentinel incident" TIMEOUT "$d; no SecurityIncident from NRT rule within 10 min"
  fi
}

# 7 -- case synced to Sentinel incident
check7() {
  local f="$RESULTS_DIR/last_case.json" cid c ext inc comments status ncom
  [[ -f "$f" ]] || { record 7 "Case synced to Sentinel incident" FAIL "results/last_case.json missing (run run_demo.sh)"; return; }
  cid="$(jq -r '.case_id' "$f")"
  c="$(kibana_curl GET "/api/cases/$cid" 2>&1)" || { record 7 "Case synced to Sentinel incident" FAIL "case $cid not found"; return; }
  ext="$(jq -r '.external_service.external_id // empty' <<<"$c")"
  [[ -n "$ext" ]] || { record 7 "Case synced to Sentinel incident" FAIL "case $cid has no external_service (not pushed to Sentinel; push may need manual 'Push' or connector-on-create)"; return; }
  inc="$(az_rest GET "$(sentinel_url "/providers/Microsoft.SecurityInsights/incidents/$ext")" 2>&1)" \
    || { record 7 "Case synced to Sentinel incident" FAIL "incident $ext not found: $(head -c 200 <<<"$inc")"; return; }
  status="$(jq -r '.properties.status' <<<"$inc")"
  comments="$(az_rest GET "$(sentinel_url "/providers/Microsoft.SecurityInsights/incidents/$ext/comments")" 2>/dev/null || echo '{"value":[]}')"
  ncom="$(jq '.value | length' <<<"$comments")"
  # Case in-progress -> Sentinel Active (Logic App maps statuses); at least one comment expected.
  if [[ "$status" == "Active" && "$ncom" -ge 1 ]]; then
    record 7 "Case synced to Sentinel incident" PASS "incident=$ext status=$status comments=$ncom"
  else
    record 7 "Case synced to Sentinel incident" FAIL "incident=$ext status=$status (expected Active) comments=$ncom (expected >=1)"
  fi
}

# 8 -- Syslog in Log Analytics
check8() {
  poll 600 30 _la_rows "Syslog | where TimeGenerated > ago(1d) | take 5" \
    && record 8 "Syslog rows in Log Analytics" PASS "rows=$(jq length <<<"$LA_JSON") host=$(jq -r '.[0].Computer // "?"' <<<"$LA_JSON")" \
    || record 8 "Syslog rows in Log Analytics" TIMEOUT "no Syslog rows within 10 min (AMA/DCR may still be starting)"
}

# 9 -- data exported through Event Hub reaches Elastic
EH_COUNT=0
_eh_docs() {
  EH_COUNT="$(es_curl GET '/logs-azure.eventhub-*/_count?ignore_unavailable=true' 2>/dev/null | jq -r '.count // 0')" || return 1
  (( EH_COUNT > 0 ))
}
check9() {
  poll 900 30 _eh_docs \
    && record 9 "Event Hub data searchable in Elastic" PASS "$EH_COUNT docs in logs-azure.eventhub-*" \
    || record 9 "Event Hub data searchable in Elastic" TIMEOUT "no docs in logs-azure.eventhub-* within 15 min"
}

# Quick checks first, then the slow polling ones.
for fn in check1 check2 check3 check4 check5 check6 check7 check8 check9; do
  "$fn" || record "${fn#check}" "$fn crashed" FAIL "unexpected error"
done

jq -n --arg ts "$STAMP" --arg run "$RUN_ISO" --argjson r "$RESULTS" \
  '{timestamp:$ts, demo_run_start:$run, results:$r, all_passed: ([$r[] | select(.status != "PASS")] | length == 0)}' > "$OUT"
log "Results written to $OUT"
echo "Check 10 is manual: run 'terraform destroy' and confirm the resource group $RESOURCE_GROUP no longer exists."
exit "$FAILED"
