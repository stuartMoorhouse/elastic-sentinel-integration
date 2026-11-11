#!/usr/bin/env bash
# Seed example "accepted customer behaviour" cases so tag search and filtering have
# something to find in use case 6. Idempotent: a case is created only if no case with
# the same title and the accepted-behaviour tag exists. Cases are not pushed to Sentinel
# (connector "none"). Run after scripts/reset-demo.sh, which deletes all cases.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds jq curl terraform
load_outputs

TAG="accepted-behaviour"

# TITLE|CUSTOMER_TAG|SEVERITY|DESCRIPTION
SEEDS=(
  'Accepted: nightly vulnerability scan from 10.0.4.0/24|customer:contoso|low|## Behaviour\nThe security team at Contoso runs an authenticated scan every night at 02:00 UTC from 10.0.4.0/24. It produces many failed SSH logins for invalid users.\n\n## Decision\nAccepted. Close SSH enumeration alerts from this range.\n\n## Review\nRe-confirm with the customer each quarter.'
  'Accepted: admin jump host uses root SSH logins|customer:fabrikam|low|## Behaviour\nFabrikam administrators log in as root from the jump host 10.0.9.5 during maintenance windows.\n\n## Decision\nAccepted for 10.0.9.5 only.\n\n## Review\nRevisit if the jump host changes.'
  'Accepted: monitoring probe generates failed logins|customer:contoso|low|## Behaviour\nA legacy monitoring probe uses a stale service account and fails authentication every 5 minutes.\n\n## Decision\nAccepted until the probe is retired.'
)

existing="$(kibana_curl GET "/api/cases/_find?perPage=100&tags=$TAG" | jq -r '.cases[].title')"

for seed in "${SEEDS[@]}"; do
  IFS='|' read -r title customer severity desc <<<"$seed"
  if grep -Fxq -- "$title" <<<"$existing"; then
    log "Exists: $title"
    continue
  fi
  body="$(jq -n --arg t "$title" --arg c "$customer" --arg s "$severity" --arg tag "$TAG" --arg d "$(printf '%b' "$desc")" '{
    owner: "securitySolution", title: $t, description: $d, severity: $s,
    tags: [$tag, $c], assignees: [],
    settings: {syncAlerts: false},
    connector: {id: "none", name: "none", type: ".none", fields: null}
  }')"
  kibana_curl POST /api/cases "$body" | jq -r '"Created: \(.title) (\(.id))"'
done

log "Search tag '$TAG' in Kibana: Security, Cases"
