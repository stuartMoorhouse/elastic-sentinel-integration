#!/usr/bin/env bash
# Runs acceptance checks 1-13 and writes results/validation-<timestamp>.json.
# Check 14 (terraform destroy leaves nothing behind) is manual.
# Checks 10-13 are the Sentinel -> Elastic and round-trip sync checks.
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
  [[ "$3" == "PASS" || "$3" == "SKIP" ]] || FAILED=1
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

# 6 -- Elastic alert pushed directly to Sentinel as an incident (via the alert Logic App)
_la_rows() { # kql -> sets LA_JSON, succeeds if non-empty
  LA_JSON="$(la_query "$1" 2>/dev/null)" || return 1
  jq -e 'length > 0' <<<"$LA_JSON" >/dev/null
}
check6() {
  local name="Elastic alert appears as a Sentinel incident"
  # The alert Logic App titles incidents "Elastic alert: <rule name>".
  if poll 600 30 _la_rows "SecurityIncident | where CreatedTime >= datetime($RUN_ISO) | where Title startswith 'Elastic alert' | take 5"; then
    record 6 "$name" PASS "incident=$(jq -r '.[0].Title' <<<"$LA_JSON")"
  else
    record 6 "$name" TIMEOUT "no 'Elastic alert' SecurityIncident within 10 min (check the alert Logic App run history; does its managed identity have the Sentinel Contributor role?)"
  fi
}

# 7 -- case synced to Sentinel incident
check7() {
  local n="Case synced to Sentinel incident" found cid c ext title cstatus inc istatus ititle expect
  # The case is created by hand in Kibana. Use the most recently updated case that was pushed.
  found="$(kibana_curl GET "/api/cases/_find?owner=securitySolution&sortField=updatedAt&sortOrder=desc&perPage=50" 2>/dev/null \
    | jq -c '[.cases[] | select(.external_service != null)][0] // empty')"
  [[ -n "$found" ]] || { record 7 "$n" SKIP "no case has been pushed to Sentinel yet (create a case in Kibana and push it)"; return; }
  cid="$(jq -r '.id' <<<"$found")"
  ext="$(jq -r '.external_service.external_id' <<<"$found")"
  title="$(jq -r '.title' <<<"$found")"
  cstatus="$(jq -r '.status' <<<"$found")"
  inc="$(az_rest GET "$(sentinel_url "/providers/Microsoft.SecurityInsights/incidents/$ext")" 2>&1)" \
    || { record 7 "$n" FAIL "case '$title' points at incident $ext, which was not found: $(head -c 200 <<<"$inc")"; return; }
  istatus="$(jq -r '.properties.status' <<<"$inc")"
  ititle="$(jq -r '.properties.title' <<<"$inc")"
  case "$cstatus" in open) expect=New ;; in-progress) expect=Active ;; closed) expect=Closed ;; *) expect="?" ;; esac
  if [[ "$istatus" == "$expect" ]]; then
    record 7 "$n" PASS "case '$title' ($cstatus) -> incident $ext '$ititle' status=$istatus"
  else
    record 7 "$n" FAIL "case '$title' is $cstatus (expected incident $expect) but incident $ext is $istatus; push the case again"
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

# ---- Bidirectional sync checks (10-13) ----
NATIVE_GUID=""; NATIVE_CASE=""; NATIVE_TITLE=""
_native_case() {
  local r
  r="$(kibana_curl GET "/api/cases/_find?owner=securitySolution&tags=sentinel-incident-$NATIVE_GUID" 2>/dev/null)" || return 1
  NATIVE_CASE="$(jq -c '.cases[0] // empty' <<<"$r")"
  [[ -n "$NATIVE_CASE" ]]
}
_native_case_status() { # expected status
  _native_case && [[ "$(jq -r '.status' <<<"$NATIVE_CASE")" == "$1" ]]
}

# 10 -- Sentinel-native incident becomes a Kibana case (automation rule -> playbook -> Cases API)
check10() {
  local n="Sentinel incident creates an Elastic case"
  NATIVE_GUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z')"
  NATIVE_TITLE="Sentinel-native demo incident $STAMP"
  incident_put "$NATIVE_GUID" "$NATIVE_TITLE" Medium New >/dev/null 2>&1 \
    || { record 10 "$n" FAIL "could not create the Sentinel incident"; return; }
  if poll 300 15 _native_case; then
    record 10 "$n" PASS "incident $NATIVE_GUID -> case $(jq -r '.id' <<<"$NATIVE_CASE") '$(jq -r '.title' <<<"$NATIVE_CASE")'"
  else
    record 10 "$n" TIMEOUT "no case tagged sentinel-incident-$NATIVE_GUID within 5 min (automation rules enabled? playbook run history?)"
  fi
}

