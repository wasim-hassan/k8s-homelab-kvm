# Roadmap — k8s-homelab-kvm

Forward plan for the homelab, phase by phase, with the decision points that
block each phase. This is also the **resume point** for a new session: read the
[Resume checklist](#resume-checklist) at the bottom.

- **Last updated:** 2026-10-15
- **Done so far:** Phases 0–3 (substrate, k3s cluster, operator workspace + k9s,
  GitOps: Flux CD + SOPS/age, Envoy Gateway, first workload) — see
  [system-inventory.md](system-inventory.md#current-phase-status).
- **Current focus:** Phase 3 (GitOps) — ✅ **complete** 2026-10-15. Flux CD
  bootstrapped (deploy key), SOPS/age decryption wired, Envoy Gateway installed
  via Flux, and the first workload (podinfo) deployed with requests/limits and an
  encrypted Secret. Next: Phase 6 (Observability) — resolve
  [Decision 4](#still-open--decision-4--observability-sizing) (sizing) first; Phase 5 (IaC)
  remains a parallel option.

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
| **3** | **GitOps foundation (Flux + SOPS/age, ingress, first workload)** | ✅ done | — |
| 4 | CNI migration → Cilium (+ Hubble) | 💤 skip for now | Decision 1 → **skip Cilium** |
| 5 | IaC as code (Terraform libvirt + Ansible) | ⏳ | — |
| 6 | Observability stack (Prometheus/Grafana/Alertmanager) | ⏳ | Decision 4 (sizing) |
| 7 | Security hardening (RBAC, NetworkPolicy, PSS) | ⏳ | Phase 4 for NetworkPolicy |
| 8 | CI/CD + image automation | ⏳ | — (Phase 3 done) |
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

> **Status: ✅ complete (2026-10-15).** Implemented in
> [`clusters/k8s-homelab/`](../clusters/k8s-homelab) (app-of-apps),
> [`infrastructure/`](../infrastructure) (Envoy Gateway) and
> [`apps/`](../apps) (podinfo). Procedure + verification:
> [runbook 05](runbooks/05-gitops-flux.md).

**Goal:** make the cluster declaratively reproducible from git, and deploy the
first real workload.

**Deliverables**
1. **Flux CD** bootstrapped (v2.9.6, read-only deploy key) against the private
   GitHub remote; app-of-apps under `clusters/k8s-homelab/`. ✅
2. **Secrets** with **SOPS + age** — age key generated, `sops-age` Secret in
   `flux-system`, `spec.decryption` on the `infrastructure`/`apps`
   Kustomizations. ✅
3. **Envoy Gateway** v1.9.2 installed *via* Flux (OCIRepository + HelmRelease),
   `GatewayClass eg` + `Gateway eg` Programmed at `192.168.123.11`
   ([ADR-0004](adr/0004-gateway-api-and-ingress.md)). ✅
4. **First workload** `podinfo` deployed declaratively in `podinfo`, exposed via
   an `HTTPRoute` + `ReferenceGrant`, **with CPU/mem requests + limits**, and an
   encrypted Secret decrypted in-cluster. ✅

**Files added**
- `clusters/k8s-homelab/flux-system/` — Flux bootstrap output.
- `clusters/k8s-homelab/{kustomization,infrastructure,apps}.yaml` — app-of-apps.
- `infrastructure/envoy-gateway/` — Gateway controller as `HelmRelease`.
- `apps/podinfo/` — first app manifests + `secret.sops.yaml`.
- Runbook [`docs/runbooks/05-gitops-flux.md`](runbooks/05-gitops-flux.md).

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
4. Phase 3 **done** (2026-10-15): Flux bootstrapped, `sops-age` wired, Envoy
   Gateway installed via Flux, and `podinfo` deployed with an encrypted Secret.
   See [runbook 05](runbooks/05-gitops-flux.md).
5. Next: resolve [Decision 4](#still-open--decision-4--observability-sizing) (observability
   sizing) and start **Phase 6** (Prometheus/Grafana via Flux); Phase 5 (IaC) is
   an unblocked parallel option.

---

## References

- [Documentation index](README.md)
- [System inventory](system-inventory.md) — verified current state
- [Troubleshooting log](troubleshooting-log.md)
- [ADR-0004 — Ingress / Gateway API](adr/0004-gateway-api-and-ingress.md)
- [Runbook 03 — session lifecycle](runbooks/03-session-lifecycle.md)
