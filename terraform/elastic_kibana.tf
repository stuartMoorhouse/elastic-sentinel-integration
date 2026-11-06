locals {
  kibana_url = ec_deployment.main.kibana.https_endpoint

  case_cfg = jsondecode(templatefile("${path.module}/../config/kibana/webhook-case-connector.json", {
    logicapp_upsert_url = azurerm_logic_app_trigger_http_request.upsert.callback_url
    logicapp_get_url    = azurerm_logic_app_trigger_http_request.get.callback_url
    subscription_id     = var.subscription_id
    resource_group      = azurerm_resource_group.main.name
    workspace_name      = azurerm_log_analytics_workspace.main.name
  }))

  eventhub_cfg = jsondecode(templatefile("${path.module}/../config/fleet/azure-eventhub-input.json", {
    eventhub            = azurerm_eventhub.sentinel.name
    consumer_group      = azurerm_eventhub_consumer_group.elastic.name
    connection_string   = azurerm_eventhub_authorization_rule.listen.primary_connection_string
    storage_account     = azurerm_storage_account.checkpoints.name
    storage_account_key = azurerm_storage_account.checkpoints.primary_access_key
  }))

  rule_cfg = jsondecode(file("${path.module}/../config/kibana/rule-ssh-enumeration.json"))

  json_headers = { "Content-Type" = "application/json" }
}

# ---- Scenario 1: case management webhook connector -> Logic App ----
resource "elasticstack_kibana_action_connector" "case" {
  name              = "Sentinel incidents (cases webhook)"
  connector_type_id = ".cases-webhook"

  config = jsonencode({
    createIncidentJson                  = local.case_cfg.create_incident_json
    createIncidentMethod                = "post"
    createIncidentResponseKey           = local.case_cfg.create_incident_response_key
    createIncidentUrl                   = local.case_cfg.create_incident_url
    getIncidentResponseExternalTitleKey = local.case_cfg.get_incident_response_external_title_key
    getIncidentUrl                      = local.case_cfg.get_incident_url_template
    updateIncidentJson                  = local.case_cfg.update_incident_json
    updateIncidentMethod                = "post"
    updateIncidentUrl                   = local.case_cfg.update_incident_url
    createCommentJson                   = local.case_cfg.create_comment_json
    createCommentMethod                 = "post"
    createCommentUrl                    = local.case_cfg.create_comment_url
    viewIncidentUrl                     = local.case_cfg.view_incident_url_template
    hasAuth                             = false
    headers                             = local.json_headers
  })

  # No credentials: the Logic App SAS signature is part of the URL.
  secrets = jsonencode({})
}

# ---- Scenario 2: alert webhook connector -> Logic App ----
resource "elasticstack_kibana_action_connector" "alert" {
  name              = "Sentinel alerts (webhook)"
  connector_type_id = ".webhook"

  config = jsonencode({
    method  = "post"
    url     = azurerm_logic_app_trigger_http_request.alert.callback_url
    hasAuth = false
    headers = local.json_headers
  })

  secrets = jsonencode({})
}

# ---- Fleet: agent policy with System + Azure Event Hub integrations ----
# Package versions are pinned (variables) because a data source would need Kibana
# at plan time, before the Elastic Cloud deployment exists. The azure package is
# policy template "eventhub" with data stream azure.eventhub.
resource "elasticstack_fleet_integration" "system" {
  name    = "system"
  version = var.fleet_system_package_version
}

resource "elasticstack_fleet_integration" "azure" {
  name    = "azure"
  version = var.fleet_azure_package_version
}

resource "elasticstack_fleet_agent_policy" "vm" {
  name            = "sentinel-demo-vm"
  namespace       = "default"
  description     = "Linux VM: System logs and Sentinel export via Azure Event Hub"
  monitor_logs    = true
  monitor_metrics = false
  sys_monitoring  = false
  skip_destroy    = false
}

resource "elasticstack_fleet_integration_policy" "system" {
  name                = "system-vm"
  namespace           = "default"
  agent_policy_id     = elasticstack_fleet_agent_policy.vm.policy_id
  integration_name    = elasticstack_fleet_integration.system.name
  integration_version = elasticstack_fleet_integration.system.version
}

locals {
  azure_other_inputs = ["events", "adlogs", "platformlogs", "activitylogs", "graphactivitylogs", "springcloudlogs", "firewall_logs", "application_gateway"]
}

resource "elasticstack_fleet_integration_policy" "azure_eventhub" {
  name                = "azure-eventhub-sentinel"
  namespace           = "default"
  agent_policy_id     = elasticstack_fleet_agent_policy.vm.policy_id
  integration_name    = elasticstack_fleet_integration.azure.name
  integration_version = elasticstack_fleet_integration.azure.version

  # Package-level vars (shared by all azure inputs)
  vars_json = jsonencode({
    for k in ["eventhub", "consumer_group", "connection_string", "storage_account", "storage_account_key"] :
    k => local.eventhub_cfg.vars[k]
  })

  # Enable only the generic Event Hub input; disable the other azure inputs.
  inputs = merge(
    {
      "eventhub-azure-eventhub" = {
        enabled = true
        streams = {
          "azure.eventhub" = {
            enabled = true
            vars = jsonencode({
              "data_stream.dataset" = local.eventhub_cfg.vars["data_stream.dataset"]
              parse_message         = true
            })
          }
        }
      }
    },
    { for i in local.azure_other_inputs : "${i}-azure-eventhub" => { enabled = false } }
  )
}

data "elasticstack_fleet_enrollment_tokens" "vm" {
  policy_id  = elasticstack_fleet_agent_policy.vm.policy_id
  depends_on = [elasticstack_fleet_agent_policy.vm]
}

# ---- Detection rule: SSH user enumeration (threshold), webhook action ----
moved {
  from = elasticstack_kibana_security_detection_rule.malware
  to   = elasticstack_kibana_security_detection_rule.ssh_enumeration
}

resource "elasticstack_kibana_security_detection_rule" "ssh_enumeration" {
  name            = local.rule_cfg.name
  description     = local.rule_cfg.description
  type            = local.rule_cfg.type
  language        = local.rule_cfg.language
  query           = local.rule_cfg.query
  index           = local.rule_cfg.index
  interval        = local.rule_cfg.interval
  from            = local.rule_cfg.from
  severity        = local.rule_cfg.severity
  risk_score      = local.rule_cfg.risk_score
  enabled         = local.rule_cfg.enabled
  tags            = local.rule_cfg.tags
  references      = local.rule_cfg.references
  false_positives = local.rule_cfg.false_positives
  note            = local.rule_cfg.note

  threshold = {
    field       = local.rule_cfg.threshold.field
    value       = local.rule_cfg.threshold.value
    cardinality = local.rule_cfg.threshold.cardinality
  }

  threat = local.rule_cfg.threat

  actions = [{
    action_type_id = ".webhook"
    id             = elasticstack_kibana_action_connector.alert.connector_id
    group          = "default"
    params = jsonencode({
      body = file("${path.module}/../config/kibana/rule-action-body.json")
    })
    frequency = {
      notify_when = "onActiveAlert"
      summary     = false
      throttle    = "no_actions"
    }
  }]
}
