# Kubernetes in Finance

[![CI](https://github.com/ManuJacks/kubernetes-in-finance/actions/workflows/ci.yml/badge.svg)](https://github.com/ManuJacks/kubernetes-in-finance/actions/workflows/ci.yml)

## A Financial Services Platform Engineering Blueprint

A hands-on platform engineering project exploring how to design, provision,
secure, operate and validate a resilient Kubernetes platform in a
financial-services context.

The project demonstrates engineering judgement across infrastructure
automation, high availability, security, observability, operational
resilience, change governance and disaster recovery.

## Architecture

The environment is being built with Multipass, Terraform and Ansible.

- **Multipass:** local virtual infrastructure and simulated network zones.
- **Terraform:** virtual machine lifecycle management.
- **Ansible:** operating system, Kubernetes node and load-balancer configuration.
- **Kubernetes / kubeadm:** planned cluster bootstrap and orchestration.
- **HAProxy:** TCP load balancing for the Kubernetes API endpoint.
- **Keepalived:** VRRP-based high availability for the API virtual IP.
- **Cilium:** proposed cluster networking, subject to validation.
- **Flux CD:** planned GitOps reconciliation.

### Target topology

Three control-plane nodes and two worker nodes across three logical network
zones, supported by two load-balancer VMs. HAProxy forwards Kubernetes API
traffic to the control-plane nodes. Keepalived manages the shared API virtual
IP (10.97.3.100) using VRRP.

All virtual machines share one physical Linux host. The zones help explore
placement and failure-domain concepts; they are not independent physical
availability zones.

The existing load balancers are configured through Ansible. VIP failover
has been demonstrated by stopping Keepalived on the active node and
observing the standby node acquire the virtual IP. End-to-end Kubernetes
API availability and traffic forwarding remain to be validated.

See the [Platform Architecture Overview](docs/architecture/overview.md).

## Engineering Workstreams

| Area | Focus |
|---|---|
| Infrastructure | Repeatable provisioning and configuration |
| Kubernetes and HA | Cluster lifecycle, API availability and failure testing |
| Security | Least privilege, trust boundaries and secrets |
| Delivery | Controlled changes and GitOps reconciliation |
| Observability | Metrics, alerting and operational visibility |
| Recovery | Failure scenarios, recovery procedures and evidence |
| Governance | Architecture decisions, acceptance criteria and traceability |
| AI-assisted engineering | Human authorization and evidence-based validation |

## Architecture Decision Records

| Decision | Document |
|---|---|
| Infrastructure environment | [ADR-001: Multipass](docs/decisions/ADR-001-multipass.md) |
| Infrastructure automation | [ADR-002: Terraform and Ansible](docs/decisions/ADR-002-terraform-ansible.md) |
| Kubernetes bootstrap | [ADR-003: Kubernetes Bootstrap](docs/decisions/ADR-003-kubernetes-bootstrap.md) |
| Networking | [ADR-004: Networking](docs/decisions/ADR-004-networking.md) |

## Engineering Standards and Governance

- [Architecture Principles](ARCHITECTURE_PRINCIPLES.md)
- [Project Charter](PROJECT_CHARTER.md)
- [Governance Model](GOVERNANCE_MODEL.md)
- [Acceptance Criteria](docs/testing/acceptance-criteria.md)
- [Observability Strategy](docs/observability/strategy.md)
- [Alerting Policy](docs/observability/alerting-policy.md)
- [AI Engineering Governance](docs/ai-engineering/AI_ENGINEERING_GOVERNANCE.md)

## Getting Started

### Prerequisites

Linux host, Multipass, Terraform 1.6+, Ansible, SSH client and key pair.

### Provision virtual machines

From the repository root:

```bash
cd terraform
terraform init
terraform validate
terraform plan
```

Review the plan before running `terraform apply`. Terraform manages five
Kubernetes VMs through the Multipass provisioning script. The two existing
load balancers are recorded in Terraform configuration but are not managed
through its VM lifecycle. Additional load-balancer provisioning requires
an explicit configuration request.

### Configure Ansible

Return to the repository root and create a local inventory:

```bash
cd ..
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
```

Replace the example addresses with actual VM addresses and configure the
SSH private-key path. The local `hosts.yml` is excluded from version control.

### Validate connectivity and playbook syntax

From the repository root:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible -i ansible/inventory/hosts.yml kubernetes -m ping
```

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/01-common.yml --syntax-check
```

The common playbook prepares the nodes. The load-balancer playbook configures
HAProxy and Keepalived on the existing load-balancer VMs:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/02-load-balancers.yml
```

**Destructive operation warning:** `terraform destroy` deletes the five
Terraform-managed VMs through the Multipass provisioning script. Review
Terraform actions carefully before applying or destroying infrastructure.

## Project Status and Limitations

This is an evolving reference architecture. Capabilities are not considered
implemented or validated until supported by implementation evidence and
documented testing. This project does not claim production readiness or
regulatory compliance.

- All VMs share one physical host and failure domain.
- Multipass zones simulate separation; they are not physical availability zones.

- Local testing does not establish cloud-scale networking or resilience.
- Compute and memory constrain workload and monitoring capacity.
- Kubernetes bootstrap, Cilium networking and Flux reconciliation remain
  subject to implementation and validation.
- HAProxy TCP forwarding is configured, but end-to-end Kubernetes API
  availability has not yet been demonstrated.
- VRRP VIP failover has been tested between the two existing load balancers.

## Worker replacement recovery

Terraform provisions the VM, Multipass assigns its DHCP address, the Ansible
baseline installs compatible runtime/Kubernetes packages, and kubeadm join
establishes Kubernetes membership. These are separate identities and checks.

Before recovery, verify `multipass info`, the worker's current address, SSH
access, control-plane/worker versions, assigned pods, and Cilium state. Update
the ignored `ansible/inventory/hosts.yml` with the observed address; do not
reuse an old DHCP address by assumption. The VM bootstrap installs only the
existing public key (`~/.ssh/id_ed25519_k8s_finance_ansible.pub`); the private
key remains on the operator host. Set `K8S_FINANCE_SSH_PUBLIC_KEY` only when
the public key is stored elsewhere.

Run the safe baseline first:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/01-common.yml --limit tf-ha-worker2
```

If the replacement has no local `/etc/kubernetes/kubelet.conf` but the old
Node object remains, inspect its pods and persistent-storage implications. Only
after explicit human approval run the narrowly targeted replacement workflow:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/08-replace-worker.yml \
  -e replacement_worker=tf-ha-worker2 \
  -e replacement_confirmation=REMOVE_STALE_NODE
```

This removes only the selected stale Node, never drains or deletes workloads,
and stops on ambiguity. It uses a short-lived, hidden bootstrap token, revokes
it after joining, and waits for the Node to become Ready. Healthy workers are
not reset or rejoined by either join playbook. Verify Cilium pods, node
readiness, scheduling, and application networking afterward. Stop and
investigate on any version mismatch, unexpected workload, failed readiness, or
token-cleanup error. Multipass zones remain simulated failure domains on one
physical host, not independent availability zones.

## Clock synchronisation and static-pod recovery

All hosts run chrony through the `timesync` role (part of `01-common.yml`
and `02-load-balancers.yml`). The role allows chrony to step large offsets
at any time, because a desktop-host suspend pauses every VM and the Ubuntu
default only permits stepping at startup. It fails the play if a host is
more than 0.5 s from NTP. See
[the 2026-11-21 incident](docs/incidents/2026-11-21-clock-drift-after-host-suspend.md).

To correct and verify a running cluster one host at a time (preview first
with `--check --diff`):

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/11-time-sync.yml
```

If a control-plane static pod shows `CreateContainerError` with
`failed to reserve container name ... is reserved for ...` while its
container is running, recover it without stopping the container:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/12-recover-static-pod.yml \
  -e recover_target=tf-ha-control2 -e recover_component=kube-apiserver
```

The playbook refuses to act unless that exact condition is present.

## Continuous integration

Every push and pull request to `main` or `development` is validated on
GitHub-hosted runners: yamllint, ansible-lint (`production` profile),
syntax checks of every playbook, `terraform fmt` and `validate`,
ShellCheck, pytest and a secret scan. CI never connects to the cluster;
deployment stays a reviewed manual step (see
[ADR-005](docs/decisions/ADR-005-github-actions-orchestration.md)).

Run the same checks locally:

```bash
pip install "ansible-core==2.21.6" "ansible-lint==26.11.0" "yamllint==1.38.0" pytest
ansible-galaxy collection install -r ansible/requirements.yml
yamllint .
(cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-lint -c ../.ansible-lint playbooks/ roles/)
terraform -chdir=terraform fmt -check -recursive
python3 -m pytest tests
```

## Engineering Principles

- Document architectural decisions, alternatives and trade-offs.
- Automate infrastructure and configuration wherever practical.
- Design for failure, recovery and operational verification.
- Apply least privilege and explicit security boundaries.
- Treat observability as an operational requirement.
- Define measurable acceptance criteria and retain validation evidence.
- Preserve traceability between proposed changes, authorization,
  implementation and validation.
- Keep human accountability central to AI-assisted engineering.

### Human Judgment in AI-Assisted Engineering

AI can accelerate technical investigation, generate diagnostic
commands, and interpret system behaviour. However, technical
fluency does not guarantee situational awareness or sound
engineering judgment.

Effective engineering requires human oversight to:
- Maintain awareness of the overall architecture and project lifecycle.
- Challenge assumptions and recognize when an investigation is premature.
- Distinguish symptoms from root causes.
- Prioritize work according to dependencies and project objectives.
- Validate AI-generated recommendations against actual system state.

**Example from this project:** During load-balancer configuration,
AI pursued increasingly detailed HAProxy diagnostics before
recognizing that Kubernetes had not yet been initialized.
Human intervention identified the sequencing problem and
redirected the investigation.

**Engineering principle:** AI should augment engineering
judgment, not replace it.

**AI proposes. Evidence challenges. Humans authorize. Automation executes.
Validation confirms.**
