resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.prefix}-law-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.tags
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "main" {
  workspace_id = azurerm_log_analytics_workspace.main.id
}

# Azure Activity connector: subscription-level diagnostic setting into the workspace.
resource "azurerm_monitor_diagnostic_setting" "activity" {
  name                       = "${var.prefix}-activity-to-law"
  target_resource_id         = "/subscriptions/${var.subscription_id}"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  dynamic "enabled_log" {
    for_each = ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"]
    content {
      category = enabled_log.value
    }
  }
}

# --- Syslog from the VM via Azure Monitor Agent ---
resource "azurerm_monitor_data_collection_rule" "syslog" {
  name                = "${var.prefix}-syslog-dcr"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  kind                = "Linux"
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "law"
      workspace_resource_id = azurerm_log_analytics_workspace.main.id
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["law"]
  }

  data_sources {
    syslog {
      name           = "syslog"
      streams        = ["Microsoft-Syslog"]
      facility_names = ["auth", "authpriv", "daemon", "syslog", "user"]
      log_levels     = ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}

resource "azurerm_monitor_data_collection_rule_association" "syslog" {
  name                    = "${var.prefix}-syslog-dcra"
  target_resource_id      = azurerm_linux_virtual_machine.main.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.syslog.id

  depends_on = [azurerm_virtual_machine_extension.ama]
}

# --- Custom table + Logs Ingestion API for Elastic alerts (Scenario 2) ---
resource "azapi_resource" "elastic_alerts_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "ElasticAlerts_CL"
  parent_id = azurerm_log_analytics_workspace.main.id

  body = {
    properties = {
      schema = {
        name = "ElasticAlerts_CL"
        columns = [
          { name = "TimeGenerated", type = "datetime" },
          { name = "rule_name_s", type = "string" },
          { name = "rule_id_s", type = "string" },
          { name = "severity_s", type = "string" },
          { name = "risk_score_s", type = "string" },
          { name = "reason_s", type = "string" },
          { name = "host_name_s", type = "string" },
          { name = "message_s", type = "string" },
          { name = "alert_id_s", type = "string" },
          { name = "kibana_alert_url_s", type = "string" },
          { name = "timestamp_s", type = "string" },
        ]
      }
      retentionInDays      = var.log_analytics_retention_days
      totalRetentionInDays = var.log_analytics_retention_days
    }
  }
}

resource "azurerm_monitor_data_collection_endpoint" "alerts" {
  name                          = "${var.prefix}-dce"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  kind                          = "Linux"
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_monitor_data_collection_rule" "alerts" {
  name                        = "${var.prefix}-elasticalerts-dcr"
  location                    = azurerm_resource_group.main.location
  resource_group_name         = azurerm_resource_group.main.name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.alerts.id
  tags                        = local.tags

  destinations {
    log_analytics {
      name                  = "law"
      workspace_resource_id = azurerm_log_analytics_workspace.main.id
    }
  }

  stream_declaration {
    stream_name = "Custom-ElasticAlerts_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    dynamic "column" {
      for_each = ["rule_name_s", "rule_id_s", "severity_s", "risk_score_s", "reason_s", "host_name_s", "message_s", "alert_id_s", "kibana_alert_url_s", "timestamp_s"]
      content {
        name = column.value
        type = "string"
      }
    }
  }

  data_flow {
    streams       = ["Custom-ElasticAlerts_CL"]
    destinations  = ["law"]
    transform_kql = "source"
    output_stream = "Custom-ElasticAlerts_CL"
  }

  depends_on = [azapi_resource.elastic_alerts_table]
}

# --- Scenario 2: NRT rule that raises incidents from Elastic alerts ---
resource "azurerm_sentinel_alert_rule_nrt" "elastic_alerts" {
  name                       = "elastic-alerts-nrt"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.main.workspace_id
  display_name               = "Elastic Security alert received"
  description                = "Raises a Sentinel incident for each alert pushed from Elastic Security into ElasticAlerts_CL."
  severity                   = "Medium"
  enabled                    = true
  query                      = file("${path.module}/../config/sentinel/nrt-query.kql")

  event_grouping {
    aggregation_method = "SingleAlert"
  }

  incident {
    create_incident_enabled = true
    grouping {
      enabled = false
    }
  }

  depends_on = [azapi_resource.elastic_alerts_table]
}
