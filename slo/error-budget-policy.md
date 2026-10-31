# Error Budget Policy

## Availability SLO

Our target is **99.9% service availability over a rolling 30-day window**.

## Error Budget

The error budget is the remaining 0.1% of allowed unavailability.

For a 30-day period:
- Total time: 43,200 minutes
- Allowed downtime: 43.2 minutes

## Policy

- When the error budget is healthy, feature development and deployments can continue.
- When the error budget is being consumed rapidly, investigate the cause.
- When the error budget is exhausted, prioritize reliability and pause non-essential changes.
- Review availability and error-budget consumption regularly.