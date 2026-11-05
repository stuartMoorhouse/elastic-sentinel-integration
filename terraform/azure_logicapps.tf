locals {
  sentinel_api_version = "2023-02-01"
  incident_base_url    = "https://management.azure.com${azurerm_log_analytics_workspace.main.id}/providers/Microsoft.SecurityInsights/incidents"
  arm_auth = {
    type     = "ManagedServiceIdentity"
    audience = "https://management.azure.com/"
  }
  trigger_schema_upsert = file("${path.module}/../config/logicapps/incident-upsert.schema.json")
  trigger_schema_get    = file("${path.module}/../config/logicapps/incident-get.schema.json")
  trigger_schema_alert  = file("${path.module}/../config/logicapps/elastic-alert.schema.json")

  # Elastic severity (low/medium/high/critical) -> Sentinel (Informational/Low/Medium/High)
  severity_expr = "@if(equals(triggerBody()?['severity'],'critical'),'High',if(equals(triggerBody()?['severity'],'high'),'High',if(equals(triggerBody()?['severity'],'medium'),'Medium',if(equals(triggerBody()?['severity'],'low'),'Low','Informational'))))"
  # Elastic status (open/in-progress/closed) -> Sentinel (New/Active/Closed)
  status_expr = "@if(equals(triggerBody()?['status'],'closed'),'Closed',if(equals(triggerBody()?['status'],'in-progress'),'Active','New'))"
}

