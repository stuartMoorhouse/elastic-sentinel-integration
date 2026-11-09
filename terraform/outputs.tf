output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "subscription_id" {
  value = var.subscription_id
}

output "vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "ssh_private_key_path" {
  value = abspath(local_sensitive_file.vm_private_key.filename)
}

output "elasticsearch_url" {
  value = ec_deployment.main.elasticsearch.https_endpoint
}

output "kibana_url" {
  value = ec_deployment.main.kibana.https_endpoint
}

# Fleet Server (integrations server) URL used by agents to enroll. The Fleet API
# itself is served by kibana_url.
output "fleet_url" {
  value = ec_deployment.main.integrations_server.endpoints.fleet
}

output "elastic_username" {
  value = ec_deployment.main.elasticsearch_username
}

output "elastic_password" {
  value     = ec_deployment.main.elasticsearch_password
  sensitive = true
}

output "log_analytics_workspace_id" {
  description = "Workspace customer (GUID) id"
  value       = azurerm_log_analytics_workspace.main.workspace_id
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.main.name
}

output "sentinel_alert_logicapp_name" {
  value = azurerm_logic_app_workflow.alert.name
}

output "sentinel_incident_logicapp_name" {
  value = azurerm_logic_app_workflow.incident_upsert.name
}

output "sentinel_get_incident_logicapp_name" {
  value = azurerm_logic_app_workflow.incident_get.name
}

output "sentinel_to_elastic_logicapp_name" {
  value = azapi_resource.sentinel_to_elastic.name
}

output "sentinel_incident_rule_name" {
  value = elasticstack_kibana_security_detection_rule.sentinel_incident.name
}

output "event_hub_namespace" {
  value = azurerm_eventhub_namespace.main.name
}

output "event_hub_name" {
  value = azurerm_eventhub.sentinel.name
}

output "kibana_case_connector_id" {
  value = elasticstack_kibana_action_connector.case.connector_id
}

output "kibana_alert_connector_id" {
  value = elasticstack_kibana_action_connector.alert.connector_id
}

output "detection_rule_name" {
  value = elasticstack_kibana_security_detection_rule.ssh_enumeration.name
}

output "logicapp_upsert_callback_url" {
  value     = azurerm_logic_app_trigger_http_request.upsert.callback_url
  sensitive = true
}

output "logicapp_get_callback_url" {
  value     = azurerm_logic_app_trigger_http_request.get.callback_url
  sensitive = true
}

output "logicapp_alert_callback_url" {
  value     = azurerm_logic_app_trigger_http_request.alert.callback_url
  sensitive = true
}
