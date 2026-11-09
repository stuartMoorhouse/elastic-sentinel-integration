#!/usr/bin/env bash
# Generate demo activity: failed SSH logins for several invalid users on the VM. They
# feed Sentinel via syslog and trigger the Elastic detection rule via Elastic Agent.
# Cases are created by hand in Kibana (see docs/runbook.md).
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

# --- 2. Flag ----------------------------------------------------------------
env_set '.demo_executed = true'

cat <<EOF2

Demo executed (run $RUN_TS). Verify:
  Cases:     $KIBANA_URL/app/security/cases  (create and push one yourself)
  Alerts:    $KIBANA_URL/app/security/alerts  (rule '$RULE_NAME', fires within ~5 min)
  Sentinel:  Incidents blade for workspace $WORKSPACE_NAME (alert incident 'Elastic alert: ...' within ~5 min)
  Syslog:    az monitor log-analytics query -w $WORKSPACE_ID --analytics-query "Syslog | take 5"
  Full run:  scripts/validate.sh
EOF2