resource "azurerm_logic_app_workflow" "incident_upsert" {
  name                = "${var.prefix}-elastic-upsert-incident"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_logic_app_workflow" "incident_get" {
  name                = "${var.prefix}-elastic-get-incident"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_logic_app_workflow" "alert" {
  name                = "${var.prefix}-elastic-alert-to-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# --- Role assignments (no OAuth authorize step needed) ---
resource "azurerm_role_assignment" "upsert_sentinel" {
  scope                = azurerm_log_analytics_workspace.main.id
  role_definition_name = "Microsoft Sentinel Responder"
  principal_id         = azurerm_logic_app_workflow.incident_upsert.identity[0].principal_id
}

resource "azurerm_role_assignment" "get_sentinel" {
  scope                = azurerm_log_analytics_workspace.main.id
  role_definition_name = "Microsoft Sentinel Reader"
  principal_id         = azurerm_logic_app_workflow.incident_get.identity[0].principal_id
}

resource "azurerm_role_assignment" "alert_dcr" {
  scope                = azurerm_monitor_data_collection_rule.alerts.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_logic_app_workflow.alert.identity[0].principal_id
}

# ============ (a) create / update / comment incident ============
resource "azurerm_logic_app_trigger_http_request" "upsert" {
  name         = "request"
  logic_app_id = azurerm_logic_app_workflow.incident_upsert.id
  method       = "POST"
  schema       = local.trigger_schema_upsert
}

resource "azurerm_logic_app_action_custom" "upsert_id" {
  name         = "Incident_Id"
  logic_app_id = azurerm_logic_app_workflow.incident_upsert.id
  body = jsonencode({
    type     = "Compose"
    inputs   = "@if(equals(triggerBody()?['action'],'create'),guid(),coalesce(triggerBody()?['sentinel_incident_id'],''))"
    runAfter = {}
  })
  depends_on = [azurerm_logic_app_trigger_http_request.upsert]
}

resource "azurerm_logic_app_action_custom" "upsert_labels" {
  name         = "Labels"
  logic_app_id = azurerm_logic_app_workflow.incident_upsert.id
  body = jsonencode({
    type = "Select"
    inputs = {
      from   = "@coalesce(triggerBody()?['tags'],json('[]'))"
      select = { labelName = "@string(item())" }
    }
    runAfter = { Incident_Id = ["Succeeded"] }
  })
  depends_on = [azurerm_logic_app_action_custom.upsert_id]
}

resource "azurerm_logic_app_action_custom" "upsert_props" {
  name         = "Props"
  logic_app_id = azurerm_logic_app_workflow.incident_upsert.id
  body = jsonencode({
    type = "Compose"
    inputs = {
      title       = "@coalesce(triggerBody()?['title'],'Elastic case')"
      description = "@concat(coalesce(triggerBody()?['description'],''),' (Elastic Security case ',coalesce(triggerBody()?['kibana_case_id'],'n/a'),')')"
      severity    = local.severity_expr
      status      = local.status_expr
      labels      = "@body('Labels')"
    }
    runAfter = { Labels = ["Succeeded"] }
  })
  depends_on = [azurerm_logic_app_action_custom.upsert_labels]
}

resource "azurerm_logic_app_action_custom" "upsert_route" {
  name         = "Route"
  logic_app_id = azurerm_logic_app_workflow.incident_upsert.id
  body = jsonencode({
    type       = "Switch"
    expression = "@triggerBody()?['action']"
    cases = {
      create = {
        case = "create"
        actions = {
          Create_Incident = {
            type = "Http"
            inputs = {
              method         = "PUT"
              uri            = "${local.incident_base_url}/@{outputs('Incident_Id')}?api-version=${local.sentinel_api_version}"
              headers        = { "Content-Type" = "application/json" }
              body           = { properties = "@outputs('Props')" }
              authentication = local.arm_auth
            }
            runAfter = {}
          }
          Respond_Created = {
            type = "Response"
            inputs = {
              statusCode = 200
              headers    = { "Content-Type" = "application/json" }
              body       = { sentinel_incident_id = "@{outputs('Incident_Id')}" }
            }
            runAfter = { Create_Incident = ["Succeeded"] }
          }
        }
      }
      update = {
        case = "update"
        actions = {
          Update_Incident = {
            type = "Http"
            inputs = {
              method  = "PUT"
              uri     = "${local.incident_base_url}/@{outputs('Incident_Id')}?api-version=${local.sentinel_api_version}"
              headers = { "Content-Type" = "application/json" }
              # Sentinel requires a classification when an incident is closed.
              body = {
                properties = "@if(equals(outputs('Props')?['status'],'Closed'),addProperty(outputs('Props'),'classification','Undetermined'),outputs('Props'))"
              }
              authentication = local.arm_auth
            }
            runAfter = {}
          }
          Respond_Updated = {
            type = "Response"
            inputs = {
              statusCode = 200
              headers    = { "Content-Type" = "application/json" }
              body       = { sentinel_incident_id = "@{outputs('Incident_Id')}" }
            }
            runAfter = { Update_Incident = ["Succeeded"] }
          }
        }
      }
      comment = {
        case = "comment"
        actions = {
          Add_Comment = {
            type = "Http"
            inputs = {
              method         = "PUT"
              uri            = "${local.incident_base_url}/@{outputs('Incident_Id')}/comments/@{guid()}?api-version=${local.sentinel_api_version}"
              headers        = { "Content-Type" = "application/json" }
              body           = { properties = { message = "@{coalesce(triggerBody()?['comment'],'')}" } }
              authentication = local.arm_auth
            }
            runAfter = {}
          }
          Respond_Commented = {
            type = "Response"
            inputs = {
              statusCode = 200
              headers    = { "Content-Type" = "application/json" }
              body       = { sentinel_incident_id = "@{outputs('Incident_Id')}" }
            }
            runAfter = { Add_Comment = ["Succeeded"] }
          }
        }
      }
    }
    default = {
      actions = {
        Respond_Bad_Request = {
          type = "Response"
          inputs = {
            statusCode = 400
            body       = { error = "unsupported action" }
          }
          runAfter = {}
        }
      }
    }
    runAfter = { Props = ["Succeeded"] }
  })
  depends_on = [azurerm_logic_app_action_custom.upsert_props]
}

# ============ (b) get incident ============
resource "azurerm_logic_app_trigger_http_request" "get" {
  name         = "request"
  logic_app_id = azurerm_logic_app_workflow.incident_get.id
  method       = "GET"
  schema       = local.trigger_schema_get
}

resource "azurerm_logic_app_action_custom" "get_incident" {
  name         = "Get_Incident"
  logic_app_id = azurerm_logic_app_workflow.incident_get.id
  body = jsonencode({
    type = "Http"
    inputs = {
      method         = "GET"
      uri            = "${local.incident_base_url}/@{triggerOutputs()['queries']['sentinel_incident_id']}?api-version=${local.sentinel_api_version}"
      authentication = local.arm_auth
    }
    runAfter = {}
  })
  depends_on = [azurerm_logic_app_trigger_http_request.get]
}

resource "azurerm_logic_app_action_custom" "get_response" {
  name         = "Respond"
  logic_app_id = azurerm_logic_app_workflow.incident_get.id
  body = jsonencode({
    type = "Response"
    inputs = {
      statusCode = 200
      headers    = { "Content-Type" = "application/json" }
      body = {
        sentinel_incident_id = "@{triggerOutputs()['queries']['sentinel_incident_id']}"
        title                = "@{body('Get_Incident')?['properties']?['title']}"
        status               = "@{body('Get_Incident')?['properties']?['status']}"
        severity             = "@{body('Get_Incident')?['properties']?['severity']}"
        incident_number      = "@{body('Get_Incident')?['properties']?['incidentNumber']}"
      }
    }
    runAfter = { Get_Incident = ["Succeeded"] }
  })
  depends_on = [azurerm_logic_app_action_custom.get_incident]
}

# ============ (c) Elastic alert -> Log Analytics (Logs Ingestion API) ============
resource "azurerm_logic_app_trigger_http_request" "alert" {
  name         = "request"
  logic_app_id = azurerm_logic_app_workflow.alert.id
  method       = "POST"
  schema       = local.trigger_schema_alert
}

resource "azurerm_logic_app_action_custom" "alert_ingest" {
  name         = "Send_To_Log_Analytics"
  logic_app_id = azurerm_logic_app_workflow.alert.id
  body = jsonencode({
    type = "Http"
    inputs = {
      method  = "POST"
      uri     = "${azurerm_monitor_data_collection_endpoint.alerts.logs_ingestion_endpoint}/dataCollectionRules/${azurerm_monitor_data_collection_rule.alerts.immutable_id}/streams/Custom-ElasticAlerts_CL?api-version=2023-01-01"
      headers = { "Content-Type" = "application/json" }
      body = [{
        TimeGenerated      = "@utcNow()"
        rule_name_s        = "@string(coalesce(triggerBody()?['rule_name'],''))"
        rule_id_s          = "@string(coalesce(triggerBody()?['rule_id'],''))"
        severity_s         = "@string(coalesce(triggerBody()?['severity'],''))"
        risk_score_s       = "@string(coalesce(triggerBody()?['risk_score'],''))"
        reason_s           = "@string(coalesce(triggerBody()?['reason'],''))"
        host_name_s        = "@string(coalesce(triggerBody()?['host_name'],''))"
        message_s          = "@string(coalesce(triggerBody()?['message'],''))"
        alert_id_s         = "@string(coalesce(triggerBody()?['alert_id'],''))"
        kibana_alert_url_s = "@string(coalesce(triggerBody()?['kibana_alert_url'],''))"
        timestamp_s        = "@string(coalesce(triggerBody()?['timestamp'],''))"
      }]
      authentication = {
        type     = "ManagedServiceIdentity"
        audience = "https://monitor.azure.com/"
      }
    }
    runAfter = {}
  })
  depends_on = [azurerm_logic_app_trigger_http_request.alert, azurerm_role_assignment.alert_dcr]
}

resource "azurerm_logic_app_action_custom" "alert_response" {
  name         = "Respond"
  logic_app_id = azurerm_logic_app_workflow.alert.id
  body = jsonencode({
    type = "Response"
    inputs = {
      statusCode = 200
      body       = { status = "ingested" }
    }
    runAfter = { Send_To_Log_Analytics = ["Succeeded"] }
  })
  depends_on = [azurerm_logic_app_action_custom.alert_ingest]
}
