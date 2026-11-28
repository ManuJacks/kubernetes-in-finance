#!/usr/bin/env bash
# DR phase 5: verify (DR plan phase 5). Read-only apart from the scripted
# tests, which create and remove their own temporary objects.
#
#   scripts/dr/60-verify.sh [--before <before.json>]
#
# "Recovered" means the same as before: captures after.json with the same
# collector as phase 0 and compares, then runs every scripted test. Writes
# verify.md and timing.md into the run directory. Exit 0 only if all pass.
# Also useful on a healthy cluster: compare it with itself to prove the
# checks are sound before the exercise.
# shellcheck source=scripts/dr/lib.sh
. "$(dirname "$0")/lib.sh"
# Read-only phase: it always runs, so it is always timed as a real phase.
EXECUTE=1

RUN="$(dr_run_dir)"
BEFORE="$RUN/before.json"
[ "${1:-}" = "--before" ] && BEFORE="$2"
PD_REPO="${PD_REPO:-$HOME/Code/production-debug}"
REPORT="$RUN/verify.md"
failed=0

dr_phase 5-verify start
python3 "$KIF_REPO/scripts/dr/capture-state.py" "$RUN/after.json"
{
    echo "# DR verification $(date -u +%FT%TZ)"
    echo
    python3 "$KIF_REPO/scripts/dr/compare-state.py" "$BEFORE" "$RUN/after.json" || failed=1
    echo
    echo "| Result | Scripted test |"
    echo "|---|---|"
} >"$REPORT"

test_row() { # <name> <command...>
    local name="$1" log
    shift
    log="$RUN/test-$(echo "$name" | tr -c 'a-z0-9' '-').log"
    if "$@" >"$log" 2>&1; then
        echo "| PASS | $name |" >>"$REPORT"
    else
        echo "| FAIL | $name (see $(basename "$log")) |" >>"$REPORT"
        failed=1
    fi
}
test_row "Admission guard, 27 live cases" bash "$PD_REPO/scripts/test-access-guard.sh" "$DR_CONTEXT"
test_row "Grant reaper live test" bash "$PD_REPO/scripts/test-grant-reaper.sh" "$DR_CONTEXT"
test_row "Vault Kubernetes login (200 / 403)" env VAULT_INTERNAL_CA_FILE=/usr/local/share/ca-certificates/kif-internal-root-ca.crt \
    bash "$KIF_REPO/scripts/vault-kubernetes-smoke-test.sh"
test_row "API through the VIP" kubectl get --raw /readyz

dr_phase 5-verify end
dr_timing_report >"$RUN/timing.md"
cat "$REPORT"
echo
cat "$RUN/timing.md"
if [ "$failed" -eq 0 ]; then echo "RECOVERED: every check passed."; else echo "NOT RECOVERED: see FAIL rows."; fi
exit "$failed"
