# Alert quality review

Every two weeks, check that each alert that fired was worth a human's
attention. The policy being enforced is
[ADR-006](../decisions/ADR-006-alerting-policy.md): a page means act now.

## Procedure (about 30 minutes)

1. Generate the table (Prometheus keeps 35 days of history):

   ```bash
   scripts/alerting/alert_review.py --days 14 > /tmp/alerts.md
   ```

   It counts *episodes* (separate firings; gaps of one or two missed
   evaluations are merged), total and longest firing time, and the affected
   targets.
2. Copy it into `docs/monitoring/alert-reviews/<date>.md` and fill in two
   columns for every row:
   - **Actionable?** Yes, if someone had to do something and did. No, if the
     right response was to ignore it. Partly, if it was real but the severity
     or timing was wrong.
   - **Action**: what changes as a result. For every page that was not
     actionable, the answer is a change: tighten the rule, lower the
     severity, add an inhibit, or delete the alert. "None" is acceptable
     only for an actionable alert.
3. Also record what *should* have alerted but did not (incidents, drills,
   things seen on the dashboard).
4. Make the changes in the same pull request as the review, each with a
   `promtool` test reproducing the case. A non-actionable page gets a
   Problem record (`docs/problems/`) and each fix a Change record
   (`docs/changes/`), using the production-debug templates.

## What to look for

| Signal | Usually means |
|---|---|
| Page that resolved by itself within minutes, with no action taken | Threshold or `for` too sensitive, or the wrong severity |
| Many episodes of the same alert | Flapping: add hysteresis or a longer `for` |
| Firing for days | Nobody owns it: fix the cause, or delete the alert |
| Same root cause across several alerts | Missing inhibit rule |
| Fired while monitoring itself had a gap | Rule computed from too little data (ADR-006 section 4) |

## Measures to track over time

- Pages per week, and the share that were actionable. Target: every page
  actionable. One non-actionable page a month is a signal, not a failure.
- Tickets open longer than a week.

## Reviews

| Date | Window | Pages | Actionable pages | Changes |
|---|---|---|---|---|
| [2026-11-22](alert-reviews/2026-11-22.md) | 3 days (baseline) | 2 | 0 | Burn-rate data guard; workload findings |
