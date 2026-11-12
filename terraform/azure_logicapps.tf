locals {
  sentinel_api_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Web/locations/${azurerm_resource_group.main.location}/managedApis/azuresentinel"
  # Sentinel connector actions take the incident ARM id. The Kibana-facing id is the
  # incident name (GUID); the ARM id is rebuilt from it.
  incident_arm_prefix   = "${azurerm_log_analytics_workspace.main.id}/providers/Microsoft.SecurityInsights/Incidents"
  sentinel_conn_host    = { connection = { name = "@parameters('$connections')['azuresentinel']['connectionId']" } }
  trigger_schema_upsert = file("${path.module}/../config/logicapps/incident-upsert.schema.json")
  trigger_schema_get    = file("${path.module}/../config/logicapps/incident-get.schema.json")
  trigger_schema_alert  = file("${path.module}/../config/logicapps/elastic-alert.schema.json")

  # Elastic severity (low/medium/high/critical) -> Sentinel (Informational/Low/Medium/High)
  severity_expr = "@if(equals(triggerBody()?['severity'],'critical'),'High',if(equals(triggerBody()?['severity'],'high'),'High',if(equals(triggerBody()?['severity'],'medium'),'Medium',if(equals(triggerBody()?['severity'],'low'),'Low','Informational'))))"
  # Elastic status (open/in-progress/closed) -> Sentinel (New/Active/Closed)
  status_expr = "@if(equals(triggerBody()?['status'],'closed'),'Closed',if(equals(triggerBody()?['status'],'in-progress'),'Active','New'))"
}

# One user-assigned managed identity shared by all four Logic Apps. It is created and given its
# role BEFORE the workflows exist: the playbook's incident trigger subscribes to Sentinel when
# the workflow is created, so the identity must already be allowed to call Sentinel. This
# replaces the OAuth connection that had to be authorized by a person in the portal (that
# token came from the person's home tenant and was rejected when the account is a guest).
resource "azurerm_user_assigned_identity" "logicapps" {
  name                = "${var.prefix}-logicapps-id"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Reads and writes incidents, comments and triggers (create, update, comment, get).
resource "azurerm_role_assignment" "logicapps_sentinel" {
  scope                = azurerm_log_analytics_workspace.main.id
  role_definition_name = "Microsoft Sentinel Contributor"
  principal_id         = azurerm_user_assigned_identity.logicapps.principal_id
}

# Sentinel API connection using managed identity auth (no portal authorization step).
# The "Alternative" parameter value type is what makes the Sentinel connector accept the
# workflows' managed identity: the connector advertises no managedIdentityAuth parameter
# set, and the workflows are rejected with WorkflowManagedIdentityConfigurationInvalid.
# The name differs from the earlier OAuth connection, so Terraform replaces it.
resource "azapi_resource" "sentinel_connection" {
  type      = "Microsoft.Web/connections@2016-06-01"
  name      = "${var.prefix}-sentinel-msi"
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id
  tags      = local.tags

  # parameterValueType is accepted by the Azure API but missing from azapi's embedded schema.
  schema_validation_enabled = false

  body = {
    properties = {
      displayName           = "${var.prefix}-sentinel-msi"
      api                   = { id = local.sentinel_api_id }
      customParameterValues = {}
      parameterValueType    = "Alternative"
    }
  }
}

locals {
  connections_param = jsonencode({
    azuresentinel = {
      connectionId   = azapi_resource.sentinel_connection.id
      connectionName = "azuresentinel"
      id             = local.sentinel_api_id
      connectionProperties = {
        authentication = {
          type     = "ManagedServiceIdentity"
          identity = azurerm_user_assigned_identity.logicapps.id
        }
      }
    }
  })
}

resource "azurerm_logic_app_workflow" "incident_upsert" {
  name                = "${var.prefix}-elastic-upsert-incident"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  workflow_parameters = { "$connections" = jsonencode({ type = "Object", defaultValue = {} }) }
  parameters          = { "$connections" = local.connections_param }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.logicapps.id]
  }

  depends_on = [azurerm_role_assignment.logicapps_sentinel]
}

