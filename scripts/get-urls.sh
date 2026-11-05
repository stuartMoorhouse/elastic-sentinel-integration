#!/usr/bin/env bash
# Print access URLs. No secrets are printed.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_outputs
portal="https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers"

cat <<URLS
Kibana:         $KIBANA_URL
Elasticsearch:  $ES_URL
Fleet:          $FLEET_URL
Username:       $ELASTIC_USER
Password:       terraform -chdir=terraform output -raw elastic_password

SSH:            ssh -i $SSH_KEY azureuser@$VM_IP

Azure portal:
  Resource group:  https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/overview
  Sentinel:        $portal/Microsoft.OperationalInsights/workspaces/$WORKSPACE_NAME/overview
  Sentinel incidents: https://portal.azure.com/#view/Microsoft_Azure_Security_Insights/MainMenuBlade/~/Incidents/id/%2Fsubscriptions%2F$SUBSCRIPTION_ID%2FresourceGroups%2F$RESOURCE_GROUP%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2F$WORKSPACE_NAME
  Logic App (alert):         $portal/Microsoft.Logic/workflows/$LA_ALERT/logicApp
  Logic App (incident):      $portal/Microsoft.Logic/workflows/$LA_INCIDENT/logicApp
  Logic App (get incident):  $portal/Microsoft.Logic/workflows/$LA_GET_INCIDENT/logicApp
  Event Hub namespace:       $portal/Microsoft.EventHub/namespaces/$EH_NAMESPACE/overview
URLS
