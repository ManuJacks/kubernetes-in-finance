"""Static checks for the monitoring stack (roles/monitoring, monitoring/)."""

import json
import os
import re

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MON = os.path.join(ROOT, "monitoring")
ROLE = os.path.join(ROOT, "ansible", "roles", "monitoring")


def read(*parts):
    with open(os.path.join(*parts)) as f:
        return f.read()


def recorded_names():
    names = set()
    rules_dir = os.path.join(MON, "prometheus", "rules")
    for fname in os.listdir(rules_dir):
        for group in yaml.safe_load(read(rules_dir, fname))["groups"]:
            for rule in group["rules"]:
                if "record" in rule:
                    names.add(rule["record"])
    return names


def test_dashboard_queries_reference_defined_recording_rules():
    """A typo in a recording-rule name would silently show 'No data'."""
    dashboard = json.loads(read(MON, "grafana", "dashboards", "platform-reliability.json"))
    recorded = recorded_names()
    for panel in dashboard["panels"]:
        for target in panel.get("targets", []):
            for name in re.findall(r"\b(?:sli|slo|etcd_backup|platform_drill):[a-z0-9_:]+", target["expr"]):
                assert name in recorded, f"panel {panel['title']!r} uses unknown rule {name}"
            assert target["datasource"]["uid"] == "prometheus"


def test_dashboard_datasource_matches_provisioning():
    ds = yaml.safe_load(read(MON, "grafana", "provisioning", "datasources", "prometheus.yml"))
    assert ds["datasources"][0]["uid"] == "prometheus"


def test_every_listener_is_localhost_only():
    compose = read(ROLE, "templates", "docker-compose.yml.j2")
    assert "ports:" not in compose, "host networking only; no published ports"
    for flag in re.findall(r"listen-address=([^\s]+)", compose):
        assert flag.startswith("127.0.0.1:"), flag
    assert "GF_SERVER_HTTP_ADDR: 127.0.0.1" in compose
    assert 'GF_AUTH_ANONYMOUS_ENABLED: "false"' in compose


def test_images_pinned_by_digest_and_memory_limited():
    defaults = yaml.safe_load(read(ROLE, "defaults", "main.yml"))
    for name, image in defaults["monitoring_images"].items():
        assert re.search(r":[\w.-]+@sha256:[0-9a-f]{64}$", image), f"{name} not pinned: {image}"
    compose = read(ROLE, "templates", "docker-compose.yml.j2")
    services = yaml.safe_load(re.sub(r"\{\{[^}]+\}\}", "x", compose))["services"]
    for name, svc in services.items():
        assert "mem_limit" in svc, f"{name} has no memory limit"


def test_backup_store_mounted_read_only_and_collector_offline():
    compose = read(ROLE, "templates", "docker-compose.yml.j2")
    assert "{{ monitoring_backup_dir }}:/backups:ro" in compose
    collector = compose.split("etcd-backup-collector:", 1)[1].split("\n\n", 1)[0]
    assert "network_mode: none" in collector


def test_grafana_password_not_in_repository():
    tasks = read(ROLE, "tasks", "main.yml")
    assert "lookup('ansible.builtin.password'" in tasks
    assert "secrets/grafana-admin-password" in tasks
    assert "no_log: true" in tasks


def test_alertmanager_webhook_urls_are_not_in_the_repository():
    """The ntfy topic is a credential: only url_file may be used."""
    config = yaml.safe_load(read(MON, "alertmanager", "alertmanager.yml"))
    for receiver in config["receivers"]:
        for hook in receiver.get("webhook_configs", []):
            assert "url" not in hook, receiver["name"]
            assert hook["url_file"].startswith("/etc/alertmanager/secrets/")
    assert "ntfy.sh/" not in read(MON, "alertmanager", "alertmanager.yml")


