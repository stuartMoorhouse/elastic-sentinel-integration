#!/usr/bin/env bash
# Create a Sentinel-native incident for the main demo ("an alert comes from Sentinel").
# The incident is exported to Elasticsearch (Log Analytics export -> Event Hub -> Elastic Agent),
# where the "Microsoft Sentinel Incident Raised" rule turns it into an Elastic alert. In testing the
# alert appeared in about a minute; allow up to 15 minutes, so run this before the demo.
#
# Usage: scripts/create-sentinel-incident.sh [--wait]
#   --wait  poll until the Elastic alert for this incident exists (up to 20 minutes)
#
# The title must not contain "Elastic" and the description must not contain "Elastic Security case":
# the rule excludes incidents that Elastic itself created.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAIT=0
[[ "${1:-}" == "--wait" ]] && WAIT=1

require_cmds az jq curl terraform uuidgen
load_outputs
az_preflight

GUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
TITLE="Suspicious SSH activity on Linux host (demo)"
DESC=$'A security tool in Microsoft Sentinel flagged repeated failed SSH logins for several invalid user names against the Linux host elastic-sentinel-vm, all from one source address (127.0.0.1).\n\nThe customer runs an authenticated vulnerability scan that can look like this. Verify against the host authentication logs before acting.'

body="$(jq -n --arg t "$TITLE" --arg d "$DESC" \
  '{properties:{title:$t, description:$d, severity:"Medium", status:"New"}}')"
az_rest PUT "$(sentinel_url "/providers/Microsoft.SecurityInsights/incidents/$GUID")" "$body" >/dev/null
log "Created Sentinel incident $GUID: $TITLE"

# The Sentinel fields copied onto an alert are stored in _source but not indexed in the alerts index,
# so the incident id cannot be searched. Fetch the rule's newest alerts and look for it in _source.
alert_exists() {
  es_curl POST '/.alerts-security.alerts-default/_search' \
    "$(jq -n --arg r "$SENTINEL_RULE_NAME" '{size:100, sort:[{"@timestamp":"desc"}], _source:["azure.eventhub.IncidentName"], query:{term:{"kibana.alert.rule.name":$r}}}')" \
    | jq -e --arg g "$GUID" 'any(.hits.hits[]._source.azure.eventhub.IncidentName; . == $g)' >/dev/null 2>&1
}

if (( WAIT )); then
  log "Waiting for the Elastic alert (usually a few minutes, up to 15)"
  poll 1200 30 alert_exists || die "No Elastic alert for incident $GUID after 20 minutes. Check Fleet and the Event Hub export (runbook: If something does not work)."
  log "Alert is in Kibana: $KIBANA_URL/app/security/alerts"
else
  log "The Elastic alert usually appears within a few minutes (up to 15): $KIBANA_URL/app/security/alerts"
fi
