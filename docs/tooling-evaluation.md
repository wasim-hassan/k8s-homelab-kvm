# Tooling evaluation: a homelab technology radar

A survey of DevOps/SRE tools that could extend this lab, judged against its
actual constraints: **FOSS only**, **two VMs**, and **~4.5 GiB of RAM total**.
This is a decision document, not an installation plan. Nothing listed here is
installed because of it; adopting any ✅ item needs its own ADR and a RAM
budget check.

- **Last updated:** 2026-10-25
- **Last verified:** 2026-10-25 (licenses and the lab baseline; RSS figures are
  estimates)
- **Status:** reference. Feeds the "stretch" items in the [roadmap](roadmap.md).

## How to read this

Each tool gets a verdict and a short "use it when / don't use it when" note.

| Verdict | Meaning |
|---|---|
| ✅ **Adopt** | Fits the constraints and closes a real gap. Not installed yet. |
| 🔬 **Learn** | Worth understanding; installing it here does not pay off. |
| ⏳ **Defer** | A real fit, but RAM or timing says "not yet". |
| ❌ **Reject** | Proprietary, redundant, or unsuitable for a static 2-node cluster. |

**Scoring axes**

1. **License** — must be FOSS (OSI-approved, or equivalently open).
2. **Footprint** — RAM/CPU/disk added to a cluster with ~25 % headroom.
3. **Overlap** — does the lab already do this? (Flux, Prometheus, Trivy, Kustomize.)
4. **Learning value** — does it teach a portable SRE skill?
5. **Operational cost** — one more controller, CRD surface, and failure mode.

> **RSS numbers are order-of-magnitude estimates**, not measurements from this
> cluster. Confirm with `kubectl top` after any install.

## The baseline (what is already running)

| Layer | Current choice |
|---|---|
| Cluster | k3s `v1.37.1+k3s1`, Flannel, built-in NetworkPolicy controller |
| GitOps | Flux CD `2.9.6` via the Flux Operator, SOPS/age |
| Config | Kustomize (inside Flux) |
| Ingress | Envoy Gateway `1.9.2`, Gateway API |
| Observability | kube-prometheus-stack (Prometheus + Grafana; Alertmanager off) |
| Security | Trivy CLI + Trivy Operator, PSS `restricted` |
| CI/CD | GitHub Actions → GHCR, Flux image automation |

Memory headroom at the time of writing (from `kubectl top nodes`): roughly
**0.9 GiB free on `k8s-cp-01`** and **0.4 GiB free on `k8s-worker-01`**. That is
the real budget for everything below.

---

## 1. Infrastructure as Code and provisioning

### Terraform — ❌ (license), 🔬 (concept)

The industry-standard declarative provisioner. Since **v1.6 (August 2023)** it
is licensed under the **BUSL 1.1**, which is not an OSI-approved open-source
license (each release converts to MPL 2.0 after four years). That alone breaks
the FOSS-only rule.

*Use it when:* you must interoperate with an employer or a provider module that
only ships Terraform.
*Don't use it here:* the lab is FOSS-only and the VMs are created by the
external `kvm-vm-provisioner` (see [ADR-0005](adr/0005-no-ansible-node-config.md)).

### OpenTofu — 🔬 (defer install)

The Linux Foundation fork of Terraform 1.5.x, **MPL 2.0**, with built-in
client-side state encryption and its own registry. It is the drop-in
replacement for the Terraform workflow.

*Use it when:* you want IaC for the host/VM/network layer without the BUSL.
*Don't use it here yet:* it would duplicate the external provisioner this
project must not modify. It is the right answer **if** the host layer is ever
brought in-repo.

### Pulumi — ⏳ (CLI only) / ❌ (as a platform)

Provisioning in general-purpose languages (TypeScript, Python, Go). The **CLI
and SDKs are Apache 2.0**; **Pulumi Cloud is a proprietary SaaS** (a free tier
exists, and self-managed backends such as S3 or local files are supported, so a
fully FOSS workflow is possible).

*Use it when:* you want real programming constructs (loops, tests, packages) in
infrastructure code.
*Don't use it here:* it solves the same problem as OpenTofu with a heavier
learning curve, and the hosted product is proprietary.

### Crossplane — ⏳

A **control plane** that exposes cloud infrastructure as Kubernetes CRDs, so
Flux/Argo reconcile infrastructure the same way they reconcile apps. Apache 2.0.

