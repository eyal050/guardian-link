# Failure Scenarios — The Break/Debug Catalog

This is the most important document in the repo. The point of this whole project is not the build; it is what happens after the build works.

## How to use this document

There are two modes:

### Mode A: "Break failure #N"
You tell Claude Code: *"Break failure #3."* Claude Code:
1. Reads the scenario.
2. Introduces the specified fault.
3. Tells you it is done. Does NOT tell you what it changed.
4. Records what it did in `scripts/.failure-state/current.md` (gitignored).

You then debug. When you think you've found it, you say: *"What was the fault?"* Claude Code reads the state file and tells you, then helps you assess whether you found the real root cause or just a symptom.

### Mode B: "Break a random one"
You tell Claude Code: *"Break a random failure, don't tell me which."* Claude Code:
1. Picks one from the catalog below (ideally one you haven't done recently — Claude Code should track this in `scripts/.failure-state/history.md`).
2. Introduces it.
3. Records it in `scripts/.failure-state/current.md`.
4. Tells you ONLY that it is done.

You debug blind. When done, reveal the state file.

### Rules of the game (for Claude Code)

- NEVER reveal the active failure in chat. Write it to the state file only.
- NEVER add comments in committed code that hint at the injected fault ("# bug: swallow exception").
- The fault must be plausible — the kind of thing that happens in real systems, not a contrived mess.
- Prefer faults that manifest as *symptoms distant from the cause*. That's the interview skill.
- After the user identifies the root cause, do a short post-mortem together: what signals would have caught it faster? Is there a test or alert worth adding?
- Revert cleanly. Keep a `revert.sh` per failure if the change is non-trivial.

### Rules of the game (for the user)

- Time yourself. Write down the timestamp when you start debugging. Write it down again when you find the cause.
- Do not read code diffs first. Start from symptoms (alerts, dashboards, logs).
- Keep a debugging journal. What did you check? What threw you off? What would have caught it sooner?

---

## The catalog

Numbering is stable — do not renumber. Add new ones at the end.

### #1 — Silent notification drop

**Scenario:** Crash events are correctly classified and logged, but the notifier function swallows exceptions on SendGrid 5xx responses. From the outside everything looks healthy. Dashboards show "crash_confirmed" events being emitted. But `notification_sent` custom event count diverges from `crash_confirmed` count.

**Implementation hint for Claude Code:**
- Wrap the SendGrid call in `try/except Exception: pass` instead of the correct handling.
- Do not log the exception.
- Make sure the SMS path still works so the symptom is "some notifications are silently dropped," not a full outage.

**What "finding the root cause" looks like:**
- User notices the `crash_confirmed` vs `notification_sent` divergence.
- Traces a specific event ID through App Insights.
- Sees the notifier invocation completed "successfully" but has no downstream SendGrid dependency call.
- Locates the bare `except`.

---

### #2 — Cosmos partition hot spot

**Scenario:** Under simulated load, the telemetry writer starts seeing 429s, latency climbs, and cost goes up. Cause: someone "optimized" the partition key to `/eventType` instead of `/deviceId`, so 95% of writes go to one partition.

**Implementation hint for Claude Code:**
- Change the partition key in the Terraform definition AND migrate (create a new container, point the writer at it).
- Or, if already deployed, just change the writer code to write all new documents with the same partition value.
- Ramp the simulator to make the symptom show up within 10 minutes.

**What "finding the root cause" looks like:**
- User sees 429s / throttles in Cosmos metrics.
- Pulls up partition-level metrics in the Azure portal or via Kusto.
- Identifies single-partition saturation.
- Finds the offending partition key choice.

---

### #3 — Cascading failure from Postgres

**Scenario:** PostgreSQL is intentionally made unreachable (firewall rule flipped, or server stopped). The notifier can no longer look up emergency contacts. It retries. Retries exhaust the function's concurrent execution budget. The crash classifier starts failing too because it shares a Function App plan. Telemetry writer starts lagging.

**Implementation hint for Claude Code:**
- Simplest: flip a Postgres firewall rule to deny the Function subnet.
- Better: use an Azure CLI command to stop the Postgres server (realistic failure mode).
- Don't crash the Function Apps themselves.

**What "finding the root cause" looks like:**
- User sees notification failure alert first.
- Investigates and sees Postgres unreachable.
- Then notices the blast radius: classifier latency is also up, telemetry writer queue is growing.
- Realizes the shared Function App plan is the structural problem.
- Post-mortem: should these be on separate plans? Should the notifier have a circuit breaker?

---

### #4 — Bad deploy with silent regression

**Scenario:** A new version of the crash classifier is deployed. It works. But it now returns `confidence` as a string ("0.95") instead of a float. The notifier parses it as `float(confidence)` which still works... until it doesn't, because occasionally the ML stub returns `"nan"` which becomes `float('nan')` which then fails the `confidence > 0.8` comparison silently (all comparisons with NaN are False).

**Implementation hint for Claude Code:**
- Deploy via the normal pipeline so the release annotation shows up in App Insights.
- Make the regression subtle — a percentage of notifications are dropped, not all of them.

**What "finding the root cause" looks like:**
- User sees notification rate dropped around deploy time.
- Correlates with release annotation in App Insights.
- Does NOT immediately roll back (anti-pattern — they should first understand).
- Finds the type mismatch by examining actual event payloads.

---

### #5 — Key Vault rotation breaks everything

**Scenario:** The SendGrid API key is rotated in Key Vault. The notifier function has the old key cached in memory (app setting resolved at startup). Until the function restarts, notifications fail. After an auto-restart, works again. Intermittent.

**Implementation hint for Claude Code:**
- Add a new version of the Key Vault secret.
- Ensure the Function App reference is `@Microsoft.KeyVault(SecretUri=...)` without a version pin (or with one — discuss which is worse).
- Or: change the RBAC on Key Vault so the function's managed identity loses access.

**What "finding the root cause" looks like:**
- User sees 401s from SendGrid in function logs.
- Checks Key Vault access logs — sees denied access OR sees successful access but stale cached secret.
- Realizes the pattern: failures correlate with function instance age, not wall-clock time.

---

### #6 — Poison message jams the pipeline

**Scenario:** The device simulator occasionally sends a malformed telemetry message (missing required field, or binary junk). The telemetry writer function crashes on it. The message goes back on the queue. The function picks it up again. Crashes again. Until max delivery count, the queue depth grows and legitimate telemetry falls behind.

**Implementation hint for Claude Code:**
- Modify the simulator to occasionally emit a malformed message.
- Make sure the writer function has no dead-letter configuration, OR the DLQ is configured but no one is watching it.

**What "finding the root cause" looks like:**
- User sees growing queue depth / lag metric.
- Dives into function logs, sees the same error repeated for the same message ID.
- Pulls the poison message from the DLQ (if configured) or from logs.
- Post-mortem: DLQ should exist AND have an alert on it.

---

### #7 — Cost explosion overnight

**Scenario:** Someone (Claude Code, the user, or a script) accidentally cranked the simulator from 10 devices at 1 Hz to 10,000 devices at 10 Hz. Cosmos autoscales to its max. Log Analytics ingestion balloons. Azure budget alert fires — 12 hours later, after €80 of damage.

**Implementation hint for Claude Code:**
- Actually change the simulator config. Leave it running for 30 min to produce a real cost signal.
- Or: simulate by generating the metrics/logs without the real cost (cheaper for practice).

**What "finding the root cause" looks like:**
- User sees the budget alert.
- Goes to Cost Management, breaks cost down by resource.
- Identifies Cosmos and Log Analytics as the top line items.
- Correlates to the simulator config change.
- Post-mortem: budget alerts at lower thresholds; Cosmos max RU cap; Log Analytics daily cap.

---

### #8 — Wrong thing in the right place (auth misconfiguration)

**Scenario:** The user-api accepts requests. JWT validation is configured in API Management. But the APIM policy validates against the wrong tenant / wrong audience, so it is effectively rubber-stamping any reasonably-shaped JWT. No security incident yet, but a pen test would find it in five minutes.

**Implementation hint for Claude Code:**
- Change the `<validate-jwt>` policy's `<audiences>` value to something permissive or wrong.
- Symptoms are non-existent — this one requires the user to *notice* it through code review or by running a deliberate test, not to debug from an alert.

**What "finding the root cause" looks like:**
- This one is different — it tests *proactive* security review skills.
- User should be practicing writing a test that sends a JWT signed by a different tenant and expecting a 401.
- Finding this without the prompt to look for it is the real skill.

---

## State file format

`scripts/.failure-state/current.md`:
```
Failure number: #N
Injected at: 2026-04-23T14:32:00Z
Description: <one line>
Files changed:
  - path/to/file.py (lines X-Y)
  - infra/module.tf (resource Z)
Expected symptoms:
  - <symptom 1>
  - <symptom 2>
How to revert:
  - <command or steps>
```

`scripts/.failure-state/history.md`: append-only log of past injections and how long they took the user to debug.
