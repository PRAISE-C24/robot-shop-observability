# Robot Shop Incident Postmortem: cart down after enabling Node auto-instrumentation

Blameless review. **All times are approximate and in UTC (the local timezone is UTC+1).** The exact event times were not saved before the cluster was destroyed, so they were reconstructed from one Loki log timestamp (the crash-loop lines at 12:56:31 UTC) and from event ages seen during the incident (the first rollback about 25 minutes before the second `undo`, and the second `undo` about 4.5 minutes before those 12:56 log lines). Treat each time as plus or minus about 3 minutes.

## Incident Summary
- Incident date: 2026-11-10
- Duration: two episodes. The first ended at the first rollback, a few minutes after the change. The second lasted roughly 5 to 8 minutes, from the second `rollout undo` until the annotation was removed.
- Severity: SEV-3 (partial outage of one service in a lab environment, outside the SLO)
- Affected services: cart. Shipping and payment call cart, so checkout flows depended on it.
- Detected by: manual observation of `kubectl get pods` (CrashLoopBackOff). No alert fired.

## Impact
Cart operations (add, update, delete) were unavailable while the crashing revision was live. The front page, the catalogue and the shipping codes kept answering, so the availability SLO did not move: cart is not one of the three probed paths. The traffic gap was small because the load generator kept running against the other services.

## Timeline
| Time | Event |
|---|---|
| about 12:22 to 12:27 (T0) | Added the `instrumentation.opentelemetry.io/inject-nodejs: "true"` annotation to the cart Deployment with `kubectl patch`, to extend tracing beyond `shipping`. The operator injects the agent when a pod is created, so a new cart pod started with it. |
| T0 plus seconds | The new cart pod went into CrashLoopBackOff while the old pod terminated. |
| about 12:25 to 12:27 (T1) | Noticed the CrashLoopBackOff in the `kubectl get pods` output. |
| about 12:27 (T2) | `kubectl rollout undo deployment/cart` restored the previous revision. Service recovered. |
| about 12:52 (T3, about 25 minutes after T2) | `rollout undo` was run a second time. It flips between the last two revisions, so it redeployed the instrumented, crashing revision and killed a healthy pod. |
| about 12:56 (T4) | Diagnosed from Loki: the crashed pod's logs showed a stack trace through the injected agent (`/otel-auto-instrumentation-nodejs/.../import-in-the-middle`) and old-style `internal/modules/cjs/loader.js` frames. |
| about 12:57 to 13:00 (T5) | Removed the annotation with a JSON patch. Pod `cart-574cbb5d97-...` came up 1/1 Running. |
| about 13:00 (T6) | Confirmed the shop and the load generator were healthy. Decided not to instrument the Node services. |

## Root Cause
**Direct cause:** the auto-instrumentation agent injected into the cart pod crashed at startup.

**Most likely reason:** the shop's cart image runs an old Node.js runtime that the current agent cannot load. The `internal/modules/cjs/loader.js` frames (newer Node prints `node:internal/...`) point that way. Observed: the cart container runs Node v14.17.5 (`kubectl -n robot-shop exec deploy/cart -- node --version`). The incompatibility with the agent is still an inference from the stack trace, not something the agent reported directly.

**Contributing causes:**
1. The change went straight to the live shop without checking the image's runtime version.
2. The recovery advice ("run `rollout undo`") did not say that `undo` toggles between two revisions, and running it twice reintroduced the fault.
3. Nothing watched cart: the SLI probes the front page, the catalogue and shipping only.

## Resolution
Removed the annotation from the Deployment's pod template, which restored the original revision. One instrumented service (`shipping`, Java) already meets the tracing goal, so the cart annotation is not added to `scripts/install.sh`.

## Lessons Learned
**What went well**
- The first rollback restored service quickly.
- Fluent Bit had already shipped the crashed pod's logs to Loki, so the failure was readable after the pod was gone.
- Rollout history and events gave a clear record of what changed and when.

**What went wrong**
- No alert: a cart outage is invisible to the availability SLO.
- The stack-trace lines carried `level=unknown`, so a `level="error"` search missed them.
- The runbook's first action was ambiguous about `rollout undo`.
- A change was made to a running service without a compatibility check.

**Where we were lucky:** the failing service was outside the probed paths and this is a lab, so no user-facing SLO budget was spent.

## Action Items
| Action | Owner | Priority | Status |
|---|---|---|---|
| Add a cart probe (`/api/cart/metrics` through `web`) to the blackbox targets and include it in the SLO rules and policy | Service owner | High | Open |
| Runbook: replace the `rollout undo` guidance with `rollout history` plus `--to-revision`, or undo the change itself; warn that running `undo` twice flips back | Service owner | High | Open |
| Fluent Bit: give stack-trace continuation lines the level of the line before them, or document searching `level=~"error\|unknown"` | Service owner | Medium | Open |
| Confirm the Node runtime version in the cart pod (v14.17.5) | Service owner | Medium | Done |
| Save `kubectl get events`, rollout history and the relevant Loki output to the repo during an incident (events expire after about an hour and everything vanishes with the cluster) | Service owner | Medium | Open |
| Check an image's runtime version before enabling auto-instrumentation on it | Service owner | Low | Done (Node services are not instrumented) |
| Keep the cart annotation out of `scripts/install.sh` | Service owner | Low | Done |
