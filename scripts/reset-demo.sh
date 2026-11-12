#!/usr/bin/env bash
# Complete refresh of the demo data. Keeps all infrastructure, connectors, rules, case
# templates and the workflow. Intended for this demo deployment only.
#
# Clears:
#   Elastic: all cases, all security alerts, analyst Timelines and Timeline templates (the
#            prebuilt Elastic templates are kept), all notes, rule-default exceptions, the exported
#            Sentinel incident rows (logs-azure.eventhub-*), and the demo index.
#   Sentinel: all incidents in the workspace.
# Then re-seeds the example accepted-behaviour cases (scripts/seed-cases.sh).
#
# Usage: scripts/reset-demo.sh [--yes] [--incident]
#   --yes       do not prompt
#   --incident  afterwards create a fresh Sentinel incident and wait for its Elastic alert
#               (scripts/create-sentinel-incident.sh --wait)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=0
INCIDENT=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --incident) INCIDENT=1 ;;
    *) die "Unknown option: $arg (use --yes, --incident)" ;;
  esac
done

require_cmds az jq curl terraform
load_outputs
az_preflight

echo "This will delete EVERYTHING of these kinds in this deployment:"
echo "  - ALL Kibana cases"
echo "  - ALL security alerts in .alerts-security.alerts-default"
echo "  - ALL analyst Timelines and Timeline templates (prebuilt Elastic templates are kept), and ALL notes"
echo "  - Rule-default exceptions on the detection rules"
echo "  - Exported Sentinel incident rows in logs-azure.eventhub-*"
echo "  - Elasticsearch data stream/index $DEMO_INDEX"
echo "  - ALL Sentinel incidents in workspace $WORKSPACE_NAME"
echo "Then the example accepted-behaviour cases are created again."
if (( ! YES )); then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log "Aborted"; exit 0; }
fi

# ---- Cases: all of them, any owner. Re-query until none are left (page size is capped). ----
for _ in $(seq 1 20); do
  ids="$(kibana_curl GET "/api/cases/_find?perPage=100" | jq -c '[.cases[].id]')"
  [[ "$ids" != "[]" ]] || break
  log "Deleting $(jq length <<<"$ids") case(s)"
  kibana_curl DELETE "/api/cases?ids=$(jq -rn --arg v "$ids" '$v|@uri')" >/dev/null || { warn "case deletion failed"; break; }
done
log "Cases remaining: $(kibana_curl GET "/api/cases/_find?perPage=1" | jq -r '.total')"

# ---- Notes: all of them (they hang off Timelines, alerts and events). ----
for _ in $(seq 1 20); do
  note_ids="$(kibana_curl GET "/api/note?perPage=100" | jq -c '[.notes[]?.noteId]')"
  [[ "$note_ids" != "[]" ]] || break
  log "Deleting $(jq length <<<"$note_ids") note(s)"
  kibana_curl DELETE /api/note "$(jq -c '{noteIds: .}' <<<"$note_ids")" >/dev/null || { warn "note deletion failed"; break; }
done
log "Notes remaining: $(kibana_curl GET "/api/note?perPage=1" | jq -r '.totalCount')"

# ---- Timelines and Timeline templates created by analysts. Prebuilt ones have status "immutable". ----
for _ in $(seq 1 20); do
  tl_ids="$(kibana_curl GET "/api/timelines?page_size=100&page_index=1" \
    | jq -c '[.timeline[]? | select(.status != "immutable") | .savedObjectId]')"
  [[ "$tl_ids" != "[]" ]] || break
  log "Deleting $(jq length <<<"$tl_ids") Timeline(s) and template(s)"
  kibana_curl DELETE /api/timeline "$(jq -c '{savedObjectIds: .}' <<<"$tl_ids")" >/dev/null || { warn "timeline deletion failed"; break; }
done
log "Timelines remaining (prebuilt templates are kept): $(kibana_curl GET "/api/timelines?page_size=1&page_index=1" | jq -r '.totalCount')"

# ---- Rule-default exceptions: the exception items analysts added from alerts. ----
# The rules keep their (now empty) rule-default exception list; only the items are removed.
removed=0
while IFS= read -r list_id; do
  [[ -n "$list_id" ]] || continue
  for item_id in $(kibana_curl GET "/api/exception_lists/items/_find?list_id=$list_id&namespace_type=single&per_page=100" | jq -r '.data[]?.id'); do
    kibana_curl DELETE "/api/exception_lists/items?id=$item_id&namespace_type=single" >/dev/null && removed=$((removed + 1))
  done
done < <(kibana_curl GET "/api/detection_engine/rules/_find?per_page=100" \
  | jq -r '.data[]?.exceptions_list[]? | select(.type == "rule_default") | .list_id')
log "Rule exception items removed: $removed"

# ---- Elasticsearch data ----
if es_curl DELETE "/_data_stream/$DEMO_INDEX" >/dev/null 2>&1; then log "Deleted data stream $DEMO_INDEX"
elif es_curl DELETE "/$DEMO_INDEX" >/dev/null 2>&1; then log "Deleted index $DEMO_INDEX"
else log "$DEMO_INDEX not present"; fi

# Exported Sentinel incident rows. Deleted before the alerts so the "Sentinel Incident Raised" rule
# (which looks back 15 minutes) cannot raise the same alerts again from rows it has already seen.
es_curl POST '/logs-azure.eventhub-*/_delete_by_query?refresh=true&conflicts=proceed&ignore_unavailable=true' \
  '{"query":{"match_phrase":{"azure.eventhub.Type":"SecurityIncident"}}}' \
  | jq -c '{exported_incident_rows_deleted: .deleted, failures: (.failures | length)}' || warn "exported row deletion failed"

# Delete every security alert, not only the current rule's.
q='{"query":{"match_all":{}}}'
es_curl POST '/.alerts-security.alerts-default/_delete_by_query?refresh=true&conflicts=proceed&ignore_unavailable=true' "$q" \
  | jq -c '{alerts_deleted: .deleted, failures: (.failures | length)}' || warn "alert deletion failed"

# ---- Sentinel incidents: all of them. Re-query the first page until none are left. ----
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

# ---- Fresh start: example cases, and optionally a new Sentinel incident ----
log "Re-seeding the example accepted-behaviour cases"
"$SCRIPT_DIR/seed-cases.sh"
if (( INCIDENT )); then
  log "Creating a fresh Sentinel incident and waiting for its Elastic alert"
  "$SCRIPT_DIR/create-sentinel-incident.sh" --wait
fi

log "Reset complete"
cat <<EOF2

Next, for the main demo (see docs/runbook.md):
  scripts/run_demo.sh                          failed SSH logins for the Timeline investigation
  scripts/create-sentinel-incident.sh --wait   a Sentinel incident and its Elastic alert (skip if you passed --incident)
EOF2
