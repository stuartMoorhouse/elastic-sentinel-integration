# Demo scripts

All scripts are bash (`set -euo pipefail`), read Terraform outputs through `terraform -chdir=terraform output -raw <name>`, and require `az`, `jq`, `curl` and `terraform`. Every script except get-urls.sh first asserts that `az account show` is on the subscription Terraform deployed to (and, if EXPECTED_AZ_USER is set, the expected user), and aborts otherwise.

Terraform owns the Kibana connectors, detection rule, Fleet policy and Cases templates. The scripts only verify the first three exist.

## Run order

1. `terraform apply` (in `terraform/`)
2. `scripts/configure.sh`
3. `scripts/run_demo.sh`
4. `scripts/validate.sh`
5. `scripts/seed-cases.sh` (optional, for runbook use case 6)
6. `scripts/reset-demo.sh` (optional, to repeat the demo; run seed-cases.sh again afterwards)

Acceptance check 14 (`terraform destroy` leaves nothing behind) is manual.

## Scripts

- `lib.sh`: sourced helpers (output loading, `es_curl`, `kibana_curl`, logging, Azure preflight, `poll`). Credentials are passed to curl through a temporary 0600 config file, never on the command line.
- `configure.sh`: waits for Kibana and Fleet, verifies both connectors, the detection rule and a Fleet agent policy exist, then writes non-secret endpoints and `infra_ready`/`config_ready` to `shared/env.json`. Passwords are never written.
- `run_demo.sh`: via `az vm run-command` (no SSH) makes 10 failed SSH logins for different invalid users on the VM (Sentinel Syslog data). Does not create a case: you create and push the case yourself in Kibana. Saves `results/last_run.json`, sets `demo_executed`.
- `validate.sh`: runs checks 1-13, printing PASS, FAIL, TIMEOUT or SKIP (check 7 is skipped until you have pushed a case), and writes `results/validation-<timestamp>.json`. Exits nonzero if any check is not PASS or SKIP. Polling windows: alert 5 min, Log Analytics and incident 10 min, Event Hub to Elastic 15 min. Checks 10 to 13 are the round-trip sync checks: a Sentinel incident creates a case (10), a Sentinel status change reaches the case (11), closing the case and pushing closes the incident (12), and closing the Sentinel incident behind an Elastic alert closes the alert (13). Each polls up to 5 minutes. Allow up to about 60 minutes in the worst case.
- `reset-demo.sh [--yes]`: deletes ALL Kibana cases, ALL security alerts, ALL Sentinel incidents in the workspace, and the demo index. It repeats each delete until none are left. Prompts unless `--yes`. Infrastructure is untouched. Use only on this demo deployment.
- `apply-case-templates.sh`: standalone and idempotent; needs `KIBANA_URL`, `KIBANA_USER`, `KIBANA_PASSWORD` in the environment. Matches each `config/kibana/case-templates/*.yaml` to an existing template by name, then creates it, replaces it (new template version) or leaves it. Terraform runs it through `terraform_data.case_templates` whenever a template file or the script changes. It is not part of the normal run order.
- `seed-cases.sh`: creates three example cases tagged `accepted-behaviour` (plus a `customer:<name>` tag) with Markdown descriptions, connector "none". Skips any that already exist by title and tag. Case templates are created by Terraform (see `apply-case-templates.sh`).
- `get-urls.sh`: prints Kibana, Elasticsearch and Fleet URLs, the `az vm run-command` hint and Azure portal links. The password is not printed; use `terraform -chdir=terraform output -raw elastic_password`.

## Assumptions about Kibana 9.x APIs

- Cases API: `POST /api/cases` with `connector {id,name,type,fields:null}`, `PATCH /api/cases` with `{cases:[{id,version,status}]}`, `POST /api/cases/{id}/comments`, `DELETE /api/cases?ids=[...]`, `GET /api/cases/_find?tags=...`. The case-management connector type is `.cases-webhook`.
- Connector test: `POST /api/actions/connector/<id>/_execute`. For `.cases-webhook` the params are `{subAction:"pushToService", subActionParams:{incident,comments}}` (this may create a real Sentinel incident); other connectors receive `{body: "..."}`.
- `/api/status` reports `.status.overall.level == "available"` (9.x format).
- Fleet agents: `GET /api/fleet/agents`; healthy means status `online` or `healthy`. Agent policies: `GET /api/fleet/agent_policies`.
- Rules: `GET /api/detection_engine/rules/_find`; alerts live in `.alerts-security.alerts-default` with field `kibana.alert.rule.name`.
- The Sentinel incident id is read from `external_service.external_id` on `GET /api/cases/{id}`. If the connector does not auto-push on create, push the case manually in the UI.
- Check 7 expects Sentinel status `Active` for an in-progress case, which depends on the Logic App status mapping. Check 6 looks for a SecurityIncident titled "Elastic alert: <rule name>" created by the alert Logic App. Both Sentinel-facing Logic Apps require the Sentinel API connection to be authorized once in the portal.
- Writing to a `logs-*-*` name relies on the `logs` data stream template auto-creating the data stream.
- Sentinel REST API versions used: incidents 2023-02-01, onboardingStates 2024-03-01.
