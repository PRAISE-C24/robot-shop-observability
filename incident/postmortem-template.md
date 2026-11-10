# Postmortem: <short title of the incident>

**Date of incident:** <YYYY-MM-DD> | **Duration:** <minutes> | **Severity:** <low / medium / high> | **Author:** <name> | **Status:** <draft / final>

This postmortem is blameless. It describes how the system and our processes allowed the failure, not who caused it.

## 1. Summary

Two or three sentences: what broke, who or what was affected, how it was fixed.

## 2. Impact

- **Who or what was affected:** <for example, catalogue and user pages for visitors>
- **Duration of user impact:** <minutes>
- **Peak symptoms:** <for example, 5xx ratio 30%, catalogue probe failing, p95 latency 5 s>
- **Error budget consumed:** see section 9.

## 3. Timeline (all times in one timezone, stated here: <UTC / local>)

| Time | Event |
|---|---|
| <hh:mm> | Failure begins (trigger) |
| <hh:mm> | First signal appears on the dashboard |
| <hh:mm> | Alert fires |
| <hh:mm> | Incident acknowledged and triage starts |
| <hh:mm> | Mitigation action taken: <what> |
| <hh:mm> | Service recovered |
| <hh:mm> | Root cause identified |

## 4. Detection

How was the incident noticed (alert, dashboard, user report)? How long after it began? Was the alert fast enough, and did it point at the right place?

## 5. Response and mitigation

What did you try, in what order, and what finally restored service? Include the commands used. Was the mitigation the fastest safe option?

## 6. Root cause

- **Trigger:** what changed or happened immediately before the failure.
- **Root cause:** the underlying reason the trigger caused harm.
- **Contributing factors:** anything that made it worse or slower to fix (missing alert, missing documentation, no health check, and so on).

Evidence: link or attach the screenshots, log lines, queries and traces that support this.

## 7. What went well, what went poorly, where we got lucky

- **Went well:**
- **Went poorly:**
- **Lucky:**

## 8. Action items

| Action | Type (prevent / detect / mitigate) | Owner | Due date | Status |
|---|---|---|---|---|
| | | | | |

Every action needs an owner and a date. Prefer a small number of specific actions over a long wish list.

## 9. Error budget impact

SLO: 99.5% over 30 days. The budget is 0.5% of 43,200 minutes, which is **216 minutes** of complete outage.

`Budget consumed (%) = impact minutes x share of probes failing / 216 x 100`

Example: 16 minutes with 1 of 3 probes failing is 16 x 0.33 / 216 x 100, which is about 2.5% of the monthly budget.

- **Impact minutes:**
- **Share of probes failing:**
- **Budget consumed:**
- **Budget status after the incident** (see the error budget policy): <healthy / caution / at risk / frozen>

## 10. Lessons learned

One or two sentences on what this incident taught about the system or the process.
