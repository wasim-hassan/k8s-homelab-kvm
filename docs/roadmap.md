# Roadmap — k8s-homelab-kvm

Forward plan for the homelab, phase by phase, with the decision points that
block each phase. This is also the **resume point** for a new session: read the
[Resume checklist](#resume-checklist) at the bottom.

- **Last updated:** 2026-10-14
- **Done so far:** Phases 0–2 (substrate, k3s cluster, operator workspace, k9s
  single pane) — see [system-inventory.md](system-inventory.md#current-phase-status).
- **Current focus:** Phase 3 (GitOps) — ✅ **decisions resolved**
  ([below](#resolved-decisions-2026-10-14)); next step is adding
  `flux`/`sops`/`age` to the workspace.

> Version numbers in this document were researched on 2026-10-13 and **will
> drift**. Re-verify the exact tag/chart version at implementation time before
> pinning. Nothing here is installed yet.

---

## Phase summary

| Phase | Theme | Status | Blocked by |
|---|---|---|---|
| 0 | Substrate (KVM, libvirt, network, VMs, SSH) | ✅ done | — |
| 1 | k3s cluster (control plane + worker, verified) | ✅ done | — |
| 2 | Operator workspace (Devpod/Podman) + observability (k9s) | ✅ done | — |
| **3** | **GitOps foundation (Flux + SOPS/age, ingress, first workload)** | ▶️ in progress | — (decisions resolved) |
| 4 | CNI migration → Cilium (+ Hubble) | 💤 skip for now | Decision 1 → **skip Cilium** |
| 5 | IaC as code (Terraform libvirt + Ansible) | ⏳ | — |
| 6 | Observability stack (Prometheus/Grafana/Alertmanager) | ⏳ | Decision 4 (sizing) |
| 7 | Security hardening (RBAC, NetworkPolicy, PSS) | ⏳ | Phase 4 for NetworkPolicy |
| 8 | CI/CD + image automation | ⏳ | Phase 3 |
| — | Stretch: Talos, storage (Longhorn), backup (Velero) | 💤 later | — |

---

## ⚠️ Sequencing note — do Cilium before GitOps

> **Resolved 2026-10-14:** Cilium is **skipped for now** (keep Flannel) to stay
> lightweight; the note below is kept for when/if that changes. See
> [Resolved decisions](#resolved-decisions-2026-10-14).

Phase 4 (Cilium) is effectively a **fresh-install-only** change: it requires k3s
started with `--flannel-backend=none` (and `--disable-network-policy`), which
means **reinstalling the control plane**. Doing it now is a trivial redo of
Phase 1 scripts against an empty cluster. Doing it *after* Phase 3 means tearing
down a cluster that already holds Flux, age keys, and workloads.

**If Cilium is ever scheduled:** run Phase 4 **before** Phase 3 for the
least-risky order.

---

## Phase 3 — GitOps foundation

**Goal:** make the cluster declaratively reproducible from git, and deploy the
first real workload.

**Deliverables**
1. **Flux CD** bootstrapped against the chosen git remote (Decision 2).
   *Researched version:* Flux **v2.9.5**.
2. **Secrets** with **SOPS + age** (FOSS, no cloud KMS). Generate an age key,
   commit the encrypted secret to git, decrypt in-cluster with
   `sops-age` / Flux `decryption` provider. (Both `sops` and `age` are currently
   **absent** from the workspace — see
   [system-inventory.md](system-inventory.md#not-yet-installed).)
3. **Ingress/Gateway controller** installed *via* Flux, superseding
   [ADR-0004](adr/0004-gateway-api-and-ingress.md) (Decision 3).
4. **First workload** deployed declaratively (e.g. a small HTTP app), exposed
   through the chosen controller, **with CPU/mem requests + limits** — this also
   fixes the `n/a` columns currently shown in k9s.

**Files it will add (planned)**
- `clusters/k8s-homelab/flux-system/` — Flux bootstrap output.
- `apps/` (or `workloads/`) — first app manifests + kustomization.
- `infrastructure/` — controllers (ingress/Gateway, later monitoring) as
  `HelmRelease`s.
- Runbook `docs/runbooks/05-gitops-flux.md` (written when Phase 3 starts).

**Why Flux first:** everything after this (Cilium via Helm, monitoring,
ingress) can then be delivered as git-managed `HelmRelease`s instead of manual
`helm install`s — reproducible and portfolio-worthy.

---

## Phase 4 — CNI migration to Cilium (skipped for now)

> **Status: not planned.** Skipped 2026-10-14 to keep the cluster lightweight
> (Flannel + k3s's built-in NetworkPolicy controller is enough for a 2-node lab).
> Revisit as a stretch if RAM grows. Kept here as a documented option.

**Goal:** replace Flannel with Cilium; enable kube-proxy replacement and Hubble.

- k3s reinstall with `--flannel-backend=none --disable-network-policy`.
- Cilium Helm: `kubeProxyReplacement=true`, `ipam.mode=kubernetes`,
  `IPAM.clusterPoolIPv4PodCIDRList="10.42.0.0/16"` (keep the existing pod CIDR
  to match [system-inventory.md](system-inventory.md#kubernetes-k3s)).
- Hubble UI for flow visibility.
- *Researched version:* Cilium **1.20.x**.

**Risk:** control-plane reinstall; kubeconfig and worker must rejoin. Mitigated
by doing it on an empty (or Flux-only) cluster.

---

## Phase 5 — Infrastructure as Code

**Goal:** stop hand-building VMs/network; make them code.

- **Terraform** (`dmacvicar/libvirt`) to provision the `k8s` network + VMs.
  *Researched version:* provider **v0.9.9**. Today `terraform/` holds only
  [`libvirt-k8s-net.xml`](../terraform/libvirt-k8s-net.xml).
- **Ansible** to replace `10-prepare-nodes.sh` (kernel modules, sysctl, k3s
  prereqs). Today `ansible/` is empty.
- Wire Terraform state/inventory into the Ansible inventory
  (`inventory/nodes.yml` is the current source of truth).

**Note:** the VMs are currently created by the external tool
`~/Sync/Repos/kvm-vm-provisioner` — this project **does not modify that repo**.
Phase 5 Terraform is an *alternative* code path, not a change to that tool.

---

## Phase 6 — Observability stack

**Goal:** metrics, dashboards, alerting — the SRE signal layer.

- `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager) via Flux
  `HelmRelease`. *Researched chart:* **91.8.2** (app v0.94.1).
- **Sizing is the blocker (Decision 4):** the cluster is only ~3 GiB total
  (2 GiB CP + 1 GiB worker). A default Prometheus will OOM the control plane.
  See [memory budget](system-inventory.md#memory-budget) for the VM bump
  procedure.

---

## Phase 7 — Security hardening

- **RBAC:** least-privilege ServiceAccounts; no cluster-admin for workloads.
- **NetworkPolicy:** pod-to-pod segmentation (needs a policy-capable CNI → after
  Phase 4).
- **Pod Security Standards** (`restricted` where possible), non-root, read-only
  root FS.
- **Secrets hygiene:** audit that only SOPS-encrypted secrets are in git.

---

## Phase 8 — CI/CD + image automation

- Build container images in CI (GitHub Actions or self-hosted runner), push to a
  registry (GHCR or self-hosted).
- **Flux image-automation** controller to bump image tags from registry to git.
- End-to-end: commit app change → CI builds → Flux deploys.

---

## Stretch (later)

- **Talos Linux** as the node OS (immutable, API-driven). Requires x86-64-v2+,
  already satisfied — see [ADR-0002](adr/0002-implicit-cpu-model.md).
- **Persistent storage:** Longhorn or tune `local-path-provisioner`.
- **Backup:** Velero for cluster/volume backup; etcd snapshots (k3s).

---

## Resolved decisions (2026-10-14)

Recorded here (in committed docs, not only the private `AGENTS.local.md`) so the
repo's memory is complete.

| # | Decision | Resolution |
|---|---|---|
| 1 | Cilium timing | **Skip Cilium for now** — keep Flannel (lightweight priority). Revisit as a stretch. |
| 2 | Git remote for Flux | **Private GitHub** — `wasim-hassan/k8s-homelab-kvm` (git init + push done). |
| 3 | Ingress / Gateway controller | **Envoy Gateway** (CNCF, Apache-2.0, Gateway API) — [ADR-0004](adr/0004-gateway-api-and-ingress.md) now **Accepted**. |

The option tables for decisions 1–3 are preserved in git history; the
resolutions above supersede them.

### Still open — Decision 4 — Observability sizing
Options in [Phase 6](#phase-6--observability-stack). Decide when Phase 6 begins:
bump VM RAM (and to what), a lightweight in-cluster stack (reduced
retention/resources or VictoriaMetrics), or defer.

---

## Resume checklist

To pick this up in a new session:

1. Start the environment — [runbook 03](runbooks/03-session-lifecycle.md)
   (`kvm on` → `vm start k8s-cp-01` → `vm start k8s-worker-01` → `devpod up . --ide none`).
2. Decisions 1–3 are **resolved** ([above](#resolved-decisions-2026-10-14));
   Decision 4 (observability sizing) is still open and only matters at Phase 6.
3. Git checkpoint is **done** — repo initialized, committed, pushed to private
   GitHub, so Flux diffs will be legible.
4. Phase 3, step 1: add `flux`/`sops`/`age` to `.devcontainer/Containerfile`,
   rebuild (`devpod up . --recreate`), generate the age key + `.sops.yaml`.
5. Then `flux bootstrap github`, install **Envoy Gateway** via Flux, deploy the
   first workload with requests/limits, and write runbook 05.

---

## References

- [Documentation index](README.md)
- [System inventory](system-inventory.md) — verified current state
- [Troubleshooting log](troubleshooting-log.md)
- [ADR-0004 — Ingress / Gateway API](adr/0004-gateway-api-and-ingress.md)
- [Runbook 03 — session lifecycle](runbooks/03-session-lifecycle.md)
