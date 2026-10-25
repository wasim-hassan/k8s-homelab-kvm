# Roadmap: k8s-homelab-kvm

Forward plan for the homelab, phase by phase, with the decision points that block
each phase. This is also the resume point for a new session: read the
[Resume checklist](#resume-checklist) at the bottom.

- **Last updated:** 2026-10-25
- **Last verified:** 2026-10-25
- **Status:** all planned phases (0 through 8) are complete. The current focus is
  maintenance and the deferred, stretch items (Talos, storage, backup).
- **Built:** the substrate (KVM/libvirt, VMs), the k3s cluster, the operator
  workspace and k9s, GitOps (Flux CD, SOPS/age, Envoy Gateway, the `podinfo`
  workload), the provisioning scripts, observability (`kube-prometheus-stack`),
  security hardening, the Trivy Operator with its Grafana dashboard, the Flux Web
  UI (Flux moved to the Flux Operator), and the CI/CD pipeline with Flux image
  automation. See
  [system-inventory.md](system-inventory.md#current-phase-status).
- **Phase timeline:** Phase 3 (GitOps) done 2026-10-14; Phase 5 (IaC) re-scoped
  2026-10-15 ([ADR-0005](adr/0005-no-ansible-node-config.md)); Phase 6
  (Observability) **done** 2026-10-15; Flux moved to operator-managed + Web UI
  **done** 2026-10-15 ([runbook 07](runbooks/07-flux-webui.md)); Phase 7 (Security)
  **done** 2026-10-15 ([runbook 08](runbooks/08-security-hardening.md)); Phase 7b
  (Trivy Operator) **done** 2026-10-16 ([ADR-0008](adr/0008-trivy-operator.md));
  Phase 8 (CI/CD + image automation) **done** 2026-10-16
  ([ADR-0009](adr/0009-ci-cd-image-automation.md)).
- **Remaining:** the deferred/stretch items (Talos, storage, backup).

## Status — all planned phases complete

Phases 0–8 are **done**. The phase sections below are the closed record; the
forward plan is now the [stretch items](#stretch-later).

> **Version note.** Component versions below were researched first, then
> **pinned and verified in the cluster** at install time. Re-verify before
> changing a pinned version.

---

## Phase summary

| Phase | Theme | Status | Blocked by |
|---|---|---|---|
| 0 | Substrate (KVM, libvirt, network, VMs, SSH) | ✅ done | — |
| 1 | k3s cluster (control plane + worker, verified) | ✅ done | — |
| 2 | Operator workspace (Devpod/Podman) + observability (k9s) | ✅ done | — |
| **3** | **GitOps foundation (Flux + SOPS/age, ingress, first workload)** | ✅ done | — |
| 4 | CNI migration → Cilium (+ Hubble) | 💤 skip for now | Decision 1 → **skip Cilium** |
| 5 | IaC — kept as scripts; **Ansible dropped, Terraform deferred** ([ADR-0005](adr/0005-no-ansible-node-config.md)) | ➖ re-scoped | — |
| 6 | Observability stack (Prometheus + Grafana; Alertmanager off) | ✅ done | — |
| 7 | Security hardening (RBAC, PSS, secrets hygiene; NetworkPolicy deferred) | ✅ done | — (NetworkPolicy → Phase 4) |
| 7b | Continuous security scanning (Trivy Operator + Grafana dashboard) | ✅ done | — |
| 8 | CI/CD + image automation | ✅ done | — |
| — | Stretch: Talos, storage (Longhorn), backup (Velero) | 💤 later | — |

---

## ⚠️ Sequencing note — do Cilium before GitOps

> **Resolved 2026-10-14:** Cilium is **skipped for now** (keep Flannel) to stay
> lightweight; the note below is kept for when/if that changes. See
> [Resolved decisions](#resolved-decisions).

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

- `clusters/k8s-homelab/flux-system/` — Flux bootstrap output. *(Removed 2026-10-15
  when Flux moved to operator-managed — [ADR-0006](adr/0006-flux-operator-managed.md).)*
- `clusters/k8s-homelab/{kustomization,infrastructure,apps}.yaml` — app-of-apps.
- `infrastructure/envoy-gateway/` — Gateway controller as `HelmRelease`.
- `apps/podinfo/` — first app manifests + `secret.sops.yaml`.
- Runbook [`docs/runbooks/05-gitops-flux.md`](runbooks/05-gitops-flux.md).

> **2026-10-15 — Flux is now operator-managed.** A `FluxInstance` + the **Flux
> Operator** adopt the Flux components/source, and the operator's **Web UI** is
> exposed at `flux.local` ([ADR-0006](adr/0006-flux-operator-managed.md),
> [runbook 07](runbooks/07-flux-webui.md)). Flux is no longer CLI-bootstrapped.

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

## Phase 5 — Infrastructure as Code *(re-scoped 2026-10-15)*

> **Status: re-scoped — Ansible dropped, Terraform deferred.** See
> [ADR-0005](adr/0005-no-ansible-node-config.md). The IaC intent is met by the
> existing `scripts/` + GitOps; **no configuration-management tool is added.**

**Goal:** make the host/cluster build reproducible as code — without adding a
tool that has no job at this scale.

- **Node baseline** → kept as [`scripts/10-prepare-nodes.sh`](../scripts/10-prepare-nodes.sh)
  (idempotent, verified). *Not* converted to Ansible.
- **Terraform (libvirt)** → **deferred**: the VMs are created by the external
  `~/Sync/Repos/kvm-vm-provisioner`, which this project must not modify, so a
  rewrite is a redundant "alternative path" rather than a gain. `terraform/`
  keeps only [`libvirt-k8s-net.xml`](../terraform/libvirt-k8s-net.xml) as
  reference.
- **Long-term replacement** → **Talos** (immutable OS) removes the node-config
  layer entirely. Tracked as a stretch goal.

**Why:** Kubernetes/Helm/Flux operate *inside* the cluster and cannot configure
the host OS, so this layer is real — but at 2 nodes a bash script covers it more
simply than Ansible. Full reasoning in [ADR-0005](adr/0005-no-ansible-node-config.md).

---

## Phase 6 — Observability stack

> **Status: ✅ complete (2026-10-15).** Implemented in
> [`infrastructure/monitoring/`](../infrastructure/monitoring) as a Flux
> `HelmRelease`. Procedure + verification:
> [runbook 06](runbooks/06-observability.md).

**Goal:** metrics, dashboards, alerting — the SRE signal layer.

- **`kube-prometheus-stack`** deployed via Flux `HelmRelease` — installed chart
  **92.7.0** (prometheus-operator **v0.94.1**). ✅
- Stack trimmed for the small cluster: **Alertmanager disabled**, Prometheus
  `retention 6h` + 2Gi `local-path` PVC, explicit requests/limits everywhere. ✅
- **Decision 4 (sizing)** resolved by bumping the VMs first
  (`k8s-cp-01` 3 GiB, `k8s-worker-01` 1536 MiB); both nodes stay under 65% with
  the stack running. See [memory budget](system-inventory.md#memory-budget). ✅
- Grafana exposed at `grafana.local` through Envoy Gateway; admin credentials
  from a SOPS-encrypted Secret. ✅

**Deferred:** Alertmanager/alert routing (no notification target yet); dashboards
ship with the chart.

---

## Phase 7 — Security hardening

> **Status: ✅ complete (2026-10-15).** Implemented in
> [`apps/podinfo/`](../apps/podinfo), [`infrastructure/`](../infrastructure) and
> `.devcontainer/Containerfile`. Procedure + verification:
> [runbook 08](runbooks/08-security-hardening.md), [ADR-0007](adr/0007-security-hardening.md).

- **Scanner:** **Trivy v0.75.0** pinned + checksum-verified in the workspace image
  as the single scanner (`trivy config` now; image/vuln/SBOM in Phase 8).
- **RBAC:** least-privilege ServiceAccounts; no cluster-admin for workloads —
  `podinfo` has a dedicated SA with automount disabled and no bindings; all
  cluster-admin holders are required Flux/Gateway/system components.
- **NetworkPolicy:** pod-to-pod segmentation (needs a policy-capable CNI → after
  Phase 4). **Still deferred.**
- **Pod Security Standards:** `restricted` enforced on `podinfo`,
  `envoy-gateway-system`, `flux-system`; `privileged` (+ baseline warn/audit) on
  `monitoring` for the node-exporter exception. Non-root, read-only root FS on
  podinfo.
- **Secrets hygiene:** audited — only SOPS-encrypted secrets in git; `trivy fs
  --scanners secret` reports 0.

---

## Phase 7b — Continuous security scanning (Trivy Operator)

> **Status: ✅ complete (2026-10-16).** Implemented in
> [`infrastructure/trivy-operator/`](../infrastructure/trivy-operator) +
> [`infrastructure/monitoring/dashboards/`](../infrastructure/monitoring/dashboards).
> Procedure + verification: [runbook 08](runbooks/08-security-hardening.md),
> [ADR-0008](adr/0008-trivy-operator.md).

**Goal:** extend Phase 7's one-shot CLI scanning to **continuous, in-cluster**
scanning — and provide the requested "trivy web UI" without adding a bespoke app.

- **Trivy Operator** (chart **0.37.0**, app v0.35.0) via a Flux `HelmRelease` in
  the new `trivy-system` namespace (PSS `restricted`). Standalone mode — no
  server, no PVC. Scans image CVE, config-audit, exposed-secret and RBAC.
- **"Web UI" = Grafana.** The operator emits Prometheus metrics; dashboard
  **17813** is vendored as a `ConfigMap` (`grafana_dashboard=1`) that the Grafana
  sidecar provisions. No bespoke UI is added. **Trivy has no official server UI.**
- **Scope kept `restricted`:** infra-assessment / node-collector **disabled**
  (needs hostPath+root); scan jobs run as unprivileged non-root (uid 10000).
- **Bonus fix:** the `flux-system` PSS `enforce`/`audit` labels, previously set
  imperatively and reverted after a restart, are now **declarative** via
  `FluxInstance.spec.commonMetadata.labels`.
- **Findings triage:** `podinfo` upgraded `6.7.1 → 6.15.0` (its report → 0
  Critical/High; cluster-wide **Critical 6 → 0**, total **897 → 701**). Remaining
  upstream/system findings are reviewed and **accepted** (not chased to zero) —
  see [ADR-0008](adr/0008-trivy-operator.md#findings-triage-accepted-risk).

---

## Phase 8 — CI/CD + image automation

- Build container images in CI (GitHub Actions or self-hosted runner), push to a
  registry (GHCR or self-hosted).
- **Flux image-automation** controller to bump image tags from registry to git.
- End-to-end: commit app change → CI builds → Flux deploys.

> **Status: ✅ complete (2026-10-16).** Implemented as ADR-0009 / runbook 09.
> A FOSS **Go** app (`ratlab-demo`, `images/ratlab-demo`, `scratch`, nonroot) is
> built by **GitHub Actions → GHCR** with trivy scan + SBOM (syft) + provenance
> attestation. The Flux **image-reflector** + **image-automation** controllers are
> enabled in the `FluxInstance`; an `ImageRepository`/`ImagePolicy` (semver
> `>=0.1.0`)/`ImageUpdateAutomation` (strategy `Setters`) writes new tags back to
> git via a dedicated **write** `GitRepository` backed by a **SOPS** deploy key.
> The `ratlab-demo` Deployment carries the `$imagepolicy` marker and is rolled out
> by the `apps` Kustomization on each release tag.
> **One-time manual steps (GitHub):** add the write **deploy key** and set the
> GHCR package **public**. See [ADR-0009](adr/0009-ci-cd-image-automation.md),
> [runbook 09](runbooks/09-ci-cd-image-automation.md).

---

## Stretch (later)

- **Talos Linux** as the node OS (immutable, API-driven). Requires x86-64-v2+,
  already satisfied — see [ADR-0002](adr/0002-implicit-cpu-model.md).
- **Persistent storage:** Longhorn or tune `local-path-provisioner`.
- **Backup:** Velero for cluster/volume backup; etcd snapshots (k3s).
- **Tooling evaluation:** a surveyed radar of candidate tools (IaC, GitOps,
  service mesh, policy, appsec, observability, chaos, autoscaling) with FOSS
  license, footprint, and verdicts — see
  [tooling-evaluation.md](tooling-evaluation.md).

---

## Resolved decisions

Recorded here (in committed docs, not only the private `AGENTS.local.md`) so the
repo's memory is complete.

| # | Decision | Resolution |
|---|---|---|
| 1 | Cilium timing | **Skip Cilium for now** — keep Flannel (lightweight priority). Revisit as a stretch. |
| 2 | Git remote for Flux | **Private GitHub** — `wasim-hassan/k8s-homelab-kvm` (git init + push done). |
| 3 | Ingress / Gateway controller | **Envoy Gateway** (CNCF, Apache-2.0, Gateway API) — [ADR-0004](adr/0004-gateway-api-and-ingress.md) now **Accepted**. |
| 4 | Observability sizing | **Bump VM RAM + trim the stack.** `k8s-cp-01` 3 GiB, `k8s-worker-01` 1536 MiB; `kube-prometheus-stack` with Alertmanager off, Prometheus `6h`/2Gi. Resolved 2026-10-15 — see [Phase 6](#phase-6--observability-stack). |
| 5 | Config management (Ansible?) | **No Ansible** — keep `10-prepare-nodes.sh`; Terraform-libvirt deferred (redundant with the external provisioner); Talos is the long-term replacement. [ADR-0005](adr/0005-no-ansible-node-config.md). |
| 6 | Flux status / Web UI | **Flux Web UI via the Flux Operator** — migrate Flux to operator-managed (`FluxInstance`) and expose the Flux Status UI at `flux.local`. Weave GitOps ruled out (unmaintained + breaks on HelmRelease `v2`); `fluxcd/webui` archived. [ADR-0006](adr/0006-flux-operator-managed.md), [runbook 07](runbooks/07-flux-webui.md). |
| 7 | Security scanner (kube-linter vs trivy) | **Trivy v0.75.0, single scanner** — kube-linter only lints manifests and cannot do image CVE / secrets / SBOM, so it cannot cover Phase 8; trivy's `config` mode replaces kube-linter and its image/secret/SBOM modes cover the rest. Pinned ≥ 0.75.0 (avoid malicious `0.69.4`). [ADR-0007](adr/0007-security-hardening.md). |
| 8 | Trivy Web UI / continuous scanning | **Trivy Operator + Grafana dashboard.** Trivy has no official server web UI; the operator scans in-cluster (image/config/secret/RBAC) and exposes Prometheus metrics, rendered by a vendored Grafana dashboard (17813). No bespoke UI, kept `restricted` by disabling infra-assessment. [ADR-0008](adr/0008-trivy-operator.md). |

The option tables for decisions 1–3 are preserved in git history; the
resolutions above supersede them.

### Resolved — Decision 4 — Observability sizing

Resolved 2026-10-15: bump the VM RAM (`k8s-cp-01` 3 GiB, `k8s-worker-01`
1536 MiB) and run a trimmed `kube-prometheus-stack` (Alertmanager off,
Prometheus `6h` retention / 2Gi `local-path` PVC). Both nodes stay below 65%
memory with the stack up. See [Phase 6](#phase-6--observability-stack) and
[runbook 06](runbooks/06-observability.md).

---

## Resume checklist

To pick this up in a new session:

1. Start the environment — [runbook 03](runbooks/03-session-lifecycle.md)
   (`kvm on` → `vm start k8s-cp-01` → `vm start k8s-worker-01` → `devpod up . --ide none`).
2. Decisions **1–8** are all resolved ([above](#resolved-decisions)).
3. Git checkpoint is **done** — repo initialized, committed, pushed to private
   GitHub, so Flux diffs will be legible.
4. Phase 3 **done** (2026-10-14): Flux bootstrapped, `sops-age` wired, Envoy
   Gateway installed via Flux, and `podinfo` deployed with an encrypted Secret.
   See [runbook 05](runbooks/05-gitops-flux.md).
5. Phase 5 **re-scoped** (2026-10-15): Ansible dropped, Terraform deferred —
   [ADR-0005](adr/0005-no-ansible-node-config.md).
6. Phase 6 **done** (2026-10-15): `kube-prometheus-stack` via Flux, Grafana at
   `grafana.local`, VMs bumped for Decision 4. See
   [runbook 06](runbooks/06-observability.md).
7. **Flux Web UI done** (2026-10-15): Flux migrated to the **Flux Operator**
   (`FluxInstance`), Web UI at `flux.local` ([ADR-0006](adr/0006-flux-operator-managed.md),
   [runbook 07](runbooks/07-flux-webui.md)). Add `192.168.123.11 flux.local` to
   the host `/etc/hosts`.
8. **Phase 7 done** (2026-10-15): trivy v0.75.0 pinned + checksum-verified,
   podinfo hardened + dedicated SA, PSS enforced on `podinfo`/`envoy-gateway-system`/
   `flux-system` (`restricted`) and `monitoring` (`privileged`, node-exporter
   exception), secrets-hygiene audit clean. NetworkPolicy is deferred until
   Phase 4 (Cilium). See [runbook 08](runbooks/08-security-hardening.md),
   [ADR-0007](adr/0007-security-hardening.md).
9. **Phase 7b done** (2026-10-16): **Trivy Operator** (chart 0.37.0) in
   `trivy-system` for continuous image/config/secret/RBAC scanning, results in a
   **Grafana dashboard** (17813) at `grafana.local`; infra-assessment disabled to
   stay `restricted`; `flux-system` PSS labels made declarative. See
   [ADR-0008](adr/0008-trivy-operator.md).
10. **Phase 8 done** (2026-10-16): CI/CD via **GitHub Actions → GHCR** (trivy +
    SBOM + provenance) and **Flux image automation** (image-reflector +
    image-automation controllers, `ImageRepository`/`ImagePolicy`/
    `ImageUpdateAutomation`, SOPS write key) driving the `ratlab-demo` workload.
    Verified end-to-end and hands-off across `v0.1.1`→`v0.1.3`: `ImagePolicy`
    → `0.1.3`, Flux committed the tag bump (`2478343`), `ratlab-demo` is
    `Running` on `0.1.3`. See
    [ADR-0009](adr/0009-ci-cd-image-automation.md),
    [runbook 09](runbooks/09-ci-cd-image-automation.md).

---

## References

- [Documentation index](README.md)
- [System inventory](system-inventory.md) — verified current state
- [Troubleshooting log](troubleshooting-log.md)
- [ADR-0004 — Ingress / Gateway API](adr/0004-gateway-api-and-ingress.md)
- [Runbook 03 — session lifecycle](runbooks/03-session-lifecycle.md)
