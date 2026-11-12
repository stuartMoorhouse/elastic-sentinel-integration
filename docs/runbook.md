# Demo Runbook

The main demo (about 15 minutes) tells one story: an alert arrives from Sentinel, the analyst investigates it in Timeline and keeps the findings, and closing the alert in Elastic closes the incident in Sentinel. Use cases 1 to 7 are shorter supporting modules (about 5 minutes each) that you can run in any order. Use cases 4 and 5 show the sync from Sentinel to Elastic, use case 6 the analyst workflow in Elastic Cases, and use case 7 the same close-once flow for an alert that Elastic raised itself.

## Before the demo

1. Run `scripts/get-urls.sh`. Open these in separate browser tabs:
   - Kibana (log in as `elastic`; the password is `terraform -chdir=terraform output -raw elastic_password`)
   - Azure portal, Microsoft Sentinel, your workspace, Incidents
2. Confirm the VM and data are healthy: run `scripts/validate.sh` the day before. All 13 checks should pass.
3. Start clean: run `scripts/reset-demo.sh --yes`. It clears alerts, cases, Timelines, notes, rule exceptions and Sentinel incidents, and re-seeds the example accepted-behaviour cases. Add `--incident` to also create a fresh Sentinel incident and wait for its Elastic alert (then skip that step below).
4. The reset has already re-created the accepted-behaviour cases to find (`scripts/seed-cases.sh`). The case templates are created by Terraform and survive a reset.
5. For the main demo, 15 minutes or more beforehand:
   - Run `scripts/run_demo.sh` so the VM's authentication logs have a burst of failed SSH logins for Timeline to show.
   - Run `scripts/create-sentinel-incident.sh --wait`. It creates a Sentinel incident and waits for the Elastic alert (usually a few minutes, up to 15).
   - In Kibana, open Workflows and check `sentinel-alert-status-sync` is enabled.
6. Do not connect the workspace to the Defender portal. Incidents created through the Sentinel API are not synced into the Defender queue.

## Main demo: a Sentinel alert, investigated and closed in Elastic

The story: Elastic can be the analyst's one console for alerts from other tools. The analyst investigates in Elastic, records what they found so the whole team can search it later, and closes the alert once. The incident in Sentinel closes on its own.

### Part 1: An alert comes from Sentinel

1. In the Sentinel tab, open Incidents. "Suspicious SSH activity on Linux host (demo)" is there with status New. Sentinel raised it; nothing in Elastic created it.
2. In Kibana, go to Security, Alerts and filter `kibana.alert.rule.name: "Microsoft Sentinel Incident Raised"`. The same incident is an Elastic alert. Open it and show the Sentinel fields on the alert (`azure.eventhub.Title`, `Description`, `Severity`, `IncidentUrl`). The path is Log Analytics export, Event Hub, Elastic Agent, then a detection rule, so it arrives a few minutes after Sentinel raised it.

### Part 2: Investigate in Timeline and keep the findings

