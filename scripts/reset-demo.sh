#!/usr/bin/env bash
# Clear ALL cases, security alerts and Sentinel incidents, plus the demo index.
# Keeps infrastructure. Intended for this demo deployment only.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

require_cmds az jq curl terraform
load_outputs
az_preflight

echo "This will delete EVERYTHING of these kinds in this deployment:"
echo "  - ALL Kibana cases"
echo "  - ALL security alerts in .alerts-security.alerts-default"
echo "  - ALL Sentinel incidents in workspace $WORKSPACE_NAME"
echo "  - Elasticsearch data stream/index $DEMO_INDEX"
if (( ! YES )); then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log "Aborted"; exit 0; }
fi

# Cases: all of them, any owner. Re-query until none are left (page size is capped).
for _ in $(seq 1 20); do
  ids="$(kibana_curl GET "/api/cases/_find?perPage=100" | jq -c '[.cases[].id]')"
  [[ "$ids" != "[]" ]] || break
  log "Deleting $(jq length <<<"$ids") case(s)"
  kibana_curl DELETE "/api/cases?ids=$(jq -rn --arg v "$ids" '$v|@uri')" >/dev/null || { warn "case deletion failed"; break; }
done
log "Cases remaining: $(kibana_curl GET "/api/cases/_find?perPage=1" | jq -r '.total')"

# Elasticsearch data
if es_curl DELETE "/_data_stream/$DEMO_INDEX" >/dev/null 2>&1; then log "Deleted data stream $DEMO_INDEX"
elif es_curl DELETE "/$DEMO_INDEX" >/dev/null 2>&1; then log "Deleted index $DEMO_INDEX"
else log "$DEMO_INDEX not present"; fi

# Delete every security alert, not only the current rule's.
q='{"query":{"match_all":{}}}'
es_curl POST '/.alerts-security.alerts-default/_delete_by_query?refresh=true&conflicts=proceed&ignore_unavailable=true' "$q" \
  | jq -c '{deleted, failures: (.failures | length)}' || warn "alert deletion failed"

# Sentinel incidents: all of them. Re-query the first page until none are left.
for _ in $(seq 1 20); do
  incs="$(az_rest GET "$(sentinel_url /providers/Microsoft.SecurityInsights/incidents)&\$top=200")"
  names="$(jq -r '.value[] | "\(.name)\t\(.properties.title)"' <<<"$incs")"
  [[ -n "$names" ]] || break
  deleted=0
  while IFS=$'\t' read -r name title; do
    log "Deleting Sentinel incident $name ($title)"
    if az rest --method DELETE --url "$(sentinel_url "/providers/Microsoft.SecurityInsights/incidents/$name")" >/dev/null; then
      deleted=$((deleted + 1))
    else
      warn "could not delete incident $name"
    fi
  done <<<"$names"
  (( deleted > 0 )) || { warn "no incidents could be deleted; stopping"; break; }
done

rm -f "$RESULTS_DIR/last_case.json" "$RESULTS_DIR/last_run.json"
env_set '.demo_executed = false'
log "Reset complete"
