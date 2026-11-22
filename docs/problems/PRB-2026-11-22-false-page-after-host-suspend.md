# PRB-2026-11-22: API SLO pages computed from a nearly empty window after host suspend

Written with the production-debug Problem template
(`docs/procedures/PROBLEM_RECORD_TEMPLATE.md` in
[production-debug](https://github.com/ManuJacks/production-debug)).
Raised from the [alert review of 2026-11-22](../monitoring/alert-reviews/2026-11-22.md)
(proactive problem management).

| Field | Value |
|---|---|
| State | Fix in Progress (action 2 awaits an owner decision) |
| Related incident | **None.** The platform was healthy, so there was no incident to open. Severity matrix: no impact, so no INC; the defect is in the monitoring, so it is a Problem |
| Configuration item | Monitoring: Prometheus API availability burn-rate rules |
| Problem owner | Platform Engineering |
| Review date | 2026-11-22 |
| Known error | Yes: after a Prometheus data gap, one failed probe can dominate the burn-rate windows |
| Workaround | Before the fix: treat SLO pages within 30 minutes of a host resume as suspect and check the probe data |

## Summary

The monitoring host (also the lab host) woke from suspend and a single probe
failed while the VMs resumed. The burn-rate windows held almost no data, so
that one failure looked like a several-percent error rate and two pages
reached the phone at night. The platform was healthy. The rules now require
sufficient data before paging; whether the host should suspend at all is
open.

## Impact

- **Users:** none. All later probes passed; the API was serving.
- **On-call:** two urgent pages at 23:24 and 23:37 EST (about three ntfy
  notifications, zero delivery failures) for a non-event. That costs sleep
  and trust in the pager.
- **SLO reporting:** the 6.5 hours of suspended time count as neither good
  nor bad, which flatters the 30-day availability figure.

## Timeline (UTC)

| Time | Event | Source |
|---|---|---|
| 2026-11-21 21:47:39 | Host suspends (Prometheus, Alertmanager and all VMs stop) | Host journal: `PM: suspend entry (deep)` |
| 2026-11-22 04:21:06 | Host resumes | Host journal: `System returned from sleep operation 'suspend'` |
| 04:21:10 | One probe fails, via the VIP and directly to `tf-ha-control2`, as the VMs resume; every later probe passes | `probe_success` |
| 04:24 | `ApiAvailabilityFastBurn` fires (page) | `ALERTS` |
| 04:26 | Fast burn resolves | `ALERTS` |
| 04:37 | `ApiAvailabilitySlowBurn` fires (page) | `ALERTS` |
| 04:49 | Slow burn resolves | `ALERTS` |
| 06:06:15 | Host suspends again | Host journal |
| 13:27:39 | Host resumes; 74 probes in the next 13 minutes, **none failed**, no page | Host journal, `probe_success` |
| 16:34 | Alert review finds the pages were not actionable | [Alert review](../monitoring/alert-reviews/2026-11-22.md) |

**Time to detect the defect:** about 12 hours, by review, not by alert.
Nothing alerted on the monitoring gap itself.

## Root cause and contributing factors

- **Root cause:** the burn-rate rules divided by whatever samples the window
  held. After a 6.5-hour gap, the 1-hour and 5-minute windows contained only
  post-resume samples, so a single failure exceeded the 14.4× threshold
  (1.44% error rate) and stayed above it for the 2-minute `for`.
- **Contributing:** the host that runs the platform also runs its
  monitoring and suspends overnight (the second suspend-related problem in
  two days; see the
  [clock drift incident](../incidents/2026-11-21-clock-drift-after-host-suspend.md)).
- **Contributing:** nothing outside the host detects that monitoring has
  stopped (documented limitation: "Prometheus failing is not detected").
- **Why only one of two resumes paged:** paging needs both a gap *and* a
  failed probe in the first minutes. The 13:27 resume had no failure. The
  defect was intermittent, which is why only a review found it.

## Detection review

| Question | Answer |
|---|---|
| Did an alert fire? | Yes, wrongly: two SLO pages for a healthy platform |
| Right severity? | The pages were correct for a real fast burn; the defect was computing it from too little data |
| Should something else have alerted? | Yes: a monitoring gap (Prometheus or host down) should be visible from outside. Action 4 |
| Anything misleading? | The pages themselves |

## What went well / what was hard

- Went well: delivery worked end to end; the alert review traced the page
  to the host journal within minutes, using data already collected.
- Hard: the signature (one failure after a gap) does not repeat on every
  resume.
- Lucky: it happened in a lab, at night, with no other incident running.

## Action items

| # | Type | Action | Owner | Due | Delivered by | Test / evidence | Status |
|---|---|---|---|---|---|---|---|
| 1 | Prevent | Burn-rate pages require at least half the expected samples in the long window (`count_over_time` ≥ 180 per 1 h, ≥ 1080 per 6 h) | Platform Engineering | 2026-11-22 | [CHG-2026-11-22](../changes/CHG-2026-11-22-burn-rate-data-guard.md) | `promtool` regression test replaying this sequence; MTTD tests unchanged; `tests/test_monitoring.py` guards the rule | Done, pending merge |
| 2 | Prevent | Disable host suspend while the lab runs, or treat suspend as planned downtime with a silence | Lab owner | 2026-11-29 | Host configuration | No suspend entries in the journal over a week | **Open: owner decision** |
| 3 | Process | Alert quality review every two weeks; non-actionable pages must lead to a change | Platform Engineering | 2026-11-22 | [ADR-006](../decisions/ADR-006-alerting-policy.md), [alert review](../monitoring/alert-review.md) | First review 2026-11-22; next 2026-12-06 | Done |
| 4 | Detect | External dead man's switch: Alertmanager sends an always-firing heartbeat to an external service that alerts when it stops | Platform Engineering | 2026-12-06 | Future CHG | Stop Prometheus; external alert within 10 minutes | Open |
| 5 | Process | Report SLO measurement coverage (share of expected probe samples present) next to the availability figure | Platform Engineering | 2026-12-06 | Future CHG | Dashboard shows coverage < 100% for 2026-11-21/22 | Open |

## Closure criteria

Actions 1 and 3 merged; action 2 decided (either done or accepted as a risk
with the silence); actions 4 and 5 delivered or explicitly deferred with a
date.
