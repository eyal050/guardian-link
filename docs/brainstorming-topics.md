# Brainstorming Topics — Decisions to Make Before Building

These are deliberately left open. Claude Code should NOT decide these silently. For each, have a discussion, pick a direction, write the decision + one-sentence rationale into `docs/architecture.md` under "Decisions already made."

An interviewer will almost certainly ask "why did you choose X?" for several of these. If your answer is "Claude Code picked it," you're done.

---

## 1. Eventing backbone: Event Grid vs. Event Hubs vs. Service Bus

**The question:** You have three distinct event patterns:
- High-volume telemetry (potentially millions of messages/day per device fleet)
- Low-volume crash events that MUST be delivered (life-safety)
- Lifecycle events (device paired, user created)

Do you use one backbone, two, or three?

**Tradeoffs to reason about:**
- Event Hubs: best for telemetry, supports replay, consumer-group model. Pull-based (Functions need an Event Hub trigger, not as elegant).
- Service Bus: at-least-once, DLQ, ordering, session support. Right answer for crash notifications (you CANNOT drop these).
- Event Grid: cheap, reactive, push-based. Perfect for lifecycle events.
- Multi-backbone = more operational surface, but each tool does one thing well.

**Strong opinion to consider:** For this product's scope, **Event Hubs for telemetry + Service Bus for the crash pipeline**. Skip Event Grid; not worth the extra surface. Defend this if asked.

---

## 2. Cosmos DB partition key

Telemetry documents look something like:
```json
{
  "deviceId": "dev-abc-123",
  "userId": "user-456",
  "timestamp": "2026-04-23T14:32:00Z",
  "eventType": "telemetry|crash_suspect|heartbeat",
  "payload": { ... }
}
```

**Candidates:**
- `/deviceId` — simple, but one very-active device can hot-spot.
- `/userId` — wrong; users can have multiple devices, weird skew.
- `/deviceId` + synthetic suffix (e.g., `deviceId_yyyyMM`) — distributes a single device's writes over time.
- Hierarchical partition keys (new Cosmos feature) — `[tenantId, deviceId]` for multi-tenant.

**Access patterns to think about first:**
- "Get last 5 min of telemetry for device X" — needs efficient read by deviceId + time range.
- "Find all crash events in the last hour across all devices" — cross-partition, expensive. Might belong elsewhere (separate container? blob index?).

**Don't pick until you've written down the top 3 read patterns.**

---

## 3. Functions vs. Container Apps

The JD names Functions explicitly. Functions are the default. But Container Apps give you:
- Full control over runtime/dependencies (matters for the ML stub — scipy, torch, etc.).
- Longer-running workloads without the 10-minute limit.
- KEDA-based scaling on any metric.

**Open question:** Is there any component that CAN'T be a Function? The ML stub is the obvious one. The notifier *could* be either. The telemetry writer should be a Function.

**Decision to make:** Which components are Functions, which are Container Apps, and why? Pick deliberately.

---

## 4. Sync vs. async on the notification path

When a crash is confirmed, do you:
- **(a)** Return the notification result synchronously to the mobile app? (Low latency feedback to user, tight coupling, failure modes are user-visible.)
- **(b)** Fire-and-forget to a Service Bus queue, return immediately, notifier processes async? (Decoupled, resilient to downstream failures, but user gets no "notifications sent" confirmation without polling.)

For a **life-safety product**, the user (or the user's phone) needs to know notifications actually went out. What's your design?

**Strong opinion:** Hybrid. Fire to queue for resilience, but write a status record to Cosmos that the mobile app can poll or subscribe to via SignalR. Don't block the mobile app on SendGrid.

---

## 5. PII and GDPR — where does sensitive data actually live?

The system has:
- User name, email, phone → Postgres.
- Emergency contact name, email, phone → Postgres.
- Device-to-user mapping → Postgres.
- Raw telemetry (could be GPS-traceable to a person) → Cosmos + Blob.
- Crash events (definitely PII-adjacent) → Cosmos + Blob.

**Questions:**
- Do you separate PII into its own storage account / database with stricter access?
- How do you implement "right to erasure" when telemetry is in hot storage, cold storage, and archive? (Hint: real answer involves a deletion log, tombstoning, and tracking down every copy.)
- GPS in telemetry is PII. Do you tokenize the device ID in telemetry so telemetry storage doesn't have user linkage, and only the user-api can resolve device-to-user?

This is the stuff that separates "I've heard of GDPR" from "I've implemented GDPR." You don't need to build it all, but have a position.

---

## 6. Environment strategy and cost

You probably should NOT build full dev + prod for this exercise. Options:
- **One env ("dev"), destroy-and-recreate daily.** Cheap, forces IaC discipline.
- **Two envs, prod sized down to match dev.** Practices the pipeline but doubles the cost.
- **One env, but with per-feature branches using Terraform workspaces.** Interesting for talking about, but honestly overkill.

**Recommendation:** One env, destroy nightly (or at minimum after each practice session), recreate via `terraform apply` in the morning. IoT Hub and Cosmos DB state lost each time — fine, the simulator regenerates data.

---

## 7. Testing strategy

What do you test, at what level?
- Terraform: `tflint`, `tfsec`, plan-must-succeed.
- Function unit tests: pytest, mocked Azure SDK.
- Integration tests: actually call deployed endpoints. Run post-deploy in pipeline.
- End-to-end: simulator emits a fake crash, assertion: notification hits a test inbox.

**Strong opinion:** At least one real end-to-end test that runs in the pipeline against a dev env. Everything else is optional for a prep project. Interviewers love "I wrote a test that sends a fake crash to IoT Hub and asserts an email arrives in a test mailbox within 10 seconds."

---

## 8. What about multi-region, DR, and backup?

Don't build it. Do have opinions:
- RPO/RTO for crash event data? (I'd argue RPO = 0 for confirmed crashes.)
- Cosmos multi-region write vs. read replicas?
- Postgres geo-redundant backup?
- APIM multi-region — that's a Premium-tier feature, real cost.

Be ready to whiteboard this. Do not spend prep time implementing it.
