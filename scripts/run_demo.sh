#!/usr/bin/env bash
# Generate demo activity: failed SSH logins for several invalid users on the VM (they
# feed Sentinel via syslog and trigger the Elastic detection rule via Elastic Agent),
# and a Kibana case that syncs to Sentinel.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds az jq curl terraform
load_outputs
az_preflight

RUN_TS="$(date +%s)"
printf '{"started_epoch": %s, "started_iso": "%s"}\n' "$RUN_TS" "$(date -u +%FT%TZ)" > "$RESULTS_DIR/last_run.json"

# --- 1. Failed SSH logins on the VM, via az vm run-command (no inbound SSH needed) --
VM_NAME="$(az vm list -g "$RESOURCE_GROUP" --query '[0].name' -o tsv)"
[[ -n "$VM_NAME" ]] || die "No VM found in resource group $RESOURCE_GROUP"
state="$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" --query 'instanceView.statuses[1].displayStatus' -o tsv)"
[[ "$state" == "VM running" ]] || die "VM $VM_NAME is '$state' (spot VMs can be evicted). Start it: az vm start -g $RESOURCE_GROUP -n $VM_NAME"
log "Generating failed SSH logins on $VM_NAME (az vm run-command, takes about a minute)"
remote_script='set -u
logger -p auth.warning "elastic-sentinel demo run '"$RUN_TS"'"
for i in $(seq 1 10); do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
      -o PreferredAuthentications=password,keyboard-interactive \
      "bogus-demo-user-$i@localhost" true </dev/null >/dev/null 2>&1 || true
done
echo "syslog events generated"'
out="$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "$remote_script" -o json)" || die "az vm run-command failed on $VM_NAME"
grep -q "syslog events generated" <<<"$out" || die "run-command did not complete as expected: $(jq -r '.value[0].message' <<<"$out" | head -c 300)"
echo "syslog events generated"

# --- 2. Kibana case ----------------------------------------------------------
log "Creating Kibana case"
connector="$(kibana_curl GET "/api/actions/connector/$CASE_CONNECTOR_ID")"
case_body="$(jq -n --arg t "Elastic Demo Case $RUN_TS" --arg tag "$DEMO_TAG" --argjson c "$connector" '{
  title:$t, description:"Repeated failed SSH logins for multiple invalid users, detected by the Elastic-Sentinel integration demo.",
  tags:[$tag], severity:"high", owner:"securitySolution",
  settings:{syncAlerts:false}, assignees:[],
  connector:{id:$c.id, name:$c.name, type:$c.connector_type_id, fields:null}}')"
created="$(kibana_curl POST /api/cases "$case_body")"
case_id="$(jq -r '.id' <<<"$created")"
version="$(jq -r '.version' <<<"$created")"
log "Case created: $case_id"

# Kibana only syncs a case to the external system on an explicit push.
push_case() {
  log "Pushing case to Sentinel connector ($1)"
  kibana_curl POST "/api/cases/$case_id/connector/$CASE_CONNECTOR_ID/_push" '{}' \
    | jq -c '{status, external_service: {external_id: .external_service.external_id, external_title: .external_service.external_title}}'
}
push_case "create"

sleep 5
# A push bumps the case version, so always re-read it before updating.
version="$(kibana_curl GET "/api/cases/$case_id" | jq -r '.version')"
log "Setting case status to in-progress"
upd="$(kibana_curl PATCH /api/cases "$(jq -n --arg id "$case_id" --arg v "$version" \
  '{cases:[{id:$id, version:$v, status:"in-progress"}]}')")"
case_version="$(jq -r '.[0].version' <<<"$upd")"
push_case "status update"

log "Adding comment"
kibana_curl POST "/api/cases/$case_id/comments" "$(jq -n \
  '{type:"user", owner:"securitySolution", comment:"Analyst note: repeated SSH logins for invalid users from one source, blocking the source address."}')" >/dev/null
push_case "comment"

jq -n --arg id "$case_id" --arg ver "$case_version" --argjson ts "$RUN_TS" \
  '{case_id:$id, version:$ver, created_epoch:$ts}' > "$RESULTS_DIR/last_case.json"

# --- 3. Flag ----------------------------------------------------------------
env_set '.demo_executed = true'

cat <<EOF2

Demo executed (run $RUN_TS). Verify:
  Case:      $KIBANA_URL/app/security/cases/$case_id
  Alerts:    $KIBANA_URL/app/security/alerts  (rule '$RULE_NAME', fires within ~5 min)
  Sentinel:  Incidents blade for workspace $WORKSPACE_NAME (case incident immediately; alert incident 'Elastic alert: ...' within ~5 min)
  Syslog:    az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "Syslog | take 5"
  Full run:  scripts/validate.sh
EOF2
