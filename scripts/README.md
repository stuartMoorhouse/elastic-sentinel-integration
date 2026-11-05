# Demo scripts

All scripts are bash (`set -euo pipefail`), read Terraform outputs through `terraform -chdir=terraform output -raw <name>`, and require `az`, `jq`, `curl`, `ssh` and `terraform`. Every script except get-urls.sh first asserts that `az account show` is on the subscription Terraform deployed to (and, if EXPECTED_AZ_USER is set, the expected user), and aborts otherwise.

Terraform owns the Kibana connectors, detection rule and Fleet policy. The scripts only verify that they exist.

## Run order

1. `terraform apply` (in `terraform/`)
2. `scripts/configure.sh`
3. `scripts/run_demo.sh`
4. `scripts/validate.sh`
5. `scripts/reset-demo.sh` (optional, to repeat the demo)

Acceptance check 10 (`terraform destroy` leaves nothing behind) is manual.

## Scripts

- `lib.sh`: sourced helpers (output loading, `es_curl`, `kibana_curl`, logging, Azure preflight, `poll`). Credentials are passed to curl through a temporary 0600 config file, never on the command line.
- `configure.sh`: waits for Kibana and Fleet, verifies both connectors, the detection rule and a Fleet agent policy exist, then writes non-secret endpoints and `infra_ready`/`config_ready` to `shared/env.json`. Passwords are never written.
- `run_demo.sh`: over SSH writes a "malware detected demo" syslog line and 10 failed SSH logins on the VM (Sentinel Syslog data); indexes a "malware detected by demo" document into `logs-demo-sentinel-default` (the rule searches `logs-*`); creates a Kibana case using the case-management connector, moves it to in-progress and adds a comment. Saves `results/last_case.json` and `results/last_run.json`, sets `demo_executed`.
- `validate.sh`: runs checks 1-9, printing PASS, FAIL or TIMEOUT, and writes `results/validation-<timestamp>.json`. Exits nonzero if any check is not PASS. Polling windows: alert 5 min, Log Analytics and incident 10 min, Event Hub to Elastic 15 min. Allow up to about 40 minutes in the worst case.
- `reset-demo.sh [--yes]`: deletes cases tagged `elastic-sentinel-demo`, the demo index, alerts for the rule, and Sentinel incidents whose title starts with "Elastic Demo Case" or mentions Elastic or the rule name. Prompts unless `--yes`. Infrastructure is untouched.
- `get-urls.sh`: prints Kibana, Elasticsearch and Fleet URLs, the SSH command and Azure portal links. The password is not printed; use `terraform -chdir=terraform output -raw elastic_password`.

## Assumptions about Kibana 9.x APIs

- Cases API: `POST /api/cases` with `connector {id,name,type,fields:null}`, `PATCH /api/cases` with `{cases:[{id,version,status}]}`, `POST /api/cases/{id}/comments`, `DELETE /api/cases?ids=[...]`, `GET /api/cases/_find?tags=...`. The case-management connector type is `.cases-webhook`.
- Connector test: `POST /api/actions/connector/<id>/_execute`. For `.cases-webhook` the params are `{subAction:"pushToService", subActionParams:{incident,comments}}` (this may create a real Sentinel incident); other connectors receive `{body: "..."}`.
- `/api/status` reports `.status.overall.level == "available"` (9.x format).
- Fleet agents: `GET /api/fleet/agents`; healthy means status `online` or `healthy`. Agent policies: `GET /api/fleet/agent_policies`.
- Rules: `GET /api/detection_engine/rules/_find`; alerts live in `.alerts-security.alerts-default` with field `kibana.alert.rule.name`.
- The Sentinel incident id is read from `external_service.external_id` on `GET /api/cases/{id}`. If the connector does not auto-push on create, push the case manually in the UI.
- Check 7 expects Sentinel status `Active` for an in-progress case, which depends on the Logic App status mapping. Check 6 matches NRT incidents by a title containing "Elastic" or the rule name.
- Writing to a `logs-*-*` name relies on the `logs` data stream template auto-creating the data stream.
- Sentinel REST API versions used: incidents 2023-02-01, onboardingStates 2024-03-01.
