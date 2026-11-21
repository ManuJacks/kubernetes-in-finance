#!/usr/bin/env bash
# Summarise an api-probe.sh CSV: sample counts and every unavailability
# window, measured from the first failed sample to the next successful one.

set -euo pipefail
csv="${1:?probe CSV required}"

awk -F, '
  NR == 1 { next }
  {
    n++
    ok = ($2 == "200")
    if (ok) good++
    if (!ok && !in_outage) { in_outage = 1; start = $1; first_code = $2 }
    if (ok && in_outage) {
      in_outage = 0; w = $1 - start; windows++
      if (w > longest) longest = w
      printf "outage %d: %.1f s (first failure code %s)\n", windows, w / 1000, first_code
    }
    last = $1
    if (n == 1) first = $1
  }
  END {
    if (in_outage) {
      windows++
      printf "outage %d: still failing at end of probe (>= %.1f s)\n", windows, (last - start) / 1000
    }
    printf "samples=%d ok=%d failed=%d availability=%.2f%% duration=%.0fs outages=%d longest=%.1fs\n",
      n, good, n - good, (n ? 100 * good / n : 0), (last - first) / 1000, windows, longest / 1000
  }
' "$csv"
