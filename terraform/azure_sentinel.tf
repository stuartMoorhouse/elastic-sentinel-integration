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

# Azure Activity is not collected: the subscription is at the limit of 5 subscription-level
# diagnostic settings (all used by other teams), so a sixth cannot be created.

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