3. In the alert flyout, choose Take action, then Investigate in timeline.
4. Look at what the host was doing. In the Timeline query bar enter `host.name : "elastic-sentinel-vm" and event.category : "authentication"`, and set the time range to cover the last day. The failed SSH logins for invalid users are the burst the incident describes. The source (127.0.0.1) and the pattern match the customer's known vulnerability scan.
5. Pin the events that matter (the pin icon on each row; they appear on the Pinned tab). Add a note to a pinned event, for example "Burst of failed logins from the scanner address, matches the nightly vulnerability scan. See the accepted-behaviour case." Add a note on the Timeline itself summarizing the conclusion.
6. Save the Timeline with a clear title and description (for example "Accepted: vulnerability scan SSH noise"). Use the star to favorite it.
7. Make it reusable. On the Timelines page, open the row's All actions menu and choose **Create template from timeline**. A Timeline template can be attached to a detection rule, so the next alert from that rule opens in Timeline with the same investigation ready (dropzone values are filled from the alert).
8. Attach the findings to a case. In the Timeline, choose Attach to case, then Attach to new case. Create the case from the "Accepted customer behaviour" template (tag `accepted-behaviour`, fill in Customer and Approved by). Then add the alert to the same case from the alert flyout (Take action, Add to case).
9. Mark the alert as a false positive: in the alert flyout, Take action, Apply alert tags, **False Positive**. Tags are filterable on the Alerts page.
10. Optional: Take action, **Add rule exception**, with a comment explaining the accepted behaviour. This stops repeat alerts as well as documenting them. Keep it narrow and remove it afterwards (Rules, the rule's exceptions), because `create-sentinel-incident.sh` always uses the same incident title and the next demo run would not alert.

### Part 3: Close once, closed in Sentinel

11. Close the alert: change the status to Closed and choose the reason **False positive**.
12. Wait about 2 minutes. The workflow `sentinel-alert-status-sync` runs every minute. In Kibana, open Workflows, then that workflow, to show the run and its steps.
13. Refresh Incidents in the Sentinel tab. The incident is **Closed**, classification False positive. Nobody logged into Sentinel to do that.

### Part 4: The finding is now searchable by the whole team

14. Cases: filter by tag `accepted-behaviour`. The new case sits with the seeded accepted-behaviour cases, with the alert and Timeline attached. Search by customer name or text.
15. Timelines: search for the Timeline or the template by title. The pinned events and notes are saved with it.
16. Notes: open the Notes page (search for "Notes" in the global search bar) and search for text from your note. Every note across alerts, events and Timelines is listed there.
17. Alerts: filter `kibana.alert.workflow_tags: "False Positive"` to see all alerts analysts classified this way.

Notes:
- Only the alert status and close reason are synced to Sentinel (Active or Closed, with the classification). Notes, Timelines, tags and cases stay in Elastic.
- There is no single knowledge-base object. Cases, notes, Timelines and alert tags are searched in their own places, so agree tag names (for example `accepted-behaviour`) and use them consistently.
- Elastic Workflows can also be run from an alert (Take action, Run workflow) for on-demand response, and Agent Builder can answer questions over this history. Neither is configured in this demo.

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
| Alert acknowledged or closed in Elastic | Incident Active or Closed | Elastic Workflow polls every minute, calls the Sentinel API |

Not synced: comments added in Sentinel, and case files, timelines, templates and custom fields.

## Use case 6: Analyst case workflow in Elastic

Shows how an analyst documents and finds work in Elastic Cases with few clicks, and how the case still reaches Sentinel.

### Setup

Terraform creates two case templates during `terraform apply` (definitions in `config/kibana/case-templates/`). Nothing to set up by hand. Each template pre-fills the case description, tags and severity, and carries its own custom fields:

- "Accepted customer behaviour": tag `accepted-behaviour`, severity Low, description headings Behaviour, Decision and Review, custom fields `Customer` (required), `Accepted behaviour` (toggle, on) and `Approved by`.
- "SSH brute force triage": tags `ssh` and `triage`, severity High, description from the rule's triage note, custom fields `Customer` and `Accepted behaviour` (toggle, off).

To change a template, edit its YAML and run `terraform apply` (or `scripts/apply-case-templates.sh` with `KIBANA_URL`, `KIBANA_USER` and `KIBANA_PASSWORD` set). `scripts/reset-demo.sh` deletes cases but not templates.

### Steps

1. Run use case 2 so the SSH alert exists. Run `scripts/seed-cases.sh` beforehand.
2. In Security, Alerts, open the alert flyout and choose Take action, Add to existing case (or Add to new case, choosing the "SSH brute force triage" template, which pre-fills the description and custom fields). The alert is attached in two clicks.
3. Open the case. Edit the description in Markdown, add a comment with findings (headings, a list and a code block), and fill in the custom fields.
4. From the alert flyout, choose Investigate in timeline. In the timeline pin the key events, add a note to a pinned event, save a query (for example `source.ip : "<attacker ip>"`), then use Attach to case so the timeline is on the case.
5. Open a Lens visualization (for example failed SSH logins over time from `logs-system.auth-*`), save it, and from its menu choose Add to case. Drag a file (a screenshot or a text export) onto the case Activity tab to attach it.
6. Show findability: in Cases, filter by tag `accepted-behaviour`, then search for `contoso`. The three seeded cases show the customer behaviours already accepted, searchable by the whole team. Create a new case from the "Accepted customer behaviour" template to show the structure it gives.
7. Push the case to Sentinel with the push button. The incident has the title, status, severity and comments. The attached alert arrives as a comment. Files, the timeline and custom field values are not sent.

Notes:
- Seeded cases use connector "none", so they are never pushed to Sentinel.
- Case templates with inline custom fields need Kibana 9.5 or later (this deployment runs 9.5.x).

## Use case 7: Close an alert in Elastic, closed in Sentinel

The problem this solves: analysts triage in Elastic, then have to log into the other portal to close or acknowledge the same alert. An Elastic Workflow (`sentinel-alert-status-sync`, deployed by Terraform) does it for them. Together with use case 5 (Sentinel to Elastic) the status stays aligned in both directions.

1. Run use case 2 so an alert and its "Elastic alert: ..." incident exist. Check the incident in Sentinel: status New.
2. In Kibana, go to Security, Alerts. Open the alert and change its status to **Acknowledged** (alert flyout, Take action, or the row menu).
3. Within about 2 minutes the Sentinel incident becomes **Active**. No one touched Sentinel.
4. Close the alert in Elastic and choose a reason (for example False positive). Within about 2 minutes the incident is **Closed** with classification False positive.
5. Show how it works: in Kibana, go to Workflows and open `sentinel-alert-status-sync`. The execution history shows a run every minute and the steps that updated the incident.
6. Optional: the same applies to alerts raised from a Sentinel incident (rule "Microsoft Sentinel Incident Raised"). The alert carries the incident id, so closing it in Elastic closes that incident.

Notes:
- The workflow runs every minute and looks at alerts changed in the last 3 minutes. It leaves an incident alone if it is already in the target state or already Closed, so it does not fight use case 5.
- It runs as an Entra app registration (`elastic-sentinel-elastic-workflows`) with the Microsoft Sentinel Responder role on the workspace. Its client secret is held in the Kibana HTTP connector "Azure Resource Manager (Sentinel workflow)" (Stack Management, Connectors), not in the workflow, so it is not visible in the workflow definition. The secret expires after 90 days; to rotate it run `terraform apply -replace=azuread_application_password.elastic_workflows`.
- A Defender or WithSecure version uses the same pattern: only the final `http` step changes (for example a PATCH to the Microsoft Graph `security/alerts_v2/{id}` endpoint, which needs the `SecurityAlert.ReadWrite.All` application permission). That version is not built here.
- Do not connect the workspace to the Defender portal. Incidents created through the Sentinel API, as use cases 1, 2 and 7 do, are not synced into the Defender incident queue.

## After the demo

- Reset for the next run: `scripts/reset-demo.sh --yes` (add `--incident` for a fresh Sentinel incident). It is a complete refresh: nothing from this run (alerts, cases, Timelines, notes, exceptions, incidents) is left to confuse the next one.
- Tear everything down: `terraform -chdir=terraform destroy` (first confirm `EC_API_KEY` is valid; see README Cost and teardown).

## If something does not work

| Symptom | Fix |
|---|---|
| Push in Kibana fails or no incident appears | A Logic App cannot call Sentinel. Open the Logic App run history (for example `elastic-sentinel-elastic-upsert-incident`) and read the failed action. A 401 or 403 means the managed identity `elastic-sentinel-logicapps-id` is missing the Microsoft Sentinel Contributor role on the workspace (role assignments can take a few minutes to apply). |
| Sentinel incident does not become a case | Check the playbook run history (Logic App `elastic-sentinel-sentinel-incident-to-elastic`) and that both automation rules are enabled (Sentinel, Automation). Both role assignments (the Sentinel automation role on the resource group and the managed identity role on the workspace) can take a few minutes to take effect. |
| No alert in Kibana | Wait 2 minutes (the rule runs every minute). Check the rule is enabled under Security, Rules. The rule needs 10 or more failures from 5 or more users in 5 minutes. |
| `run_demo.sh` says the VM is not running | Spot VMs can be evicted. Start it with `az vm start -g elastic-sentinel-rg -n elastic-sentinel-vm`. |
| No Elastic alert for the Sentinel incident | Wait up to 15 minutes. Check that the incident title does not contain "Elastic", that the rule "Microsoft Sentinel Incident Raised" is enabled (Security, Rules), that the agent is online in Fleet, and that the Event Hub export reached Elastic (use case 3). |
| The incident does not close after closing the alert | Check the workflow run history (Kibana, Workflows, `sentinel-alert-status-sync`) and that the workflow is enabled. A 401 or 403 from Sentinel means the workflow's Entra app has lost its role or its client secret expired (90 days); rotate it as described under use case 7. |
| No Event Hub data in Elastic | Wait up to 15 minutes. Check the agent is online under Fleet. |
