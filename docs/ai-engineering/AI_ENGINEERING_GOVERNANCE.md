# AI Engineering Governance

## Human Oversight, Accountability and Decision Authority

### Why human involvement is essential

AI can accelerate architecture, implementation, troubleshooting, testing and documentation. However, AI assistance does not guarantee continuity of context, correctness of reasoning, or adherence to previously approved architectural decisions.

During development of this reference architecture, an AI-assisted planning session demonstrated a practical failure mode: despite an established decision to provision a new five-node Kubernetes HA cluster using Terraform, while preserving existing virtual machines, the assistant subsequently proposed a different approach involving the existing VMs.

The human project owner identified the inconsistency and corrected the direction.

This illustrates an important principle:

**AI can contribute to engineering decisions, but it must not independently redefine the architecture, scope or approved objectives of a project.**

An AI assistant may:
- Lose track of previous decisions.
- Misinterpret or overlook project documentation.
- Introduce assumptions that have not been validated.
- Recommend technically plausible solutions that conflict with the agreed architecture.
- Confidently present an incorrect recommendation.
- Repeat unnecessary work or introduce avoidable complexity.

These risks are particularly important in financial-services environments, where infrastructure changes can affect availability, security, data integrity, regulatory obligations and business continuity.

### Human authority and AI responsibilities

| Area | AI responsibility | Human responsibility |
|---|---|---|
| Objectives | Help translate objectives into plans | Define and approve objectives |
| Architecture | Analyse options and trade-offs | Approve architectural decisions |
| Implementation | Generate and review proposed changes | Authorize consequential changes |
| Security | Identify risks and recommend controls | Accept or reject residual risk |
| Infrastructure | Propose and execute authorized automation | Approve provisioning and destructive actions |
| Testing | Generate tests and analyse evidence | Determine whether acceptance criteria are met |
| Documentation | Maintain decision and implementation records | Review and approve material changes |
| Operations | Assist with diagnosis and recovery options | Retain operational and incident authority |

### Mandatory governance controls

1. **Documented source of truth:** Approved objectives, architecture decisions, ADRs and implementation plans must be maintained in version-controlled documentation.

2. **Decision continuity:** Before proposing or implementing a material change, AI must consult the relevant project decisions and current implementation state.

3. **Conflict detection:** If a recommendation conflicts with an approved decision, AI must explicitly identify the conflict and explain the proposed deviation. It must not silently change direction.

4. **Human authorization:** Changes to architecture, scope, security boundaries, production-impacting configuration and destructive infrastructure operations require appropriate human authorization.

5. **Evidence-based validation:** Generated code and recommendations must be validated through tests, reviews and observable evidence. AI-generated confidence is not proof of correctness.

6. **Traceability:** Material AI-assisted changes should identify the originating requirement, relevant ADR, implementation evidence, reviewer and approval where applicable.

7. **Accountability:** AI is an engineering assistant, not the accountable owner of the platform. Human owners retain responsibility for decisions, risk acceptance and operational outcomes.

### Operating principle

**AI proposes. Evidence challenges. Humans authorize. Automation executes. Validation confirms.**

The objective is not to restrict AI involvement. It is to use AI productively while preserving human judgment, architectural integrity, accountability and control.

Human oversight must be an active engineering control, not a final rubber stamp.
