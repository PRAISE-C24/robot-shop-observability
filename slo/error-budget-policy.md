# Error Budget Policy: Robot Shop Availability

**Service owner:** Praise | **Version:** 1.0 | **Effective:** 3 November 2026 | **Review:** monthly

## 1. Scope

The Robot Shop storefront as users reach it through the web front end: the front page, the product catalogue and the shipping lookup.

## 2. Service level indicator (SLI)

Availability is the share of successful probe checks across three blackbox probes: the front page (`/`), the catalogue (`/api/catalogue/categories`) and shipping (`/api/shipping/codes`). The probes run every 30 seconds from inside the cluster. A check is good if it returns HTTP 2xx before the 5 second timeout.

Prometheus records this as `slo:availability:ratio_rate5m` and `slo:availability:ratio_rate1m`.

## 3. Service level objective (SLO)

**99.5% availability over a rolling 30 days.**

The error budget is the remaining 0.5% of checks, which equals about 3 hours 36 minutes of complete outage per 30 days, or about 10 hours 48 minutes if only one of the three paths is down.

## 4. What counts against the budget

- Every failed check counts, including planned maintenance and drills, so the budget reflects real user impact. An exemption needs written approval before the work starts.
- Real-traffic 5xx responses are tracked on the dashboard but are not part of the SLI, because the load generator produces a constant baseline of them. Client errors (4xx) never count.

## 5. Alerting

Burn rate is `(1 - SLI) / (1 - 0.995)`. A burn rate of 1 uses the budget exactly over 30 days.

| Alert | Condition | Response |
|---|---|---|
| Fast burn (implemented) | Burn rate above 14.4 over both 5 minutes and 1 minute, for 1 minute. This means more than 7.2% of checks failing. | Page. Acknowledge within 15 minutes and start mitigation. |
| Slow burn (planned) | Burn rate above 6 over 6 hours and 30 minutes | Ticket. Investigate within one working day. |

The lab windows are shorter than the production standard (1 hour and 5 minutes for fast burn) so that drills can be tested in minutes.

## 6. Budget status and required actions

| Budget remaining | Status | Required actions |
|---|---|---|
| More than 50% | Healthy | Normal feature work and releases. |
| 25% to 50% | Caution | Review recent incidents. Every release needs a tested rollback plan. |
| Below 25% | At risk | Reliability work and critical fixes only. No risky changes. |
| Exhausted | Frozen | Release freeze except fixes for the outage. A postmortem is required. The freeze ends when the rolling budget is positive again. |

## 7. Incident response

1. **Mitigate first.** Restore service by the fastest safe action (roll back, restart, scale, restore a dependency) before searching for the root cause.
2. **Then diagnose** using the dashboard, logs and traces, and record a timeline as you go.
3. **Postmortem.** Write a blameless postmortem within 5 working days if an incident uses more than 10% of the monthly budget, or if the budget is exhausted. Every postmortem ends with action items that have an owner and a date.

## 8. Limitations

- The probes run inside the cluster and bypass the internet-facing load balancer, so they cannot see failures between users and the load balancer.
- Only three paths are measured. Login, cart and checkout are not.
- Prometheus keeps less than 30 days of data in this lab, so budget figures use the history available until retention allows a full window.

## 9. Review

The owner reviews budget consumption monthly. Targets and thresholds are reviewed quarterly, or after any budget exhaustion.