resource "azurerm_logic_app_workflow" "incident_get" {
  name                = "${var.prefix}-elastic-get-incident"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  workflow_parameters = { "$connections" = jsonencode({ type = "Object", defaultValue = {} }) }
  parameters          = { "$connections" = local.connections_param }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.logicapps.id]
  }

  depends_on = [azurerm_role_assignment.logicapps_sentinel]
}

resource "azurerm_logic_app_workflow" "alert" {
  name                = "${var.prefix}-elastic-alert-to-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  workflow_parameters = { "$connections" = jsonencode({ type = "Object", defaultValue = {} }) }
  parameters          = { "$connections" = local.connections_param }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.logicapps.id]
  }

  depends_on = [azurerm_role_assignment.logicapps_sentinel]
}

# ============ (a) create / update / comment incident ============
resource "azurerm_logic_app_trigger_http_request" "upsert" {
  name         = "request"
  logic_app_id = azurerm_logic_app_workflow.incident_upsert.id
  method       = "POST"
  schema       = local.trigger_schema_upsert
}

# Existing incident name (GUID) for update/comment; empty for create.
resource "azurerm_logic_app_action_custom" "upsert_id" {
  name         = "Incident_Id"
  logic_app_id = azurerm_logic_app_workflow.incident_upsert.id
  body = jsonencode({
    type     = "Compose"
    inputs   = "@coalesce(triggerBody()?['sentinel_incident_id'],'')"
    runAfter = {}
  })
  depends_on = [azurerm_logic_app_trigger_http_request.upsert]
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
    }
    runAfter = { Incident_Id = ["Succeeded"] }
  })
  depends_on = [azurerm_logic_app_action_custom.upsert_id]
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
          # Cases created from a Sentinel incident (see azure_sentinel_to_elastic.tf) carry the tag
          # "sentinel-incident-<guid>". The incident already exists, so the first push returns that
          # guid instead of creating a duplicate; later pushes then update the same incident.
          Native_Tag = {
            type = "Query"
            inputs = {
              from  = "@coalesce(triggerBody()?['tags'],createArray())"
              where = "@startsWith(item(),'sentinel-incident-')"
            }
            runAfter = {}
          }
          Existing_Or_New = {
            type       = "If"
            expression = "@greater(length(body('Native_Tag')),0)"
            runAfter   = { Native_Tag = ["Succeeded"] }
            actions = {
              Respond_Existing = {
                type = "Response"
                inputs = {
                  statusCode = 200
                  headers    = { "Content-Type" = "application/json" }
                  body       = { sentinel_incident_id = "@{substring(first(body('Native_Tag')),18)}" }
                }
                runAfter = {}
              }
            }
            else = {
              actions = {
                Create_Incident = {
                  type = "ApiConnection"
                  inputs = {
                    host   = local.sentinel_conn_host
                    method = "put"
                    path   = "/Incidents/subscriptions/@{encodeURIComponent('${var.subscription_id}')}/resourceGroups/@{encodeURIComponent('${azurerm_resource_group.main.name}')}/workspaces/@{encodeURIComponent('${azurerm_log_analytics_workspace.main.name}')}"
                    body = {
                      title       = "@outputs('Props')?['title']"
                      description = "@outputs('Props')?['description']"
                      severity    = "@outputs('Props')?['severity']"
                      status      = "@outputs('Props')?['status']"
                    }
                  }
                  runAfter = {}
                }
                Respond_Created = {
                  type = "Response"
                  inputs = {
                    statusCode = 200
                    headers    = { "Content-Type" = "application/json" }
                    body       = { sentinel_incident_id = "@{body('Create_Incident')?['name']}" }
                  }
                  runAfter = { Create_Incident = ["Succeeded"] }
                }
              }
            }
          }
        }
      }
      update = {
        case = "update"
        actions = {
          Update_Incident = {
            type = "ApiConnection"
            inputs = {
              host   = local.sentinel_conn_host
              method = "put"
              path   = "/Incidents"
              # UNVERIFIED: Sentinel requires a classification when closing; the connector's
              # classification field is dynamic. Adjust after checking the connector in the portal.
              body = "@if(equals(outputs('Props')?['status'],'Closed'),json(concat('{\"incidentArmId\":\"${local.incident_arm_prefix}/',outputs('Incident_Id'),'\",\"title\":\"',outputs('Props')?['title'],'\",\"severity\":\"',outputs('Props')?['severity'],'\",\"status\":\"Closed\",\"classification\":{\"ClassificationAndReason\":\"Undetermined\"}}')),json(concat('{\"incidentArmId\":\"${local.incident_arm_prefix}/',outputs('Incident_Id'),'\",\"title\":\"',outputs('Props')?['title'],'\",\"severity\":\"',outputs('Props')?['severity'],'\",\"status\":\"',outputs('Props')?['status'],'\"}')))"
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
            type = "ApiConnection"
            inputs = {
              host   = local.sentinel_conn_host
              method = "post"
              path   = "/Incidents/Comment"
              body = {
                incidentArmId = "${local.incident_arm_prefix}/@{outputs('Incident_Id')}"
                message       = "@{coalesce(triggerBody()?['comment'],'')}"
              }
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
    type = "ApiConnection"
    inputs = {
      host   = local.sentinel_conn_host
      method = "post"
      path   = "/Incidents"
      body   = { incidentArmId = "${local.incident_arm_prefix}/@{triggerOutputs()['queries']['sentinel_incident_id']}" }
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

# ============ (c) Elastic alert -> Sentinel incident (direct, via the Sentinel connection) ============
resource "azurerm_logic_app_trigger_http_request" "alert" {
  name         = "request"
  logic_app_id = azurerm_logic_app_workflow.alert.id
  method       = "POST"
  schema       = local.trigger_schema_alert
}

resource "azurerm_logic_app_action_custom" "alert_incident" {
  name         = "Create_Sentinel_Incident"
  logic_app_id = azurerm_logic_app_workflow.alert.id
  body = jsonencode({
    type = "ApiConnection"
    inputs = {
      host   = local.sentinel_conn_host
      method = "put"
      path   = "/Incidents/subscriptions/@{encodeURIComponent('${var.subscription_id}')}/resourceGroups/@{encodeURIComponent('${azurerm_resource_group.main.name}')}/workspaces/@{encodeURIComponent('${azurerm_log_analytics_workspace.main.name}')}"
      body = {
        title       = "@concat('Elastic alert: ',coalesce(triggerBody()?['rule_name'],'unknown rule'))"
        description = "@concat('Reason: ',coalesce(triggerBody()?['reason'],''),' | Host: ',coalesce(triggerBody()?['host_name'],''),' | Message: ',coalesce(triggerBody()?['message'],''),' | Risk score: ',string(coalesce(triggerBody()?['risk_score'],'')),' | Alert: ',coalesce(triggerBody()?['kibana_alert_url'],''),if(empty(coalesce(triggerBody()?['alert_uuid'],'')),'',concat(' [alert-uuid:',triggerBody()?['alert_uuid'],']')))"
        severity    = local.severity_expr
        status      = "New"
      }
    }
    runAfter = {}
  })
  depends_on = [azurerm_logic_app_trigger_http_request.alert]
}

resource "azurerm_logic_app_action_custom" "alert_response" {
  name         = "Respond"
  logic_app_id = azurerm_logic_app_workflow.alert.id
  body = jsonencode({
    type = "Response"
    inputs = {
      statusCode = 200
      body       = { status = "incident created", sentinel_incident_id = "@{body('Create_Sentinel_Incident')?['name']}" }
    }
    runAfter = { Create_Sentinel_Incident = ["Succeeded"] }
  })
  depends_on = [azurerm_logic_app_action_custom.alert_incident]
}