# 11 -- status change in Sentinel reaches the case
check11() {
  local n="Sentinel status change updates the Elastic case"
  [[ -n "$NATIVE_GUID" && -n "$NATIVE_CASE" ]] || { record 11 "$n" SKIP "check 10 did not produce a case"; return; }
  incident_set_status "$NATIVE_GUID" Active >/dev/null 2>&1 || { record 11 "$n" FAIL "could not set the incident to Active"; return; }
  poll 300 15 _native_case_status in-progress \
    && record 11 "$n" PASS "incident Active -> case in-progress" \
    || record 11 "$n" TIMEOUT "case did not become in-progress within 5 min"
}

# 12 -- closing the case in Elastic closes the Sentinel incident (case connector push)
_incident_status() { # expected
  local st
  st="$(az_rest GET "$(sentinel_url "/providers/Microsoft.SecurityInsights/incidents/$NATIVE_GUID")" 2>/dev/null | jq -r '.properties.status')" || return 1
  [[ "$st" == "$1" ]]
}
check12() {
  local n="Closing the Elastic case closes the Sentinel incident" cid ver
  [[ -n "$NATIVE_CASE" ]] || { record 12 "$n" SKIP "check 10 did not produce a case"; return; }
  _native_case || { record 12 "$n" FAIL "case not found"; return; }
  cid="$(jq -r '.id' <<<"$NATIVE_CASE")"; ver="$(jq -r '.version' <<<"$NATIVE_CASE")"
  kibana_curl PATCH /api/cases "$(jq -n --arg id "$cid" --arg v "$ver" '{cases:[{id:$id,version:$v,status:"closed"}]}')" >/dev/null 2>&1 \
    || { record 12 "$n" FAIL "could not close the case"; return; }
  kibana_curl POST "/api/cases/$cid/connector/$CASE_CONNECTOR_ID/_push" '{}' >/dev/null 2>&1 \
    || { record 12 "$n" FAIL "push to Sentinel failed"; return; }
  poll 180 10 _incident_status Closed \
    && record 12 "$n" PASS "case closed + pushed -> incident $NATIVE_GUID Closed" \
    || record 12 "$n" FAIL "incident $NATIVE_GUID is not Closed after the push"
}

# 13 -- closing the Sentinel incident that came from an Elastic alert closes that alert
_alert_closed() {
  local q r
  q="$(jq -n --arg n "$RULE_NAME" '{size:0, track_total_hits:true, query:{bool:{filter:[{term:{"kibana.alert.rule.name":$n}},{term:{"kibana.alert.workflow_status":"closed"}}]}}}')"
  r="$(es_curl POST '/.alerts-security.alerts-default/_search?ignore_unavailable=true' "$q" 2>/dev/null)" || return 1
  (( $(jq -r '.hits.total.value // 0' <<<"$r") > 0 ))
}
check13() {
  local n="Closing the Sentinel incident closes the Elastic alert" g
  g="$(az_rest GET "$(sentinel_url /providers/Microsoft.SecurityInsights/incidents)&\$filter=contains(properties/title,'Elastic%20alert')&\$top=1" 2>/dev/null | jq -r '.value[0].name // empty')"
  [[ -n "$g" ]] || { record 13 "$n" SKIP "no 'Elastic alert' incident in Sentinel (run check 6 first)"; return; }
  incident_set_status "$g" Closed >/dev/null 2>&1 || { record 13 "$n" FAIL "could not close incident $g"; return; }
  poll 300 15 _alert_closed \
    && record 13 "$n" PASS "incident $g Closed -> alert workflow_status closed" \
    || record 13 "$n" TIMEOUT "alert not closed within 5 min"
}

# Quick checks first, then the slow polling ones.
for fn in check1 check2 check3 check4 check5 check6 check7 check8 check9 check10 check11 check12 check13; do
  "$fn" || record "${fn#check}" "$fn crashed" FAIL "unexpected error"
done

jq -n --arg ts "$STAMP" --arg run "$RUN_ISO" --argjson r "$RESULTS" \
  '{timestamp:$ts, demo_run_start:$run, results:$r, all_passed: ([$r[] | select(.status != "PASS" and .status != "SKIP")] | length == 0)}' > "$OUT"
log "Results written to $OUT"
echo "Check 14 is manual: run 'terraform destroy' and confirm the resource group $RESOURCE_GROUP no longer exists."
exit "$FAILED"
