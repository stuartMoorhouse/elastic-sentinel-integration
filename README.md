# Elastic Security and Microsoft Sentinel Integration Demo

Terraform that deploys a small Microsoft Sentinel environment on Azure and an Elastic Cloud deployment, wired together to demonstrate bidirectional case and alert synchronisation plus Sentinel log ingestion, in five scenarios from the Elastic blog "Unifying security monitoring with Elastic Security and Microsoft Sentinel":

1. Elastic Security cases create and update Sentinel incidents.
2. Elastic Security alerts create Sentinel incidents.
3. Sentinel logs are exported into Elasticsearch.
4. Sentinel incidents create and update Elastic cases, and status changes sync both ways.
5. Closing a Sentinel incident that came from an Elastic alert closes or acknowledges the alert.

The main demo tells one story: an alert comes from Sentinel, the analyst investigates it in Timeline (pinned events, notes, a saved Timeline and template, tags, a case), and closing the alert in Elastic closes the incident in Sentinel. A seventh use case shows an analyst closing an alert in Elastic and the matching Sentinel incident closing automatically, using an Elastic Workflow. A sixth use case shows the analyst workflow in Elastic Cases: Markdown notes, attached alerts, Lens charts and files, timeline, tags and search, templates and custom fields. It needs no extra infrastructure: Terraform creates the case templates and custom fields, and `scripts/seed-cases.sh` adds example cases.

To run the demo, see [docs/runbook.md](docs/runbook.md).

## Architecture

```
                         Azure (eastus)
  +---------------------------------------------------------------+
  |  Linux VM (spot) ---- syslog via Azure Monitor Agent ----+    |
  |   |                                                      v    |
  |   +-- Elastic Agent (Fleet-managed)          Log Analytics     |
  |                                              workspace +       |
  |  Logic App: upsert incident  --+             Microsoft Sentinel|
  |  Logic App: get incident     --+--> Sentinel API connection    |
  |  Logic App: alert -> incident -+                  |            |
  |  Automation rules --> Logic App: incident -> Kibana case/alert     |
  |                                                   v            |
  |                          Data export rule --> Event Hub        |
  +---------------------------------------------------|------------+
                                                      |
  Elastic Cloud (Azure)                               |
    Elasticsearch, Kibana, Fleet Server               |
      - Case webhook connector  --> upsert/get Logic Apps (scenario 1)
      - Alert webhook connector --> alert Logic App       (scenario 2)
      - Detection rule "SSH Login Attempts for Multiple Invalid Users From One Source"
      - Azure Event Hub integration <------------------- (scenario 3)
      - Cases and alerts API <---- incident playbook ---- (scenarios 4, 5)
      - Detection rule "Microsoft Sentinel Incident Raised" (scenario 4)
```

## Resources created

### Azure

| Resource | Purpose |
|---|---|
| Resource group | Holds everything below. |
| Virtual network, subnet, network security group, public IP, NIC | Network for the VM. The security group has no inbound rules, so the VM is not reachable from the internet. The public IP is only for outbound traffic. |
| Linux VM (spot, `Standard_B2als_v2`) | Runs Elastic Agent and generates syslog data. Demo commands run on it with `az vm run-command`, so no SSH access is needed. An SSH key is generated because Azure requires one. |
| Azure Monitor Agent extension, data collection rule and association | Sends the VM's syslog to Log Analytics. |
| Log Analytics workspace | Stores Sentinel data (30 day retention). |
| Microsoft Sentinel onboarding | Enables Sentinel on the workspace. |
| Event Hubs namespace (Standard), event hub, consumer group, listen authorization rule | Carries exported Sentinel data to Elastic. |
| Log Analytics data export rule | Exports the Syslog, SecurityAlert and SecurityIncident tables to the event hub. |
| Storage account | Checkpoint storage for the Elastic Event Hub integration. |
| Entra app registration, client secret, Microsoft Sentinel Responder role | Identity the Elastic workflow uses to update Sentinel incidents. The secret expires after 90 days. |
| User-assigned managed identity, role assignment | One identity shared by the four Logic Apps, with the Microsoft Sentinel Contributor role on the workspace. Created before the Logic Apps. |
| Sentinel API connection | Lets the Logic Apps talk to Sentinel using the managed identity. No portal authorization is needed. |
| Logic App: upsert incident | Creates, updates and comments on Sentinel incidents (called by the Kibana case connector). |
| Logic App: get incident | Returns incident details to Kibana (called by the Kibana case connector). |
| Logic App: alert to incident | Creates a Sentinel incident from an Elastic alert (called by the Kibana alert connector). |
| Logic App: incident to Elastic | Sentinel playbook (incident trigger). Creates or updates a Kibana case for Sentinel incidents, copies status back to the originating case, and sets the alert status for incidents that came from an Elastic alert. |
| Sentinel automation rules (2) | Run the playbook when an incident is created and when it is updated. |
| Role assignment | Gives the "Azure Security Insights" service principal the Microsoft Sentinel Automation Contributor role on the resource group so automation rules can run the playbook. |

### Elastic Cloud and Kibana