*Use it when:* you have real cloud resources and want one reconciliation model.
*Don't use it here:* there is no cloud account to manage, and it adds a
controller plus CRDs on a cluster with ~1.3 GiB free.

### Kustomize — ✅ (already in use)

Apache 2.0, built into `kubectl` and the engine Flux already uses. No action
needed; it is listed so the radar is complete.

---

## 2. GitOps and delivery

### Argo CD — ❌ (redundant)

Apache 2.0, CNCF-graduated pull-based GitOps with a strong UI. It would
**duplicate Flux**, which already reconciles this repo, and it adds an
api-server, repo-server, application-controller, and Redis (~0.5–1 GiB).

*Use it when:* a team standardizes on Argo, or you need Argo-specific features.
*Don't use it here:* two GitOps engines on one small cluster is pure overhead.

### Argo Rollouts — ✅

Apache 2.0 progressive-delivery controller: `Rollout` CRDs for canary and
blue-green, with analysis runs that can auto-abort. It **complements** Flux
(Flux deploys; Rollouts controls the rollout shape). Controller ~100–200 MiB.

*Use it when:* you want canary/blue-green instead of `RollingUpdate`, and to
learn progressive delivery.
*Don't use it here yet:* verify its **Gateway API / Envoy Gateway** traffic
integration for the version you pick before committing.

---

## 3. Networking and service mesh

### Cilium — ⏳

Apache 2.0, eBPF-based CNI that can replace **both Flannel and kube-proxy**, and
adds **Hubble** flow observability plus L3/L4/L7 policy.

*Use it when:* you want eBPF networking, kube-proxy replacement, and flow-level
observability.
*Don't use it here yet:* it is a **fresh-install** change (k3s must start with
`--flannel-backend=none`), it adds a per-node agent plus operator, and it was
deliberately skipped to stay lightweight (roadmap Decision 1). Revisit only with
more RAM or a rebuild.

### Istio (ambient mode) — 🔬 / ⏳

Apache 2.0. **Ambient mode** is sidecar-less: a per-node L4 **ztunnel** plus an
optional L7 **waypoint** proxy. Lighter than the classic sidecar model, but
still `istiod` (~200–500 MiB) plus a ztunnel per node.

*Use it when:* you need mTLS, traffic policy, and L7 routing across services.
*Don't use it here:* with ~1.3 GiB free and a single Gateway already handling
ingress, a mesh is a large addition for little gain. Study the ambient
architecture; install only on a bigger cluster.

### NetworkPolicy — ✅ (already possible)

**Correction to an earlier assumption:** this cluster does **not** need Cilium
to enforce `NetworkPolicy`. k3s ships a NetworkPolicy controller (kube-router)
and the server was installed with only `--disable traefik` — neither
`--flannel-backend=none` nor `--disable-network-policy` was passed. A
`NetworkPolicy` already exists in `flux-system`.

*Next step:* write a default-deny + allow-list policy for `podinfo` and
`ratlab-demo` as a small, high-value exercise. No new component required.

---

## 4. Policy, security, and supply chain

### Kyverno — ⏳

Apache 2.0, Kubernetes-native policy engine (YAML, CEL) with validate, mutate,
generate, and cleanup rules, plus policy reports.

