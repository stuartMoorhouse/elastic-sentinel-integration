# Demo Runbook

Three use cases, about 5 minutes each. Run them in any order.

## Before the demo

1. Run `scripts/get-urls.sh`. Open these in separate browser tabs:
   - Kibana (log in as `elastic`; the password is `terraform -chdir=terraform output -raw elastic_password`)
   - Azure portal, Microsoft Sentinel, your workspace, Incidents
2. Confirm the VM and data are healthy: run `scripts/validate.sh` the day before. All 9 checks should pass.
3. Start clean: run `scripts/reset-demo.sh --yes`.

## Use case 1: Elastic case creates a Sentinel incident

1. In Kibana, go to Security, Cases, and select Create case.
2. Enter a title and description. In "External incident management system", choose the Sentinel connector. Create the case.
3. Select the push button on the case. Kibana sends the case to Sentinel.
4. In the Sentinel tab, refresh Incidents. The new incident has the same title.
5. Back in Kibana, change the status to In progress and add a comment. Push again.
6. Refresh the incident in Sentinel. The status is Active and the comment is there.

Shortcut: `scripts/run_demo.sh` does all of this in about 30 seconds.

## Use case 2: Elastic alert creates a Sentinel incident

1. Run `scripts/run_demo.sh`. It writes a log message containing "malware".
2. In Kibana, go to Security, Alerts. Within about 2 minutes an alert from "Sentinel Test Rule" appears.
3. In the Sentinel tab, refresh Incidents. An incident titled "Elastic alert: Sentinel Test Rule" appears within a few minutes.
4. Open the incident to show the reason, host and link back to the Kibana alert.

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
5. Optional: find the "malware" line that `run_demo.sh` wrote on the VM:

   ```
   FROM logs-azure.eventhub-*
   | WHERE azure.eventhub.SyslogMessage LIKE "*malware*"
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

## After the demo

- Reset for the next run: `scripts/reset-demo.sh --yes`.
- Tear everything down: `terraform -chdir=terraform destroy`.

## If something does not work

| Symptom | Fix |
|---|---|
| Push in Kibana fails or no incident appears | The Sentinel API connection is not authorized. In the Azure portal, open it, choose Edit API connection, Authorize, Save. |
| No alert in Kibana | Wait 2 minutes (the rule runs every minute). Check the rule is enabled under Security, Rules. |
| Cannot SSH to the VM (`run_demo.sh` times out) | Your public IP changed. Update `operator_ip_cidr` in `terraform/terraform.tfvars` and run `terraform apply -target=azurerm_network_security_group.vm`. |
| No Event Hub data in Elastic | Wait up to 15 minutes. Check the agent is online under Fleet. |
