# ADR-0005: No Ansible — node baseline stays a shell script (Talos is the long-term answer)

- **Status:** Accepted
- **Date:** 2026-10-15
- **Deciders:** wasim (with AI assistant review)

## Context

Phase 5 ("Infrastructure as Code") originally paired **Terraform (libvirt)** with
**Ansible** — the plan was to replace `scripts/10-prepare-nodes.sh` with Ansible
playbooks. The question raised was blunt and fair: *does this homelab actually
need Ansible, or is it a tool without a job?*

Two facts frame the decision:

1. **Kubernetes cannot do this layer.** The task (apt upgrades, kernel modules in
   `/etc/modules-load.d/`, `sysctl` in `/etc/sysctl.d/`, k3s prereqs) runs on the
   **host OS, below the cluster**. No Kubernetes/Helm/Flux object can install a
   kernel module or set host sysctl. So all three live in different layers:
   - Day 0 provisioning → Terraform
   - Day 1/2 host config → Ansible *or* a script
   - Cluster-internal → YAML/Helm/Flux

2. **This layer is already covered twice over.** `scripts/10-prepare-nodes.sh`
   is idempotent, verified, and part of the current runbooks. And the VMs are
   provisioned by the external `~/Sync/Repos/kvm-vm-provisioner`, which this
   project must not modify — so a Terraform-libvirt rewrite would be a redundant
   "alternative path," not a real gain.

Scale matters too: this is a **2-node** homelab. Ansible's advantage (managing
many hosts idempotently at once) does not materialise at n=2 — a single bash
script is faster to run and simpler to reason about.

## Decision

**Do not adopt Ansible.** Keep `scripts/10-prepare-nodes.sh` as the node
baseline. Also keep **Terraform (libvirt) deferred** — redundant with the
external provisioner.

Phase 5 is therefore re-scoped: the IaC intent is satisfied by the existing
scripts + GitOps; no new configuration-management tool is added.

## Rationale / alternatives considered

| Alternative | Verdict |
|---|---|
| **Ansible** for node baseline | ✗ At 2 nodes it adds a tool + learning curve with no bulk payoff; the layer is already scripted. |
| **Terraform** `remote-exec` / cloud-init | ✗ HashiCorp discourages provisioners for config management; cloud-init needs control of VM creation, which the external provisioner owns. |
| **Kubernetes-native node config** | ✗ Doesn't exist for mutable-OS package/module/sysctl management. |
| **Immutable OS — Talos** | ✓ The real long-term answer (in stretch goals). Removes SSH and the node-config layer entirely; pairs with the existing Flux/GitOps. |

This also matches the project's reference point: Mischa van den Burg's homelab
is now *"powered by Talos and FluxCD"* — the "fast / smooth" setup removes the
host-config layer rather than adding a tool for it.

## Consequences

**Positive**

- One fewer tool; one less thing to learn, run, and keep in sync.
- That layer is already proven (`10-prepare-nodes.sh`), so nothing regresses.
- Clear path forward: **Talos** removes this layer permanently when adopted.

**Negative**

- No Ansible exposure in this project. (Ansible remains a marketable skill and
  can be learned separately; it is easy to add back if the environment ever
  becomes a mutable-OS on-prem fleet.)

**Neutral**

- `ansible/` stays empty (and untracked — nothing to remove from git).
- `terraform/` keeps only `libvirt-k8s-net.xml` for reference.

## Revisit when

- We move to a **mutable-OS, on-prem fleet** (many VMs/bare-metal to patch and
  drift-manage) — then Ansible is the correct Day 1/2 tool.
- We adopt **Talos** — then this layer disappears and the decision is moot.
- We take control of VM provisioning (replacing the external provisioner) — then
  Terraform-libvirt becomes real instead of redundant.
