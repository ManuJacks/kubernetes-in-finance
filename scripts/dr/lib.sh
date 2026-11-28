#!/usr/bin/env bash
# File-wide: sourced by the phase scripts, which use these variables.
# shellcheck disable=SC2034
# Shared helpers for the DR phase scripts (docs/dr/DR-PLAN-full-platform.md).
#
# Every phase script is a DRY RUN unless it is given --execute: it prints the
# commands it would run and runs nothing that changes state. Read-only
# checks (kubectl get, status reads) run in both modes.
#
# Evidence for one exercise lives in one run directory:
#   $DR_RUNS/<run-id>/   timing.tsv, commands.log, before.json, verify.md ...
# 00-preflight.sh creates it and points $DR_RUNS/current at it.

set -euo pipefail

KIF_REPO="${KIF_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DR_RUNS="${DR_RUNS:-$HOME/.local/share/kubernetes-in-finance/dr-runs}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kubernetes-in-finance.conf}"
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$KIF_REPO/ansible/ansible.cfg}"
DR_CONTEXT="kubernetes-admin@kubernetes"
INVENTORY="$KIF_REPO/ansible/inventory/hosts.yml"

EXECUTE=0
for arg in "$@"; do
    [ "$arg" = "--execute" ] && EXECUTE=1
done

dr_log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
dr_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# The run directory of the current exercise. Created by 00-preflight.sh.
dr_run_dir() {
    if [ -n "${DR_RUN_DIR:-}" ]; then
        printf '%s\n' "$DR_RUN_DIR"
    elif [ -L "$DR_RUNS/current" ]; then
        readlink -f "$DR_RUNS/current"
    else
        dr_die "no DR run started: run scripts/dr/00-preflight.sh first"
    fi
}

dr_new_run() {
    local id
    id="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$DR_RUNS/$id"
    chmod 700 "$DR_RUNS" "$DR_RUNS/$id"
    ln -sfn "$DR_RUNS/$id" "$DR_RUNS/current"
    printf 'phase\tevent\tutc\tepoch\tstatus\n' >"$DR_RUNS/$id/timing.tsv"
    printf '%s\n' "$DR_RUNS/$id"
}

# Record a phase boundary. Only real runs are timed; dry runs say so.
dr_phase() { # <phase> <start|end> [status]
    local dir
    dir="$(dr_run_dir)"
    local mode="dry-run"
    [ "$EXECUTE" -eq 1 ] && mode="${3:-ok}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$mode" \
        >>"$dir/timing.tsv"
    dr_log "phase $1 $2${3:+ ($3)}"
}

# Run a state-changing command, or only print it in a dry run.
dr_run() {
    local dir
    dir="$(dr_run_dir)"
    if [ "$EXECUTE" -eq 1 ]; then
        printf '%s\t%s\n' "$(date -u +%H:%M:%SZ)" "$*" >>"$dir/commands.log"
        dr_log "run: $*"
        "$@"
    else
        printf '[dry-run] %s\n' "$*"
    fi
}

# Destructive phases need --execute AND the exact phrase typed by a person.
dr_confirm() { # <phrase>
    [ "$EXECUTE" -eq 1 ] || return 0
    local typed
    printf '\nThis cannot be undone. Type exactly: %s\n> ' "$1" >&2
    read -r typed </dev/tty
    [ "$typed" = "$1" ] || dr_die "confirmation did not match; nothing was changed"
}

dr_require_context() {
    local current
    current="$(kubectl config current-context 2>/dev/null || true)"
    [ "$current" = "$DR_CONTEXT" ] || dr_die "kube context is '$current', expected '$DR_CONTEXT'"
}

dr_playbook() { # <playbook name> [ansible-playbook args...]
    local pb="$1"
    shift
    dr_run ansible-playbook -i "$INVENTORY" "$KIF_REPO/ansible/playbooks/$pb" "$@"
}

# Markdown timing sheet from timing.tsv: one row per phase.
dr_timing_report() {
    python3 - "$(dr_run_dir)/timing.tsv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
start, end, status = {}, {}, {}
for r in rows:
    (start if r["event"] == "start" else end)[r["phase"]] = r
    if r["event"] == "end":
        status[r["phase"]] = r["status"]
print("| Phase | Start (UTC) | End (UTC) | Duration | Status |")
print("|---|---|---|---|---|")
for p, s in start.items():
    e = end.get(p)
    dur = f"{(int(e['epoch']) - int(s['epoch'])) // 60} min {(int(e['epoch']) - int(s['epoch'])) % 60} s" if e else "running"
    print(f"| {p} | {s['utc']} | {e['utc'] if e else ''} | {dur} | {status.get(p, s['status'])} |")
PY
}
