# ---- Elastic to Sentinel alert status sync (runbook use case 7) ----
# An Elastic Workflow polls for alerts an analyst acknowledged or closed and sets the matching
# Sentinel incident to Active or Closed, so the analyst does not have to do it in the other portal.
# Elastic calls the Azure Resource Manager API, so it needs its own Entra identity: an app
# registration with a client secret, limited to Microsoft Sentinel Responder on the workspace.
#
# The client secret is held only in a Kibana HTTP connector (encrypted by Kibana, never returned by
# its API, marked sensitive in Terraform), not in the workflow definition. Kibana fetches and
# refreshes the OAuth token itself. The secret is also in Terraform state, as any managed secret
# is, and expires after 90 days (to rotate: run apply with -replace on the
# azuread_application_password.elastic_workflows resource).
resource "azuread_application" "elastic_workflows" {
  display_name = "${var.prefix}-elastic-workflows"
}

resource "azuread_service_principal" "elastic_workflows" {
  client_id = azuread_application.elastic_workflows.client_id
}

resource "azuread_application_password" "elastic_workflows" {
  application_id    = azuread_application.elastic_workflows.id
  display_name      = "elastic-workflow"
  end_date_relative = "2160h"
}

resource "azurerm_role_assignment" "elastic_workflows_sentinel" {
  scope                = azurerm_log_analytics_workspace.main.id
  role_definition_name = "Microsoft Sentinel Responder"
  principal_id         = azuread_service_principal.elastic_workflows.object_id
  # The principal was just created; skip the directory replication check.
  skip_service_principal_aad_check = true
}

# HTTP connector the workflow uses to call the Azure Resource Manager API as the Entra app
# (OAuth 2.0 client credentials). Workflow http steps reference it by id.
resource "elasticstack_kibana_action_connector" "azure_arm" {
  name              = "Azure Resource Manager (Sentinel workflow)"
  connector_type_id = ".http"

  config = jsonencode({
    url      = "https://management.azure.com"
    authType = "webhook-oauth2-client-credentials"
    # Kibana adds these defaults to the stored config. State them, or the provider reports
    # "inconsistent result after apply" because the planned config lacks them.
    hasAuth        = true
    hasProxyAuth   = false
    accessTokenUrl = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/token"
    clientId       = azuread_application.elastic_workflows.client_id
    scope          = "https://management.azure.com/.default"
  })

  secrets = jsonencode({
    clientSecret = azuread_application_password.elastic_workflows.value
  })

  depends_on = [azurerm_role_assignment.elastic_workflows_sentinel]
}

# No fixed workflow_id: Kibana keeps the ids of deleted workflows reserved, so a fixed id fails with
# HTTP 409 ("already exists") after any delete or destroy and re-apply. The workflow is found by its
# name, sentinel-alert-status-sync, in Kibana under Workflows.
resource "elasticstack_kibana_agentbuilder_workflow" "sentinel_alert_status_sync" {
  configuration_yaml = templatefile("${path.module}/../config/kibana/workflows/sentinel-alert-status-sync.yaml.tftpl", {
    connector_id    = elasticstack_kibana_action_connector.azure_arm.connector_id
    incidents_url   = "https://management.azure.com${azurerm_log_analytics_workspace.main.id}/providers/Microsoft.SecurityInsights/incidents"
    rule_names_json = jsonencode([local.rule_cfg.name, local.sentinel_rule_cfg.name])
  })

  depends_on = [elasticstack_kibana_action_connector.azure_arm]
}
