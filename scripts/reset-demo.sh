#!/usr/bin/env bash
# Clear demo artefacts (cases, demo index, alerts, Sentinel incidents). Keeps infrastructure.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

require_cmds az jq curl terraform
load_outputs
az_preflight

echo "This will delete:"
echo "  - Kibana cases tagged '$DEMO_TAG'"
echo "  - Elasticsearch data stream/index $DEMO_INDEX"
echo "  - Alerts for rule '$RULE_NAME' in .alerts-security.alerts-default"
echo "  - Sentinel incidents titled 'Elastic Demo Case*' or mentioning Elastic/'$RULE_NAME'"
if (( ! YES )); then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log "Aborted"; exit 0; }
fi

# Cases
ids="$(kibana_curl GET "/api/cases/_find?tags=$DEMO_TAG&owner=securitySolution&perPage=100" | jq -c '[.cases[].id]')"
if [[ "$ids" != "[]" ]]; then
  log "Deleting cases: $ids"
  kibana_curl DELETE "/api/cases?ids=$(jq -rn --arg v "$ids" '$v|@uri')" >/dev/null
else
  log "No demo cases found"
fi

# Elasticsearch data
if es_curl DELETE "/_data_stream/$DEMO_INDEX" >/dev/null 2>&1; then log "Deleted data stream $DEMO_INDEX"
elif es_curl DELETE "/$DEMO_INDEX" >/dev/null 2>&1; then log "Deleted index $DEMO_INDEX"
else log "$DEMO_INDEX not present"; fi

q="$(jq -n --arg n "$RULE_NAME" '{query:{term:{"kibana.alert.rule.name":$n}}}')"
es_curl POST '/.alerts-security.alerts-default/_delete_by_query?refresh=true&conflicts=proceed&ignore_unavailable=true' "$q" \
  | jq -c '{deleted, failures: (.failures | length)}' || warn "alert deletion failed"

# Sentinel incidents
incs="$(az_rest GET "$(sentinel_url /providers/Microsoft.SecurityInsights/incidents)&\$top=200" )"
jq -r --arg r "$RULE_NAME" \
  '.value[] | select(.properties.title | (startswith("Elastic Demo Case") or test("Elastic";"i") or contains($r))) | "\(.name)\t\(.properties.title)"' \
  <<<"$incs" | while IFS=$'\t' read -r name title; do
    log "Deleting Sentinel incident $name ($title)"
    az rest --method DELETE --url "$(sentinel_url "/providers/Microsoft.SecurityInsights/incidents/$name")" >/dev/null \
      || warn "could not delete incident $name"
  done

rm -f "$RESULTS_DIR/last_case.json" "$RESULTS_DIR/last_run.json"
env_set '.demo_executed = false'
log "Reset complete"