| Resource | Purpose |
|---|---|
| Elastic Cloud deployment on Azure | Elasticsearch (1 GB hot, 1 zone), Kibana (1 GB), Integrations Server with Fleet (1 GB). Latest stack version available in the region. |
| Case management webhook connector | Syncs Kibana cases to Sentinel incidents through the upsert and get Logic Apps. |
| Alert webhook connector | Sends alert details to the alert Logic App. |
| Detection rule "SSH Login Attempts for Multiple Invalid Users From One Source" | Threshold rule (10 or more failed SSH logins, 5 or more distinct users, same source, 5 minutes). High severity, mapped to MITRE T1110. Calls the alert connector. |
| Detection rule "Microsoft Sentinel Incident Raised" | Query rule on the exported SecurityIncident rows. Excludes incidents Elastic created, so there is no alert loop. |
| Case templates "Accepted customer behaviour" and "SSH brute force triage" | Created by `scripts/apply-case-templates.sh` (run from a `terraform_data` resource) from `config/kibana/case-templates/*.yaml`. Include custom fields. Used by runbook use case 6. |
| Workflow `sentinel-alert-status-sync` | Elastic Workflow (every minute) that sets the Sentinel incident to Active or Closed when an analyst acknowledges or closes the alert in Elastic. Runbook use case 7. |
| Fleet agent policy with System and Azure Event Hub integrations | Enrolls the VM's Elastic Agent and ingests the Event Hub data. |

### Local files written by Terraform

| File | Purpose |
|---|---|
| `.ssh/sentinel-demo.pem` | Private key generated for the VM (not used by the scripts; git-ignored). |
| `shared/env.json` | Non-secret endpoints and flags used by the scripts. |

All taggable resources carry the tags from the `tags` variable.

## Not included

- Azure Activity logs. The subscription is already at the Azure limit of five subscription-level diagnostic settings.
- A manual connection authorization. The Logic Apps use a managed identity, so no person signs in. The deploying account needs Owner (or User Access Administrator) on the subscription for the role assignments.
- A scoped Kibana credential for the incident playbook. It calls Kibana as the `elastic` user (demo only).
- A custom Log Analytics table and NRT rule for Elastic alerts. Alerts create Sentinel incidents directly.

## Prerequisites

- Terraform 1.5 or later, the Azure CLI (`az`), `jq` and `curl`.
- An Azure subscription where you have Owner access (role assignments are created) and permission to create an Entra app registration (Application Administrator or Global Administrator), and `az login` completed for it. Default: the personal subscription `8e5b82f7-fb81-4620-8b75-fc820cf9f492`.
- An Elastic Cloud API key in the `EC_API_KEY` environment variable.
- The `az` `log-analytics` extension, for the validation script: `az extension add --name log-analytics`.

## Deploy

1. Copy `terraform.tfvars.example` to `terraform/terraform.tfvars` and fill in the subscription ID, tenant ID, and the tags. This file is git-ignored.
2. Make sure `az account show` is on the intended subscription.
3. From `terraform/`, run `terraform init`, `terraform plan`, then `terraform apply`. Creating the Elastic Cloud deployment takes several minutes. If Terraform times out, wait five minutes, run `terraform refresh` and `terraform plan` instead of applying again.
4. Run `scripts/configure.sh` to check that the connectors, rule and Fleet policy exist.
5. Run `scripts/validate.sh` to check the integration end to end (13 checks, about 5 to 60 minutes).

## Scripts

| Script | Purpose |
|---|---|
| `scripts/configure.sh` | Verifies the deployed Elastic configuration and records endpoints in `shared/env.json`. |
| `scripts/run_demo.sh` | Generates failed SSH logins on the VM. You create the Kibana case yourself. |
| `scripts/validate.sh` | Runs the acceptance checks and writes a summary to `results/`. |
| `scripts/create-sentinel-incident.sh` | Creates a Sentinel incident for the main demo and optionally waits for the matching Elastic alert (`--wait`). |
| `scripts/apply-case-templates.sh` | Creates or updates the Cases templates from `config/kibana/case-templates/`. Run by Terraform; can be run by hand. |
| `scripts/seed-cases.sh` | Creates example `accepted-behaviour` cases for use case 6 (idempotent, not pushed to Sentinel). Run after a reset. |
| `scripts/reset-demo.sh` | Removes ALL cases, security alerts and Sentinel incidents, plus the demo index. Keeps the infrastructure. |
| `scripts/get-urls.sh` | Prints the Kibana, Fleet and Azure portal links. |

See `scripts/README.md` and `config/README.md` for details.

## Repository layout

```
terraform/   Infrastructure and Elastic configuration
config/      Payload templates used by the Terraform (connector bodies, schemas, Fleet inputs)
scripts/     Demo and validation scripts
docs/        Runbook
shared/      Non-secret environment values written by Terraform
results/     Output of the scripts (git-ignored)
```

## Cost and teardown

Sentinel, Log Analytics, Event Hubs Standard, the spot VM and Elastic Cloud all bill while they exist. Destroy everything when finished:

```
cd terraform
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: ApiKey $EC_API_KEY" https://api.elastic-cloud.com/api/v1/deployments   # must print 200
terraform destroy
```

`terraform destroy` reads `data.ec_stack` and fails with `root.unauthenticated: The supplied authentication is invalid` if `EC_API_KEY` is expired or revoked. Export a fresh key and re-run; destroy resumes from state.

The Fleet agent policy has `skip_destroy = true` because enrolled agents block its deletion (HTTP 400, "Cannot delete an agent policy that is assigned to any active or inactive agents"); it is removed with the Elastic Cloud deployment.

Then confirm the resource group no longer exists.
