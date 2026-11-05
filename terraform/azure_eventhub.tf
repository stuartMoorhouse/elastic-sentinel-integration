resource "azurerm_eventhub_namespace" "main" {
  name                = "${var.prefix}-ehns-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.event_hub_sku
  capacity            = 1
  minimum_tls_version = "1.2"
  tags                = local.tags
}

resource "azurerm_eventhub" "sentinel" {
  name              = "sentinel-logs"
  namespace_id      = azurerm_eventhub_namespace.main.id
  partition_count   = 2
  message_retention = 1
}

resource "azurerm_eventhub_consumer_group" "elastic" {
  name                = "elastic"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.sentinel.name
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_eventhub_authorization_rule" "listen" {
  name                = "elastic-listen"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.sentinel.name
  resource_group_name = azurerm_resource_group.main.name
  listen              = true
  send                = false
  manage              = false
}

# Checkpoint store for the Elastic Agent Azure Event Hub input.
resource "azurerm_storage_account" "checkpoints" {
  #checkov:skip=CKV_AZURE_59:Elastic Agent on the VM reaches the account over the public endpoint; demo only
  #checkov:skip=CKV_AZURE_33:Queue logging not applicable, account only holds blob checkpoints
  #checkov:skip=CKV2_AZURE_1:Platform-managed keys are sufficient for demo checkpoint blobs
  #checkov:skip=CKV2_AZURE_33:No private endpoint in this demo
  #checkov:skip=CKV2_AZURE_40:Elastic Agent authenticates with the account key (required by the input)
  #checkov:skip=CKV2_AZURE_21:Blob logging not needed for demo checkpoints
  #checkov:skip=CKV_AZURE_206:LRS is enough for demo checkpoints
  #checkov:skip=CKV_AZURE_190:Blob access restricted by key and no public containers
  #checkov:skip=CKV_AZURE_35:Elastic Agent running outside the VNet needs the public endpoint
  #checkov:skip=CKV2_AZURE_38:Soft delete not needed for demo checkpoints
  #checkov:skip=CKV2_AZURE_41:SAS expiration policy not applicable, account key is used
  name                            = "elsent${local.suffix}"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
  tags                            = local.tags
}

# Scenario 3: export Sentinel (Log Analytics) tables to the event hub.
resource "azurerm_log_analytics_data_export_rule" "to_eventhub" {
  name                    = "sentinel-to-eventhub"
  resource_group_name     = azurerm_resource_group.main.name
  workspace_resource_id   = azurerm_log_analytics_workspace.main.id
  destination_resource_id = azurerm_eventhub.sentinel.id
  table_names             = var.export_table_names
  enabled                 = true

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.main]
}
