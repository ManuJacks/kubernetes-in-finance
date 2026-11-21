# ADR-005: GitHub Actions for CI/CD and Platform Orchestration

- **Status:** Accepted — amended 2026-11-21 (validation implemented; deployment deferred)
- **Date:** 2026-11-05

## Context

The platform uses Terraform for infrastructure provisioning, Ansible for
host configuration and operational orchestration, and Helm for installing
Kubernetes platform components.

These tools provide independent, reproducible automation capabilities.
A central workflow orchestration layer is needed to coordinate validation,
approvals, deployment and post-deployment verification.

GitHub already provides source control, pull requests and change history
for the project.

The initial infrastructure runs on a private Multipass network hosted
on a Linux Mint desktop. GitHub-hosted runners cannot directly access
this private network.

## Decision

GitHub Actions will be the CI/CD workflow orchestration layer.

The responsibilities of the delivery components are:

- **GitHub:** Source control, pull requests and change history.
- **GitHub Actions:** CI validation, workflow orchestration and approval gates.
- **Terraform:** Infrastructure provisioning and lifecycle management.
- **Ansible:** Host configuration and operational orchestration.
- **Helm:** Packaging and installation of Kubernetes platform components.
- **Flux:** Continuous reconciliation of approved Kubernetes desired state.
- **Monitoring:** Deployment verification and operational visibility.

A secured self-hosted GitHub Actions runner will initially provide
workflow access to the private Multipass network.

The runner will use a dedicated, restricted identity and will be treated
as a privileged infrastructure component.

## Security and governance

- Protect workflow execution with repository permissions and branch protection.
- Require appropriate review and approval for infrastructure changes.
- Separate validation from deployment permissions.
- Use dedicated deployment identities and least privilege.
- Protect bootstrap tokens, certificate keys and other sensitive credentials.
- Prevent secrets from entering workflow logs, artifacts or source control.
- Retain traceability between source changes, approvals, deployments and validation.
- Restrict self-hosted runner access to the infrastructure it needs to manage.

## Alternatives considered

### GitHub-hosted runners

Not selected initially because the Multipass infrastructure is private
and inaccessible directly from standard GitHub-hosted runners.

This option may become appropriate if the platform moves to remotely
accessible infrastructure or a secured connectivity model is introduced.

### Manual execution from the engineering workstation

Suitable for initial platform construction and troubleshooting, but
does not provide centralized workflow execution, consistent approval
gates or durable deployment history.

### Flux as the sole automation mechanism

Not selected because Flux reconciles Kubernetes desired state but does
not replace infrastructure provisioning, host configuration, CI validation
or deployment authorization.

## Consequences

Positive:

- Centralized and repeatable delivery workflows.
- Traceability from source changes to deployment outcomes.
- Consistent approval and validation controls.
- Reuse of existing Terraform, Ansible and Helm automation.
- A clear separation between CI/CD orchestration and Kubernetes reconciliation.

Trade-offs and limitations:

- Self-hosted runners introduce an additional privileged component to secure.
- Runner availability depends initially on the local engineering host.
- The initial environment does not demonstrate independent physical
  availability or enterprise-scale CI/CD resilience.
- Workflow credentials and permissions require ongoing governance.

## Implementation scope

Implementation is deferred until the initial highly available Kubernetes
platform is operational.

Planned workflows include infrastructure provisioning, host configuration,
load-balancer deployment, Kubernetes bootstrap, Cilium installation,
node expansion and platform acceptance validation.

## Amendment (2026-11-21): validation only on a public repository

### Context

This repository is public. GitHub advises against self-hosted runners for
public repositories: a pull request from a fork can run arbitrary workflow
code on the runner. Here, the planned runner would sit inside the private
Multipass network with access to cluster-admin credentials and every node.

### Decision

1. **Implemented:** `.github/workflows/ci.yml` runs validation only, on
   GitHub-hosted runners, with read-only repository permissions:
   yamllint, ansible-lint (production profile), playbook syntax checks,
   Terraform format and validate, ShellCheck, pytest and a secret scan. It
   never connects to the cluster. Third-party actions are pinned to commit
   SHAs.
2. **Deferred:** automated deployment through a self-hosted runner. Until a
   design below is adopted, changes are applied from the engineering
   workstation with the existing playbooks, after CI passes and the change
   is reviewed.

### Preconditions before any self-hosted runner

At least one of:

- Make the repository private, accepting the loss of public visibility.
- Run deployment jobs only for protected branches through a GitHub
  Environment with required reviewers, with fork pull requests unable to
  reach the runner (for example, a separate private deployment repository
  that consumes reviewed commits from this one).

And in all cases:

- An ephemeral runner with a dedicated, least-privilege identity; no
  long-lived cluster-admin credentials on the runner host.
- Runner registration restricted to the deployment workflow only.

### Consequences

- CI gives every change the same validation without adding a privileged
  component.
- Deployment remains a manual, reviewed step; traceability relies on pull
  requests and commit history rather than workflow runs.

