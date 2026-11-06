# config/

Static configuration consumed by Terraform via file() / templatefile(). No secrets are stored here.

## Files

| File | Purpose | Target |
|---|---|---|
| logicapps/incident-upsert.schema.json | Request trigger schema for create/update/comment of Sentinel incidents (fields: action, sentinel_incident_id, title, description, severity, status, tags, comment, kibana_case_id) | Logic App HTTP request trigger (azurerm_logic_app_trigger_http_request.schema) |
| logicapps/incident-get.schema.json | Doc/minimal schema for the get-incident Logic App; id arrives as query parameter sentinel_incident_id; response must have top-level `title` | Logic App HTTP request trigger |
| logicapps/elastic-alert.schema.json | Request trigger schema for pushed Elastic alerts | Logic App HTTP request trigger (alert to Sentinel incident) |
| kibana/webhook-case-connector.json | Fields of the .cases-webhook connector: create/update/comment bodies, response keys, get/view URL templates, plus create/update/comment URLs | elasticstack_kibana_action_connector (connector_type_id `.cases-webhook`), POST /api/actions/connector |
| kibana/rule-action-body.json | Body of the Webhook rule action; keys match elastic-alert.schema.json | `actions[].params.body` of the detection rule (elasticstack_kibana_security_detection_rule) |
| kibana/rule-ssh-enumeration.json | Detection rule "SSH Login Attempts for Multiple Invalid Users From One Source" (threshold, 1m, high, 73, MITRE T1110) | POST /api/detection_engine/rules |
| fleet/azure-eventhub-input.json | Azure Event Hub input vars for the Fleet package policy (azure_logs) | elasticstack_fleet_integration_policy |

## Placeholders

Terraform placeholders use `${name}` and are filled by templatefile(). Kibana mustache uses `{{...}}` / `{{{...}}}` and is passed through untouched (templatefile ignores braces without `$`). No file contains a literal `$${`. The case connector bodies must be sent to Kibana as-is; the mustache is rendered by Kibana at runtime.

| Placeholder | Kind | File |
|---|---|---|
| ${logicapp_upsert_url} | Terraform | webhook-case-connector.json |
| ${logicapp_get_url} | Terraform | webhook-case-connector.json |
| ${subscription_id}, ${resource_group}, ${workspace_name} | Terraform | webhook-case-connector.json |
| ${eventhub}, ${consumer_group}, ${connection_string}, ${storage_account}, ${storage_account_key} | Terraform | azure-eventhub-input.json |
| {{{case.id}}}, {{{case.title}}}, {{{case.description}}}, {{{case.severity}}}, {{{case.status}}}, {{{case.tags}}}, {{{case.comment}}}, {{{external.system.id}}} | Kibana | webhook-case-connector.json |
| {{rule.name}}, {{rule.id}}, {{alert.id}}, {{alert.uuid}}, {{kibanaBaseUrl}}, {{context.*}} | Kibana | rule-action-body.json |

The files with Terraform placeholders are valid JSON (placeholders sit inside string values). Only webhook-case-connector.json and azure-eventhub-input.json should go through templatefile(); the others use file().

## Notes

- Case bodies follow the blog's unquoted triple-brace style: Kibana JSON-encodes case variables for .cases-webhook, so strings and the tags array render as valid JSON.
- Blog field names (case_title, update-incident, ...) were replaced with the requested schema (title, action create|update|comment). The Logic Apps must map Kibana severity (low/medium/high/critical) to Sentinel (Low/Medium/High/High or Informational), and status to New/Active/Closed.
- Fleet package name and var names (azure_logs, eventhub, storage_account_key, ...) should be confirmed against the installed package version; the file is a template for the Terraform author.
