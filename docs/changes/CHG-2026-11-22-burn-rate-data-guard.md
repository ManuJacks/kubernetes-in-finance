# CHG-2026-11-22: API burn-rate pages require sufficient data

Written with the production-debug Change template
(`docs/procedures/CHANGE_REQUEST_TEMPLATE.md` in
[production-debug](https://github.com/ManuJacks/production-debug)).

| Field | Value |
|---|---|
| Type | Normal |
| Related records | [PRB-2026-11-22](../problems/PRB-2026-11-22-false-page-after-host-suspend.md), action 1 |
| Configuration item | Monitoring: `monitoring/prometheus/rules/api-availability-slo.yml` |
| Implemented by | Ansible `13-monitoring.yml` (operator on the monitoring host) |
| Risk | Moderate: changes when the platform's most important pages fire. Mitigated by keeping every existing detection test unchanged |
| Pull request | Branch `feat/metrics-server-and-dashboard` |

## Justification

A single failed probe after a Prometheus data gap paged twice for a healthy
platform (PRB-2026-11-22). Pages that are not actionable train the on-call
to ignore pages.

## Implementation

`ApiAvailabilityFastBurn` and `ApiAvailabilitySlowBurn` gain one condition
each:

```promql
and on (job, instance) count_over_time(probe_success{job="api-vip"}[1h]) >= 180   # fast burn: half of 360
and on (job, instance) count_over_time(probe_success{job="api-vip"}[6h]) >= 1080  # slow burn: half of 2160
```

Deployed with `ansible-playbook ansible/playbooks/13-monitoring.yml`.

## Test plan and evidence

- **Before:** a new `promtool` test replays the sequence (1 hour of healthy
  probes, a 2-hour gap, one failure, recovery). It fails against the old
  rules, which page.
- **After:** the same test passes (no page). The existing tests still pass
  unchanged: a full outage pages within 5 minutes (MTTD KPI), a 4-second
  failover blip does not page, slow burn and erosion fire at a steady 1%
  error rate.
- **Static guard:** `tests/test_monitoring.py` fails if either burn-rate
  rule loses its data condition.
- **In production:** on 2026-11-22 the live 1-hour sample count was 356,
  well above the 180 threshold, so normal detection is unaffected.

## Trade-off accepted

After Prometheus itself has a gap, fast-burn paging resumes once 30 minutes
of probes exist. A real outage in that window stays visible on the dashboard
(recorded in ADR-006).

## Backout plan

Revert the two conditions and redeploy with `13-monitoring.yml` (about
2 minutes). Trigger: any real outage that the burn-rate rules miss while
probe data is complete.

## Post-implementation review

| Question | Answer |
|---|---|
| Implemented as planned? | Deployed to the lab monitoring host 2026-11-22; all rules healthy |
| Success check met? | Pending: no host resume since deployment. Confirm at the next review (2026-12-06) |
| Unplanned impact? | None observed |
| Problem action item updated? | PRB-2026-11-22 action 1: done, pending merge |
