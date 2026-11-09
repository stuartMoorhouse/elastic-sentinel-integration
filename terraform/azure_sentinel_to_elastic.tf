# Sentinel -> Elastic: a Sentinel automation rule runs this playbook on every incident
# created or updated. The playbook mirrors the incident into Kibana:
#   - Sentinel-native incident        -> Kibana case (tag sentinel-incident-<guid>), status/severity/title kept in sync
#   - incident made from an Elastic case  -> status copied back to that case
#   - incident made from an Elastic alert -> alert workflow status set (closed / acknowledged)
# Loop guard: a Kibana write happens only when the value differs from what Kibana already has.

locals {
  # Sentinel API values -> Kibana case values.
  inc = "outputs('Incident_Fields')"

  kb_auth = {
    type       = "Basic"
    username   = "@parameters('kibana_user')"
    "password" = "@parameters('kibana_password')"
  }
  kb_headers = {
    "kbn-xsrf"     = "true"
    "Content-Type" = "application/json"
  }

  playbook_actions = {
    Incident_Fields = {
      type = "Compose"
      inputs = {
        guid        = "@triggerBody()?['object']?['name']"
        title       = "@triggerBody()?['object']?['properties']?['title']"
        description = "@coalesce(triggerBody()?['object']?['properties']?['description'],'')"
        url         = "@coalesce(triggerBody()?['object']?['properties']?['incidentUrl'],'')"
        severity    = "@if(equals(toLower(triggerBody()?['object']?['properties']?['severity']),'high'),'high',if(equals(toLower(triggerBody()?['object']?['properties']?['severity']),'medium'),'medium','low'))"
        status      = "@if(equals(triggerBody()?['object']?['properties']?['status'],'Closed'),'closed',if(equals(triggerBody()?['object']?['properties']?['status'],'Active'),'in-progress','open'))"
      }
      runAfter = {}
    }

    # case = incident pushed from an Elastic case, alert = from an Elastic alert, native = anything else
    Origin = {
      type     = "Compose"
      inputs   = "@if(contains(${local.inc}?['description'],'(Elastic Security case '),'case',if(startsWith(${local.inc}?['title'],'Elastic alert:'),'alert','native'))"
      runAfter = { Incident_Fields = ["Succeeded"] }
    }

    Route = {
      type       = "Switch"
      expression = "@outputs('Origin')"
      runAfter   = { Origin = ["Succeeded"] }

      cases = {
        # ---- incident came from an Elastic case: copy status back to that case ----
        case = {
          case = "case"
          actions = {
            Case_Id = {
              type     = "Compose"
              inputs   = "@substring(${local.inc}?['description'],add(indexOf(${local.inc}?['description'],'(Elastic Security case '),23),36)"
              runAfter = {}
            }
            Get_Case = {
              type = "Http"
              inputs = {
                method         = "GET"
                uri            = "@{parameters('kibana_url')}/api/cases/@{outputs('Case_Id')}"
                headers        = local.kb_headers
                authentication = local.kb_auth
              }
              runAfter = { Case_Id = ["Succeeded"] }
            }
            Case_Differs = {
              type       = "If"
              expression = "@not(equals(body('Get_Case')?['status'],${local.inc}?['status']))"
              runAfter   = { Get_Case = ["Succeeded"] }
              actions = {
                Patch_Case = {
                  type = "Http"
                  inputs = {
                    method  = "PATCH"
                    uri     = "@{parameters('kibana_url')}/api/cases"
                    headers = local.kb_headers
                    body = {
                      cases = [{
                        id      = "@outputs('Case_Id')"
                        version = "@body('Get_Case')?['version']"
                        status  = "@${local.inc}?['status']"
                      }]
                    }
                    authentication = local.kb_auth
                  }
                  runAfter = {}
                }
              }
            }
          }
        }

        # ---- incident came from an Elastic alert: set the alert's workflow status ----
        alert = {
          case = "alert"
          actions = {
            Alert_Status_Changed = {
              type       = "If"
              expression = "@and(contains(${local.inc}?['description'],'[alert-uuid:'),not(equals(${local.inc}?['status'],'open')))"
              runAfter   = {}
              actions = {
                Set_Alert_Status = {
                  type = "Http"
                  inputs = {
                    method  = "POST"
                    uri     = "@{parameters('kibana_url')}/api/detection_engine/signals/status"
                    headers = local.kb_headers
                    body = {
                      signal_ids = ["@substring(${local.inc}?['description'],add(indexOf(${local.inc}?['description'],'[alert-uuid:'),12),36)"]
                      status     = "@if(equals(${local.inc}?['status'],'closed'),'closed','acknowledged')"
                    }
                    authentication = local.kb_auth
                  }
                  runAfter = {}
                }
              }
            }
          }
        }
      }

      # ---- Sentinel-native incident: create or update a Kibana case ----
      default = {
        actions = {
          Find_Case = {
            type = "Http"
            inputs = {
              method         = "GET"
              uri            = "@{parameters('kibana_url')}/api/cases/_find?owner=securitySolution&tags=sentinel-incident-@{${local.inc}?['guid']}"
              headers        = local.kb_headers
              authentication = local.kb_auth
            }
            runAfter = {}
          }
          Case_Exists = {
            type       = "If"
            expression = "@greater(body('Find_Case')?['total'],0)"
            runAfter   = { Find_Case = ["Succeeded"] }

            actions = {
              Existing_Differs = {
                type       = "If"
                expression = "@or(not(equals(body('Find_Case')?['cases']?[0]?['status'],${local.inc}?['status'])),not(equals(body('Find_Case')?['cases']?[0]?['severity'],${local.inc}?['severity'])),not(equals(body('Find_Case')?['cases']?[0]?['title'],${local.inc}?['title'])))"
                runAfter   = {}
                actions = {
                  Patch_Existing = {
                    type = "Http"
                    inputs = {
                      method  = "PATCH"
                      uri     = "@{parameters('kibana_url')}/api/cases"
                      headers = local.kb_headers
                      body = {
                        cases = [{
                          id       = "@body('Find_Case')?['cases']?[0]?['id']"
                          version  = "@body('Find_Case')?['cases']?[0]?['version']"
                          status   = "@${local.inc}?['status']"
                          severity = "@${local.inc}?['severity']"
                          title    = "@${local.inc}?['title']"
                        }]
                      }
                      authentication = local.kb_auth
                    }
                    runAfter = {}
                  }
                }
              }
            }

            else = {
              actions = {
                Create_Case = {
                  type = "Http"
                  inputs = {
                    method  = "POST"
                    uri     = "@{parameters('kibana_url')}/api/cases"
                    headers = local.kb_headers
                    body = {
                      title       = "@${local.inc}?['title']"
                      description = "@concat(${local.inc}?['description'],' | Sentinel incident: ',${local.inc}?['url'])"
                      tags        = ["@concat('sentinel-incident-',${local.inc}?['guid'])", "sentinel"]
                      severity    = "@${local.inc}?['severity']"
                      owner       = "securitySolution"
                      settings    = { syncAlerts = false }
                      connector = {
                        id     = "@parameters('case_connector_id')"
                        name   = "@parameters('case_connector_name')"
                        type   = ".cases-webhook"
                        fields = null
                      }
                    }
                    authentication = local.kb_auth
                  }
                  runAfter = {}
                }
                # New cases always start open; apply the incident's status if it differs.
                Created_Needs_Status = {
                  type       = "If"
                  expression = "@not(equals(${local.inc}?['status'],'open'))"
                  runAfter   = { Create_Case = ["Succeeded"] }
                  actions = {
                    Patch_New = {
                      type = "Http"
                      inputs = {
                        method  = "PATCH"
                        uri     = "@{parameters('kibana_url')}/api/cases"
                        headers = local.kb_headers
                        body = {
                          cases = [{
                            id      = "@body('Create_Case')?['id']"
                            version = "@body('Create_Case')?['version']"
                            status  = "@${local.inc}?['status']"
                          }]
                        }
                        authentication = local.kb_auth
                      }
                      runAfter = {}
                    }
                  }
                }
                # Push links the case to the incident: the upsert Logic App sees the
                # sentinel-incident-<guid> tag and returns this incident's id, so Kibana stores it
                # as the external id and later Elastic-side edits update the same incident.
                Push_Case = {
                  type = "Http"
                  inputs = {
                    method         = "POST"
                    uri            = "@{parameters('kibana_url')}/api/cases/@{body('Create_Case')?['id']}/connector/@{parameters('case_connector_id')}/_push"
                    headers        = local.kb_headers
                    body           = {}
                    authentication = local.kb_auth
                  }
                  runAfter = { Created_Needs_Status = ["Succeeded"] }
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "azapi_resource" "sentinel_to_elastic" {
  type      = "Microsoft.Logic/workflows@2019-05-01"
  name      = "${var.prefix}-sentinel-incident-to-elastic"
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id
  tags      = local.tags

  body = {
    properties = {
      state = "Enabled"
      definition = {
        "$schema"      = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
        contentVersion = "1.0.0.0"
        parameters = {
          "$connections"      = { type = "Object", defaultValue = {} }
          kibana_url          = { type = "String" }
          kibana_user         = { type = "String" }
          kibana_password     = { type = "SecureString" }
          case_connector_id   = { type = "String" }
          case_connector_name = { type = "String" }
        }
        triggers = {
          Microsoft_Sentinel_incident = {
            type = "ApiConnectionWebhook"
            inputs = {
              host = local.sentinel_conn_host
              body = { callback_url = "@{listCallbackUrl()}" }
              path = "/incident-creation"
            }
          }
        }
        actions = local.playbook_actions
      }
      parameters = {
        "$connections" = { value = jsondecode(local.connections_param) }
        # Strip the trailing slash so "@{kibana_url}/api/..." is well formed.
        kibana_url          = { value = trimsuffix(ec_deployment.main.kibana.https_endpoint, "/") }
        kibana_user         = { value = ec_deployment.main.elasticsearch_username }
        case_connector_id   = { value = elasticstack_kibana_action_connector.case.connector_id }
        case_connector_name = { value = elasticstack_kibana_action_connector.case.name }
      }
    }
  }

  # Demo only: the Logic App calls Kibana with the elastic superuser. Use a scoped API key
  # or a dedicated Kibana user with Cases and Security privileges outside a demo.
  sensitive_body = {
    properties = {
      parameters = {
        kibana_password = { value = ec_deployment.main.elasticsearch_password }
      }
    }
  }
}

# Sentinel runs automation-rule playbooks as the "Azure Security Insights" service principal,
# which needs this role on the resource group holding the playbook.
data "azuread_service_principal" "sentinel" {
  client_id = "98785600-1bb7-4fb9-b9fa-19afe2c8a360"
}

resource "azurerm_role_assignment" "sentinel_playbooks" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Microsoft Sentinel Automation Contributor"
  principal_id         = data.azuread_service_principal.sentinel.object_id
}

resource "random_uuid" "automation_created" {}
resource "random_uuid" "automation_updated" {}

resource "azurerm_sentinel_automation_rule" "incident_created" {
  name                       = random_uuid.automation_created.result
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.main.workspace_id
  display_name               = "Elastic: mirror new incident to Kibana"
  order                      = 1
  triggers_on                = "Incidents"
  triggers_when              = "Created"

  action_playbook {
    logic_app_id = azapi_resource.sentinel_to_elastic.id
    order        = 1
  }

  depends_on = [azurerm_role_assignment.sentinel_playbooks]
}

resource "azurerm_sentinel_automation_rule" "incident_updated" {
  name                       = random_uuid.automation_updated.result
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.main.workspace_id
  display_name               = "Elastic: mirror incident changes to Kibana"
  order                      = 2
  triggers_on                = "Incidents"
  triggers_when              = "Updated"

  action_playbook {
    logic_app_id = azapi_resource.sentinel_to_elastic.id
    order        = 1
  }

  depends_on = [azurerm_role_assignment.sentinel_playbooks]
}
