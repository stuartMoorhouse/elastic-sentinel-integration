# Non-secret handoff for scripts. Secrets are read with `terraform output -raw`.
resource "local_file" "shared_env" {
  filename        = "${path.module}/../shared/env.json"
  file_permission = "0644"
  content = jsonencode({
    elasticsearch_url   = ec_deployment.main.elasticsearch.https_endpoint
    kibana_url          = ec_deployment.main.kibana.https_endpoint
    fleet_url           = ec_deployment.main.integrations_server.endpoints.fleet
    resource_group_name = azurerm_resource_group.main.name
    location            = azurerm_resource_group.main.location
    vm_public_ip        = azurerm_public_ip.vm.ip_address
    workspace_name      = azurerm_log_analytics_workspace.main.name
    event_hub_namespace = azurerm_eventhub_namespace.main.name
    event_hub_name      = azurerm_eventhub.sentinel.name
    infra_ready         = true
    config_ready        = true
    demo_executed       = false
  })

  depends_on = [
    azurerm_linux_virtual_machine.main,
    azurerm_monitor_data_collection_rule_association.syslog,
    azurerm_sentinel_alert_rule_nrt.elastic_alerts,
    azurerm_log_analytics_data_export_rule.to_eventhub,
    azurerm_role_assignment.upsert_sentinel,
    azurerm_role_assignment.get_sentinel,
    azurerm_logic_app_action_custom.upsert_route,
    azurerm_logic_app_action_custom.get_response,
    azurerm_logic_app_action_custom.alert_response,
    elasticstack_kibana_security_detection_rule.malware,
    elasticstack_fleet_integration_policy.azure_eventhub,
    elasticstack_fleet_integration_policy.system,
  ]
}
