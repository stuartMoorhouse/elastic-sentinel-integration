# Demo Runbook

Five use cases, about 5 minutes each. Run them in any order. Use cases 4 and 5 show the sync in both directions.

## Before the demo

1. Run `scripts/get-urls.sh`. Open these in separate browser tabs:
   - Kibana (log in as `elastic`; the password is `terraform -chdir=terraform output -raw elastic_password`)
   - Azure portal, Microsoft Sentinel, your workspace, Incidents
2. Confirm the VM and data are healthy: run `scripts/validate.sh` the day before. All 13 checks should pass.
3. Start clean: run `scripts/reset-demo.sh --yes`.

## Use case 1: Elastic case creates a Sentinel incident

1. In Kibana, go to Security, Cases, and select Create case.
2. Enter a title and description. In "External incident management system", choose the Sentinel connector. Create the case.
3. Select the push button on the case. Kibana sends the case to Sentinel.
4. In the Sentinel tab, refresh Incidents. The new incident has the same title.
5. Back in Kibana, change the status to In progress and add a comment. Push again.
6. Refresh the incident in Sentinel. The status is Active and the comment is there.

## Use case 2: Elastic alert creates a Sentinel incident

1. Run `scripts/run_demo.sh`. It makes failed SSH logins for 10 different invalid usernames on the VM, which looks like an attacker guessing usernames.
2. In Kibana, go to Security, Alerts. Within a few minutes an alert from "SSH Login Attempts for Multiple Invalid Users From One Source" appears (high severity, MITRE T1110).
3. In the Sentinel tab, refresh Incidents. An incident titled "Elastic alert: SSH Login Attempts for Multiple Invalid Users From One Source" appears within a few minutes.
4. Open the incident to show the reason, host, source IP and link back to the Kibana alert.

## Use case 3: Sentinel logs are searchable in Elastic

1. Run `scripts/run_demo.sh` (it also creates failed SSH logins on the VM). Data takes 5 to 15 minutes to arrive, so start this early or use data already there.
2. In Sentinel, open Logs and run `Syslog | take 10` to show the data in Sentinel.
3. In Kibana, open Discover and switch to **ES|QL** mode (the query-language toggle next to the search bar). No data view is needed. Run the ES|QL equivalent of the Sentinel query:

   ```
   FROM logs-azure.eventhub-*
   | WHERE azure.eventhub.Type == "Syslog"
   | SORT @timestamp DESC
   | KEEP @timestamp, azure.eventhub.Computer, azure.eventhub.ProcessName, azure.eventhub.SeverityLevel, azure.eventhub.SyslogMessage
   | LIMIT 10
   ```

4. The same Syslog records appear in Elasticsearch, delivered through Log Analytics export and Event Hubs.
5. Optional: find the failed SSH logins that triggered the Elastic rule:

   ```
   FROM logs-azure.eventhub-*
   | WHERE azure.eventhub.SyslogMessage LIKE "*Invalid user*"
   | SORT @timestamp DESC
   | KEEP @timestamp, azure.eventhub.Computer, azure.eventhub.SyslogMessage
   | LIMIT 5
   ```

6. Optional: count events by process.

   ```
   FROM logs-azure.eventhub-*
   | WHERE azure.eventhub.Type == "Syslog"
   | STATS events = COUNT(*) BY azure.eventhub.ProcessName
   | SORT events DESC
   | LIMIT 5
   ```

## Use case 4: Sentinel incident creates and updates an Elastic case

1. In the Sentinel tab, create an incident (Incidents, Create incident). Give it a title and severity Medium.
2. Within about a minute a Sentinel automation rule runs the playbook, and a case with the same title appears in Kibana under Security, Cases. It is tagged `sentinel-incident-<id>` and already linked to the incident (the Sentinel connector shows as pushed).
3. In Sentinel, set the incident to Active. After a minute the Kibana case moves to In progress.
4. In Kibana, close the case and select push. Refresh the incident in Sentinel: it is Closed. The same incident was updated, no duplicate was created.
5. Optional: show the alert side. A Sentinel-raised incident also produces an alert from the rule "Microsoft Sentinel Incident Raised" after the Event Hub export arrives (5 to 15 minutes).

## Use case 5: Close in one place, closed in the other

1. Run use case 2 so an "Elastic alert: ..." incident exists in Sentinel.
2. In Sentinel, close that incident (choose any classification).
3. In Kibana, open Security, Alerts. The alert's status changes to Closed within about a minute. Setting the incident to Active marks the alert Acknowledged.
4. From the Kibana side, closing a case that has alerts attached closes those alerts, and pushing the case closes the incident (use case 1).

Sync summary:

| Elastic | Sentinel | Mechanism |
|---|---|---|
| Case create, status, severity, title, comments | Incident | Case webhook connector, upsert Logic App (push) |
| Alert created | Incident "Elastic alert: ..." | Rule action, alert Logic App |
| Case | Incident created in Sentinel | Automation rule, playbook calls the Cases API |
| Case status | Incident status changes | Automation rule (Created and Updated), playbook |
| Alert status | Incident status changes | Automation rule, playbook calls the alert status API |

Not synced: Elastic alert status changes made without a case (rule actions only fire on alert creation) and comments added in Sentinel.

## After the demo

- Reset for the next run: `scripts/reset-demo.sh --yes`.
- Tear everything down: `terraform -chdir=terraform destroy` (first confirm `EC_API_KEY` is valid; see README Cost and teardown).

## If something does not work

| Symptom | Fix |
|---|---|
| Push in Kibana fails or no incident appears | The Sentinel API connection is not authorized. In the Azure portal, open it, choose Edit API connection, Authorize, Save. |
| Sentinel incident does not become a case | Check the playbook run history (Logic App `elastic-sentinel-sentinel-incident-to-elastic`) and that both automation rules are enabled (Sentinel, Automation). The Sentinel API connection must be authorized and the role assignment on the resource group can take a few minutes to take effect. |
| No alert in Kibana | Wait 2 minutes (the rule runs every minute). Check the rule is enabled under Security, Rules. The rule needs 10 or more failures from 5 or more users in 5 minutes. |
| `run_demo.sh` says the VM is not running | Spot VMs can be evicted. Start it with `az vm start -g elastic-sentinel-rg -n elastic-sentinel-vm`. |
| No Event Hub data in Elastic | Wait up to 15 minutes. Check the agent is online under Fleet. |
