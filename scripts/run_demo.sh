#!/usr/bin/env bash
# Generate demo activity: syslog on the VM (Sentinel), a doc in Elasticsearch that
# triggers the detection rule, and a Kibana case that syncs to Sentinel.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds az jq curl ssh terraform
load_outputs
az_preflight

RUN_TS="$(date +%s)"
printf '{"started_epoch": %s, "started_iso": "%s"}\n' "$RUN_TS" "$(date -u +%FT%TZ)" > "$RESULTS_DIR/last_run.json"

# --- 1. Native Sentinel syslog data via the VM -------------------------------
[[ -f "$SSH_KEY" ]] || die "SSH key not found at $SSH_KEY"
log "Generating syslog events on $VM_IP"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes \
  "azureuser@$VM_IP" bash -s -- "$RUN_TS" <<'REMOTE' || die "SSH to $VM_IP failed (check NSG operator IP and VM state)"
set -u
logger -p auth.warning "malware detected demo $1"
for i in $(seq 1 10); do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
      -o PreferredAuthentications=password,keyboard-interactive \
      "bogus-demo-user-$i@localhost" true </dev/null >/dev/null 2>&1 || true
done
echo "syslog events generated"
REMOTE

# --- 2. Document for the detection rule --------------------------------------
# The Terraform-managed rule matches message:malware over logs-* (which covers
# logs-demo-sentinel-default). A data stream index name (logs-*-*) requires
# op_type=create on _create; plain _doc POST on a data stream also works.
log "Indexing demo document into $DEMO_INDEX"
doc="$(jq -n --arg ts "$(date -u +%FT%T.000Z)" \
  '{"@timestamp":$ts, message:"malware detected by demo", "event":{"category":["malware"],"kind":"event"}, tags:["elastic-sentinel-demo"]}')"
es_curl POST "/$DEMO_INDEX/_doc?refresh=wait_for" "$doc" | jq -c '{result, _index, _id}'

# --- 3. Kibana case ----------------------------------------------------------
log "Creating Kibana case"
connector="$(kibana_curl GET "/api/actions/connector/$CASE_CONNECTOR_ID")"
case_body="$(jq -n --arg t "Elastic Demo Case $RUN_TS" --arg tag "$DEMO_TAG" --argjson c "$connector" '{
  title:$t, description:"Malware detected by the Elastic-Sentinel integration demo.",
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
  '{type:"user", owner:"securitySolution", comment:"Analyst note: malware confirmed, host isolation under review."}')" >/dev/null
push_case "comment"

jq -n --arg id "$case_id" --arg ver "$case_version" --argjson ts "$RUN_TS" \
  '{case_id:$id, version:$ver, created_epoch:$ts}' > "$RESULTS_DIR/last_case.json"

# --- 4. Flag ----------------------------------------------------------------
env_set '.demo_executed = true'

cat <<EOF2

Demo executed (run $RUN_TS). Verify:
  Case:      $KIBANA_URL/app/security/cases/$case_id
  Alerts:    $KIBANA_URL/app/security/alerts  (rule '$RULE_NAME', fires within ~5 min)
  Sentinel:  Incidents blade for workspace $WORKSPACE_NAME (case incident immediately; alert incident 'Elastic alert: ...' within ~5 min)
  Syslog:    az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "Syslog | take 5"
  Full run:  scripts/validate.sh
EOF2
