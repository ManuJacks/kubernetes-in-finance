#!/usr/bin/env python3
"""Compare two capture-state.py documents (DR phase 5).

    scripts/dr/compare-state.py <before.json> <after.json>

Prints a Markdown table and exits 1 if anything that must survive a rebuild
differs. Differences a rebuild is expected to cause are reported as NOTE,
not as failures:

- Secrets and ServiceAccounts in kube-system: kubeadm creates new bootstrap
  tokens; only counts are compared there.
- Objects created by the verification tests themselves are excluded
  (pd-guard-*, pd-reaper-test, pd-expiry-scratch namespaces).
"""

from __future__ import annotations

import json
import sys

TEST_NAMESPACES = ("pd-guard-", "pd-reaper-test", "pd-expiry-scratch", "vault-kubernetes-smoke")
COUNT_ONLY = {"secrets"}


def strip_tests(names: list[str]) -> set[str]:
    return {n for n in names if not n.split("/")[0].startswith(TEST_NAMESPACES)}


def compare(before: dict, after: dict) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []

    def row(ok: bool | None, what: str, detail: str) -> None:
        rows.append(("PASS" if ok else "NOTE" if ok is None else "FAIL", what, detail))

    for key in ("cluster_ca_pubkey_sha256", "sa_pub_sha256"):
        b, a = before["identity"].get(key), after["identity"].get(key)
        row(b == a and b is not None, f"identity: {key}", f"{(a or 'missing')[:16]}... (before {(b or 'missing')[:16]}...)")

    bn = {n["name"] for n in before["nodes"]}
    an = {n["name"]: n["ready"] for n in after["nodes"]}
    row(set(an) == bn and all(an.values()), "nodes", f"{sum(an.values())}/{len(bn)} Ready, same names: {set(an) == bn}")

    for kind, b in sorted(before["objects"].items()):
        a = after["objects"].get(kind, {"count": 0, "names": []})
        if kind in COUNT_ONLY or b["names"] is None:
            ok = a["count"] >= b["count"]
            row(True if ok else False, f"{kind} (count)", f"{a['count']} (before {b['count']}); new bootstrap tokens may add some")
            continue
        missing = sorted(strip_tests(b["names"]) - strip_tests(a["names"]))
        extra = sorted(strip_tests(a["names"]) - strip_tests(b["names"]))
        if missing:
            row(False, kind, f"missing after: {', '.join(missing[:8])}{' ...' if len(missing) > 8 else ''}")
        elif extra:
            row(None, kind, f"all {len(b['names'])} present; new: {', '.join(extra[:5])}{' ...' if len(extra) > 5 else ''}")
        else:
            row(True, kind, f"{len(b['names'])} identical")

    for key in ("debug_grants", "access_guard_rules", "grant_reaper_cronjob", "diagnosable_namespaces"):
        b, a = before["access_model"][key], after["access_model"][key]
        row(a == b, f"access model: {key}", json.dumps(a))

    v = after["vault"]
    row(v.get("sealed") is False and v.get("version") == before["vault"].get("version"),
        "vault", f"sealed={v.get('sealed')} version={v.get('version')}")
    m = after["monitoring"]
    row("error" not in m and m.get("up") == m.get("targets") and m.get("targets", 0) >= before["monitoring"].get("targets", 0),
        "monitoring targets", f"{m.get('up')}/{m.get('targets')} up (before {before['monitoring'].get('targets')})")
    return rows


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    before, after = (json.load(open(p)) for p in sys.argv[1:])
    rows = compare(before, after)
    print(f"Before {before['captured_at']}, after {after['captured_at']}.")
    print()
    print("| Result | Check | Detail |")
    print("|---|---|---|")
    for r in rows:
        print(f"| {r[0]} | {r[1]} | {r[2]} |")
    return 1 if any(r[0] == "FAIL" for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