def test_every_alert_has_a_routable_severity():
    """Alertmanager routes on severity; an unlabelled alert would only reach the default."""
    rules_dir = os.path.join(MON, "prometheus", "rules")
    for fname in os.listdir(rules_dir):
        for group in yaml.safe_load(read(rules_dir, fname))["groups"]:
            for rule in group["rules"]:
                if "alert" in rule:
                    assert rule["labels"]["severity"] in {"page", "ticket"}, rule["alert"]
                    assert rule["annotations"].get("runbook"), rule["alert"]


def test_backup_status_is_recorded_on_every_exit():
    script = read(ROOT, "ansible", "roles", "etcd-backup", "templates", "etcd-backup.sh.j2")
    assert "trap write_status EXIT" in script
    # The status trap must be installed before any step that can fail.
    assert script.index("trap write_status EXIT") < script.index("mountpoint -q")


def test_drill_timer_runs_the_drill_script():
    service = read(ROLE, "templates", "kif-restore-drill.service.j2")
    assert "scripts/drills/etcd-restore-drill.sh" in service
    assert "OnCalendar={{ monitoring_drill_schedule }}" in read(ROLE, "templates", "kif-restore-drill.timer.j2")


def alert_rules():
    rules_dir = os.path.join(MON, "prometheus", "rules")
    alerts = {}
    for fname in sorted(os.listdir(rules_dir)):
        for group in yaml.safe_load(read(rules_dir, fname))["groups"]:
            for rule in group["rules"]:
                if "alert" in rule:
                    alerts[rule["alert"]] = rule
    return alerts


def test_every_alert_has_a_runbook_that_exists():
    for name, rule in alert_rules().items():
        runbook = rule.get("annotations", {}).get("runbook")
        assert runbook, f"{name} has no runbook annotation"
        assert os.path.isfile(os.path.join(ROOT, runbook)), f"{name}: runbook {runbook} does not exist"


def test_every_alert_has_a_promtool_test_that_fires_it():
    """ADR-006: an alert nobody has seen fire may never fire."""
    tests = yaml.safe_load(read(MON, "prometheus", "tests", "rules.test.yml"))
    fired = {
        case["alertname"]
        for group in tests["tests"]
        for case in group.get("alert_rule_test", [])
        if case.get("exp_alerts")
    }
    missing = sorted(set(alert_rules()) - fired)
    assert not missing, f"alerts without a firing test: {missing}"


def test_adr_alert_inventory_matches_the_rules():
    """The severity policy (ADR-006) and the rules must not drift apart."""
    adr = read(ROOT, "docs", "decisions", "ADR-006-alerting-policy.md")
    inventory = dict(re.findall(r"^\| `(\w+)` \| (page|ticket) \|", adr, re.MULTILINE))
    actual = {name: rule["labels"]["severity"] for name, rule in alert_rules().items()}
    assert inventory == actual


def test_burn_rate_pages_require_sufficient_data():
    """Alert review 2026-11-22: a scrape gap made one failed probe page."""
    alerts = alert_rules()
    for name in ("ApiAvailabilityFastBurn", "ApiAvailabilitySlowBurn"):
        assert "count_over_time(probe_success" in alerts[name]["expr"], name


def load_alert_review():
    import importlib.util

    path = os.path.join(ROOT, "scripts", "alerting", "alert_review.py")
    spec = importlib.util.spec_from_file_location("alert_review", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_alert_review_merges_missed_evaluations_but_splits_real_gaps():
    review = load_alert_review()
    # 0..120 continuous, one missed sample at 180, then a real gap until 600.
    samples = [0, 60, 120, 240, 600, 660]
    assert review.episodes(samples) == [(0, 300), (600, 720)]


def test_alert_review_summarises_per_alert_and_severity():
    review = load_alert_review()
    series = {
        (("alertname", "KubeNodeNotReady"), ("node", "w1"), ("severity", "page")): [0, 60, 120],
        (("alertname", "KubeNodeNotReady"), ("node", "w2"), ("severity", "page")): [1000],
    }
    row = review.summarise(series)[("KubeNodeNotReady", "page")]
    assert row["episodes"] == 2
    assert row["seconds"] == 180 + 60
    assert row["targets"] == {"w1", "w2"}