*Use it when:* you want admission guardrails ("no `latest` tag", "require
limits") without learning Rego.
*Don't use it here yet:* ~200–400 MiB for the full set of controllers. PSS
already covers the basic pod hardening.

### OPA Gatekeeper — 🔬

Apache 2.0, CNCF, the Rego-based policy engine. More general and more powerful
than Kyverno, with a steeper curve and a similar footprint (~150–300 MiB).

*Use it when:* policy must span non-Kubernetes systems, or your org already uses
OPA.
*Don't use it here:* Kyverno is the easier fit for a Kubernetes-only lab.

### Snyk — ❌ (proprietary)

A commercial SaaS for SCA/SAST/container scanning. The product is proprietary;
it violates the FOSS-only rule.

*Replacement:* **Trivy** (already used), **Grype**, **Semgrep**, and the OWASP
tools below.

### SonarQube — ⏳ (CI only) / ❌ (in-cluster)

**SonarQube Community Build** is LGPL-3.0 and genuinely FOSS, but a small
instance needs roughly **4 GB RAM, 2 cores, and 30 GB disk** — more than this
cluster has. It is a code-quality/SAST server, not a Kubernetes component.

*Use it when:* you can run it on a workstation or a CI runner with enough RAM.
*Don't use it here:* it does not fit the cluster, and a per-PR one-shot install
on a GitHub-hosted runner is slow.

### Supply-chain and appsec tools — ✅ (CI, no cluster cost)

| Tool | What it adds | License |
|---|---|---|
| **Trivy** | Image/config/secret/SBOM scanning (already used) | Apache 2.0 |
| **Grype** | Second-opinion vulnerability matcher | Apache 2.0 |
| **Semgrep** | Lightweight SAST rules | LGPL-2.1 (OSS engine) |
| **OWASP Dependency-Check** | SCA for dependency manifests | Apache 2.0 |
| **OWASP ZAP** | DAST baseline scan against a running app | Apache 2.0 |
| **Cosign / Syft** | Image signing and SBOM generation | Apache 2.0 |

*Use them when:* you want broader coverage than Trivy alone, at **zero cluster
RAM**. Add them as CI steps, not in-cluster controllers.
*Don't use them here:* as always-on in-cluster services — CI is the right place.

---

## 5. Observability

### OpenTelemetry — ✅

Apache 2.0, vendor-neutral SDKs plus the **Collector** (agent/gateway) for
traces, metrics, and logs. The collector is light (~50–150 MiB); the **backend**
is what costs RAM.

*Use it when:* you want traces and a standard instrumentation path instead of
vendor SDKs.
*Don't use it here yet:* it needs a backend (below) to be useful; add the
collector and one backend together.

### Trace/log backends — ⏳ (pick one)

| Backend | Signal | License | Est. RAM |
|---|---|---|---|
| **Tempo** | traces | AGPL-3.0 | ~200–500 MiB + storage |
| **Loki** | logs | AGPL-3.0 | ~200–500 MiB + storage |
| **Jaeger** | traces | Apache 2.0 | ~200–500 MiB + storage |

*Use them when:* you need to answer "why was this request slow?" (traces) or
"what did the pod log?" (logs).
*Don't use them here yet:* one backend already consumes most of the free RAM.
Choose **Tempo** (traces) *or* **Loki** (logs), not both, and size retention
aggressively on `local-path`.

### Grafana Alloy — 🔬

Apache 2.0, Grafana's OTel-compatible collector distribution. It can replace the
Prometheus agent and the OTel collector with one binary.

*Use it when:* you want one agent for metrics, logs, and traces.
*Don't use it here yet:* the Prometheus stack is working; migrating agents is
churn without a clear win at this size.

---

## 6. Chaos engineering

### Chaos Mesh — ⏳ / ✅ (with RAM)

Apache 2.0, CNCF. A controller plus a privileged `chaos-daemon` DaemonSet and an
optional dashboard; experiment CRDs for pod, network, IO, and stress faults.
~300–500 MiB.

*Use it when:* you want realistic failure injection and a UI to explore it.
*Don't use it here yet:* the privileged daemon and the RAM cost are the
blockers on this cluster. It is the best learning tool of the two if RAM grows.

### LitmusChaos — ✅ (ad-hoc) / ⏳ (control plane)

Apache 2.0, CNCF. A library of chaos experiments; the control plane is optional
and experiments can be run as one-shot jobs.

*Use it when:* you want to run a single experiment (pod delete, network delay)
without a standing control plane.
*Don't use it here:* as a permanent control plane — the one-shot mode is the
lighter fit.

---

## 7. Autoscaling

### Horizontal Pod Autoscaler — ✅ (built in)

Ships with Kubernetes and uses the already-installed metrics-server. No new
component.

*Use it when:* a workload has a meaningful CPU/memory signal and more than one
replica makes sense.
*Don't use it here:* on single-replica lab apps — scaling out on a 2-node,
RAM-bound cluster just moves the problem.

### Vertical Pod Autoscaler — ✅ (recommender only)

Apache 2.0 (`kubernetes/autoscaler`). The **recommender** alone (~50–100 MiB)
reports right-sized requests without mutating pods.

*Use it when:* you want data to fix over/under-provisioned requests — valuable
on tight nodes.
*Don't use it here:* in `Auto` update mode on a RAM-bound cluster; evictions to
resize pods are disruptive. Start with `updateMode: "Off"` and read the
recommendations.

### KEDA — ✅

Apache 2.0, CNCF. Event-driven autoscaling (queue depth, cron, Prometheus
queries) on top of HPA, including scale-to-zero. ~100–200 MiB.

*Use it when:* you want to learn event-driven scaling, or scale a worker on a
queue/metric instead of CPU.
*Don't use it here yet:* there is no event source in the lab today. Add it
alongside a small demo workload so the value is visible.

### Cluster Autoscaler — ❌

Apache 2.0, but it needs a cloud provider or Cluster API to add/remove nodes.
This lab has two **static** VMs.

*Use it when:* nodes are ephemeral and provider-managed.
*Don't use it here:* there is nothing to scale.

---

## 8. ML platform

### Kubeflow — 🔬 / ❌ (install)

Apache 2.0. The Kubernetes ML platform: pipelines, notebooks, Katib (tuning),
KServe (serving), and a central dashboard. The full platform pulls in Istio,
Knative, and a large CRD surface; a useful install realistically wants **8 GB+
RAM** and several cores.

*Use it when:* you are building an ML platform on Kubernetes.
*Don't use it here:* it dwarfs the entire cluster. Worth reading about for the
patterns (pipeline orchestration, model serving), not for installing.

---

## Gaps in the current lab

Ranked by value per MiB:

1. **No TLS** — every route is HTTP. `cert-manager` + a local CA or ACME closes
   this (~50–150 MiB).
2. **No NetworkPolicy** — already enforceable (see above); just needs manifests.
3. **No traces or logs** — metrics only. One backend (Tempo *or* Loki) plus the
   OTel collector.
4. **No admission policy** — PSS covers pod hardening; Kyverno would add
   guardrails such as "no `latest` tag".
5. **No right-sizing data** — VPA recommender would show where requests are
   wrong.
6. **No progressive delivery** — Argo Rollouts.
7. **No alerting/SLOs** — Alertmanager is disabled; re-enable it with a
   webhook/email receiver when there is somewhere to send alerts.
8. **No backup/DR** — Velero plus object storage, or k3s etcd snapshots plus a
   PVC copy.

## Recommended sequence

Ordered by value and RAM cost. Each step should be its own ADR + runbook.

| # | Step | Why | Est. RAM | Prerequisite |
|---|---|---|---|---|
| 1 | **cert-manager** | HTTPS everywhere; closes the biggest visible gap | ~50–150 MiB | none |
| 2 | **NetworkPolicy** (no install) | Default-deny + allow-list for the two apps | 0 | none |
| 3 | **VPA recommender** | Right-size requests before adding more workloads | ~50–100 MiB | metrics-server (present) |
| 4 | **Argo Rollouts** | Canary/blue-green; progressive delivery skill | ~100–200 MiB | verify Gateway API support |
| 5 | **KEDA** | Event-driven autoscaling; scale-to-zero | ~100–200 MiB | a demo event source |
| 6 | **OTel Collector + Tempo *or* Loki** | Traces or logs, one signal at a time | ~250–600 MiB | storage sizing |
| 7 | **Kyverno** | Admission guardrails | ~200–400 MiB | RAM bump likely |
| 8 | **Chaos Mesh** *or* **Litmus one-shot** | Failure injection | ~300–500 MiB / ~0 | RAM bump likely |
| 9 | **Velero** | Backup and restore | ~100–200 MiB + storage | an S3-compatible target |

**Study-only (no install):** Terraform vs OpenTofu, Pulumi, Crossplane, Argo CD,
Istio ambient, Cilium, Kubeflow, SonarQube.

**CI-side (zero cluster cost):** Semgrep, Grype, OWASP Dependency-Check, OWASP
ZAP baseline, Cosign.

## Master table

| Tool | Theme | License | Est. RAM | Overlaps with | Verdict |
|---|---|---|---|---|---|
| Terraform | IaC | BUSL 1.1 | n/a (CLI) | OpenTofu | ❌ |
| OpenTofu | IaC | MPL 2.0 | n/a (CLI) | Terraform | 🔬 |
| Pulumi | IaC | Apache 2.0 (CLI) | n/a (CLI) | OpenTofu | ⏳ |
| Crossplane | IaC | Apache 2.0 | ~150–300 MiB | Flux | ⏳ |
| Kustomize | Config | Apache 2.0 | 0 | — | ✅ |
| Argo CD | GitOps | Apache 2.0 | ~500 MiB–1 GiB | Flux | ❌ |
| Argo Rollouts | Delivery | Apache 2.0 | ~100–200 MiB | — | ✅ |
| Cilium | Networking | Apache 2.0 | ~100–300 MiB | Flannel | ⏳ |
| Istio (ambient) | Mesh | Apache 2.0 | ~250–600 MiB | Envoy Gateway | 🔬 |
| Kyverno | Policy | Apache 2.0 | ~200–400 MiB | PSS | ⏳ |
| OPA Gatekeeper | Policy | Apache 2.0 | ~150–300 MiB | Kyverno | 🔬 |
| Snyk | AppSec | proprietary | n/a (SaaS) | Trivy | ❌ |
| SonarQube | AppSec | LGPL-3.0 | ~4 GiB | Semgrep | ⏳ |
| Semgrep | AppSec | LGPL-2.1 (OSS engine) | 0 (CI) | — | ✅ |
| OWASP DC / ZAP | AppSec | Apache 2.0 | 0 (CI) | — | ✅ |
| OpenTelemetry | Observability | Apache 2.0 | ~50–150 MiB | — | ✅ |
| Tempo / Loki | Observability | AGPL-3.0 | ~200–500 MiB | — | ⏳ |
| Grafana Alloy | Observability | Apache 2.0 | ~100 MiB | Prometheus agent | 🔬 |
| Chaos Mesh | Chaos | Apache 2.0 | ~300–500 MiB | — | ⏳ |
| LitmusChaos | Chaos | Apache 2.0 | ~0 (one-shot) | Chaos Mesh | ✅ |
| HPA | Autoscaling | Apache 2.0 | 0 (built in) | — | ✅ |
| VPA | Autoscaling | Apache 2.0 | ~50–100 MiB | — | ✅ |
| KEDA | Autoscaling | Apache 2.0 | ~100–200 MiB | — | ✅ |
| Cluster Autoscaler | Autoscaling | Apache 2.0 | n/a | — | ❌ |
| Kubeflow | ML platform | Apache 2.0 | 8 GiB+ | — | 🔬 |

## Deliberately not adding

- **Argo CD** — Flux already owns GitOps.
- **Snyk** — proprietary; Trivy/Grype cover the same ground.
- **SonarQube in-cluster** — needs more RAM than the whole cluster has.
- **Istio / Cilium now** — a mesh or eBPF CNI is a fresh-install-scale change on
  a RAM-bound lab.
- **Kubeflow** — an ML platform does not fit a 4.5 GiB cluster.

## Open questions

1. **Argo Rollouts + Envoy Gateway** — confirm the Gateway API traffic-routing
   integration for the chosen version before adopting.
2. **Tempo or Loki** — pick one signal to add first; both will not fit.
3. **Backup target** — Velero needs an S3-compatible backend; decide whether
   that is MinIO in-cluster (costs RAM) or external.
4. **RAM budget** — steps 6–8 likely need a VM memory bump first; re-measure
   `kubectl top nodes` before each step.

## References

- [OpenTofu](https://opentofu.org/) · [Terraform license](https://www.hashicorp.com/license-faq)
- [Pulumi](https://www.pulumi.com/docs/) · [Crossplane](https://crossplane.io/)
- [Argo CD](https://argo-cd.readthedocs.io/) · [Argo Rollouts](https://argoproj.github.io/rollouts/)
- [Cilium](https://cilium.io/) · [Istio ambient](https://istio.io/latest/docs/ambient/)
- [k3s networking / NetworkPolicy](https://docs.k3s.io/networking)
- [Kyverno](https://kyverno.io/) · [Gatekeeper](https://open-policy-agent.github.io/gatekeeper/)
- [SonarQube Community Build](https://docs.sonarsource.com/sonarqube-community-build/)
- [Semgrep](https://semgrep.dev/) · [OWASP Dependency-Check](https://owasp.org/www-project-dependency-check/) · [OWASP ZAP](https://www.zaproxy.org/)
- [OpenTelemetry](https://opentelemetry.io/) · [Tempo](https://grafana.com/oss/tempo/) · [Loki](https://grafana.com/oss/loki/)
- [Chaos Mesh](https://chaos-mesh.org/) · [LitmusChaos](https://litmuschaos.io/)
- [KEDA](https://keda.sh/) · [VPA](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)
- [Kubeflow](https://www.kubeflow.org/)
- [cert-manager](https://cert-manager.io/) · [Velero](https://velero.io/)
