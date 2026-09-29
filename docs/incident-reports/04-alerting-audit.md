# Incident 04 — Auditing the Monitoring Stack Itself

## Summary

A routine review of the existing Grafana alert rules — prompted simply by "let's check what alerts we actually have" rather than any reported problem — found that the monitoring stack had been silently non-functional in two separate, unrelated ways since it was first set up months earlier. Every rule showed "Normal"/"ok" in the Grafana UI the whole time. **A dashboard showing green is not the same as a working alerting pipeline**, and this incident is the concrete example of why.

## Finding 1 — Two RAM alert rules had bugs that made them permanently silent

Inspecting the raw PromQL behind the two "RAM > 85%" rules (one per worker) via the provisioning API:

- **Worker1's rule**: `(1-(node_memory_MemAvailable_bytes{...}/node_memory_MemTotal_bytes{...}))*0` — multiplied the percentage by **zero** instead of 100. The expression always evaluated to exactly `0`, which can never exceed the 85% threshold, no matter how much RAM was actually in use. The rule would never fire under any real-world condition.
- **Worker2's rule**: `(1-(node_memory_MemAvailable_bytes{...}/node_memory_MemTotal_bytes{...}))100` — missing the `*` operator entirely before `100`, a PromQL syntax error. This doesn't evaluate to a wrong number; it fails to evaluate at all, silently (`execErrState: Error`, but with no one watching for that error state specifically).

Both were almost certainly the result of a copy-paste error made once, months apart from when anyone would have noticed — a >85% RAM condition on a homelab server is not something that happens often enough to be immediately obvious to human observation.

**Fix**: corrected both expressions to `... * 100`. Verified by checking Grafana's live query preview showed a realistic current percentage (not `0`, not an error) before saving.

## Finding 2 — The email delivery channel itself was dead

Separately, checking Grafana's Alerting → Contact Points page directly (not just the alert rules) showed the Gmail contact point's status line: **"Last delivery attempt failed" — "username and password not accepted."** The Gmail App Password backing SMTP delivery had expired or been revoked at some point after initial setup, and — critically — **nothing in the system had ever surfaced this failure** until this contact point page was checked manually. Every alert rule could have fired correctly the entire time and no one would have received a single email.

**Fix**: generated a new Gmail App Password, updated `GF_SMTP_PASSWORD` in the monitoring stack's environment, redeployed, and — this is the step that actually matters — **sent a live test notification** via Grafana's contact-point test API and confirmed real email delivery before considering the fix complete:

```bash
curl -s --max-time 15 -X POST \
  http://localhost:3000/api/alertmanager/grafana/config/api/v1/receivers/test \
  -u admin:<password> \
  -H "Content-Type: application/json" \
  -d '{"receivers":[{"name":"<contact-point-name>", ...}], "alert":{...}}'
```

A `200` response with `"status":"ok"` from the API is not sufficient proof on its own — the actual email arriving in the actual inbox is the only real confirmation, and that's what was checked.

## Key takeaway

**"Configured" and "delivering" are not the same claim, and only one of them is worth anything during a real incident.** Both problems here — dead formulas and a dead SMTP credential — were invisible from the Grafana UI's normal "everything is Normal/green" view; both required deliberately going looking, on a day nothing was actually wrong, specifically to find out whether the safety net worked. It didn't, on two independent counts, for an unknown length of time. Every alert rule and every SMTP/contact-point change from this point forward is followed by an explicit live test, not just a visual check that the configuration "looks right."

## Verification after the fix

The corrected pipeline was validated under real conditions (not synthetic tests) during the failover testing described in [incident report 03](03-failover-testing-and-boot-races.md): a genuine "GlusterFS Heal Pending" alert fired and later auto-resolved as real heal activity occurred and then completed, and the corresponding emails were received for both the firing and resolved states — full end-to-end confirmation that alert evaluation, the notification policy, and email delivery are all actually working together, not just each looking correct in isolation.
