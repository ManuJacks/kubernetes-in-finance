# Vault recovery and rotation

Vault is an independent security control plane and must have recovery
procedures that do not depend on Kubernetes availability.

## Current recovery facts

- Integrated Raft storage: `/opt/vault/data`.
- Current deployment: single node, `kif-vault-01`.
- Shamir configuration: five shares, threshold three.
- Initial snapshot: `~/vault-backups/kif-vault-initial.snap`.
- Recovery material: KeePassXC under `KIF Infrastructure/Vault`.

The snapshot currently resides on the same host as Vault. An independent
encrypted backup and restore drill are still required.

## Rotation principles

- Revoke compromised or obsolete Vault tokens promptly.
- Rotate workload credentials by changing the source secret and allowing
  workloads to obtain a new short-lived Vault token.
- Rotate AppRole SecretIDs only for external automation that actually uses
  AppRole.
- Never place recovery shares, root tokens, SecretIDs, or secret values in Git,
  Kubernetes manifests, chat, or incident bundles.
- Preserve audit evidence for administrative rotations.

## Deferred work

Define and rehearse documented procedures for snapshot export, encrypted
off-host storage, restore into an isolated Vault instance, seal/unseal
operations, and post-restore audit verification.
