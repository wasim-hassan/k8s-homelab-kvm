# ADR-0008 — Continuous security scanning: Trivy Operator + Grafana dashboard

- **Status:** Accepted (2026-10-15, Phase 7b)
- **Deciders:** project owner
- **Context:** Phase 7 ([ADR-0007](0007-security-hardening.md)) adopted the
  **Trivy CLI** for one-shot manifest scanning in the workspace (`trivy config`,
  `trivy fs`). That covers the repo at commit time, but the cluster had no
  **continuous, in-cluster** view of what is actually running: image CVEs,
  workload misconfigurations, exposed secrets and RBAC risks drift after deploy.
  A "web UI for trivy" was requested. Trivy itself is a **CLI/scanner with no
  official server-side web UI** — so the requirement was reinterpreted as *"make
  in-cluster scan results visible"*, which the cluster can already do with its
  existing observability stack.

---

## Decision

Deploy the **Trivy Operator** (Aqua), managed by Flux, and surface its results in
the **existing Grafana** — no new UI component is introduced.

### 1. Trivy Operator via Flux `HelmRelease`
- Chart **`trivy-operator` 0.37.0** (app **v0.35.0**) from the `aqua`
  `HelmRepository` (`https://aquasecurity.github.io/helm-charts`), delivered as a
  `HelmRelease` in the new **`trivy-system`** namespace
  ([`infrastructure/trivy-operator/`](../../infrastructure/trivy-operator)).
- The operator watches workloads and spawns short-lived, per-resource **scan
  jobs**, writing `VulnerabilityReport` / `ConfigAuditReport` /
  `ExposedSecretReport` / `RbacAssessmentReport` **CRs**.
- **Standalone mode** (`trivy.mode: Standalone`): each scan job pulls the Trivy
  DB itself, so there is no Trivy **server** component and no PVC — lighter and
  simpler for a 2-node lab.

### 2. "Web UI" = Grafana, not a bespoke app
- The operator exposes **Prometheus metrics** (`trivy_image_vulnerabilities`,
  `trivy_resource_configaudits`, …). Prometheus already scrapes the cluster, so
  the UI is a **Grafana dashboard**.
- Dashboard **17813** ("Trivy Operator Dashboard", grafana.com) is vendored as a
  `ConfigMap` labelled `grafana_dashboard: "1"`, which the **Grafana sidecar**
  auto-provisions. `__inputs`/`__requires` are stripped and the datasource
  placeholder `${DS_PROMETHEUS}` is replaced with the cluster's Prometheus
  datasource uid (`prometheus`).
- **Alternatives rejected:** a Trivy server + third-party web UI (extra
  component, credentials, and exposure for little gain); a standalone reporting
  UI such as DefectDojo (heavyweight, duplicates Grafana which is already
  deployed and routed at `grafana.local`).
- **Grafana sidecar label `grafana_dashboard=1`** is the integration point — any
  namespace's ConfigMap with that label is picked up (verified: the sidecar
  watches cluster-wide).

### 3. Security posture kept consistent with Phase 7
- **PSS `restricted`** on `trivy-system` (enforce/warn/audit). The operator image
  runs as **uid 10000** (non-root) and both the operator pod and the scan-job pods
  are given numeric non-root `runAsUser`/`runAsGroup`, `RuntimeDefault` seccomp,
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and
  `capabilities.drop: [ALL]`. The operator mounts an `emptyDir` at `/tmp`, so a
  read-only root filesystem is safe.
- **Infra assessment (node-collector) disabled**
  (`operator.infraAssessmentScannerEnabled: false`). The node-collector needs
  `hostPath` mounts and root, which `restricted` forbids; disabling it avoids a
  second `privileged` exception like the monitoring one. We keep **image CVE,
  config-audit, exposed-secret and RBAC** scans — all of which run unprivileged.
- **ServiceMonitor** enabled with `labels.release: kube-prometheus-stack` so the
  existing Prometheus (selector `{release: kube-prometheus-stack}`) scrapes it.
- **Info metrics** (`metricsExposedSecretInfo`, `metricsRbacAssessmentInfo`,
  `metricsClusterComplianceInfo`, `metricsConfigAuditInfo`) enabled so the
  dashboard has data.

### 4. `flux-system` PSS labels moved to declarative management
- Phase 7 set the `flux-system` PSS labels **imperatively** and recorded that as
  an exception ([ADR-0007](0007-security-hardening.md)), because the namespace is
  Flux-Operator–owned. In practice the `enforce`/`audit` labels **reverted after
  a VM restart**. The fix: set them **declaratively** via
  `FluxInstance.spec.commonMetadata.labels`, which the operator re-applies on
  every reconcile. Verified: all six PSS labels now persist (see
  [troubleshooting-log](../troubleshooting-log.md)).

---

## Consequences

- **Positive:** Continuous in-cluster scanning with **zero new UI surface** —
  results appear in the Grafana the cluster already runs. Trivy Operator is the
  de-facto successor to Starboard and mirrors the CLI already adopted, giving a
  consistent story from commit-time (Phase 7) to runtime (this phase). Scan
  concurrency, timeouts and resources are bounded for the small cluster.
- **Negative:** Adds one controller + ephemeral scan-job pods to a 3 GiB/1.5 GiB
  cluster (mitigated: `scanJobsConcurrentLimit: 2`, `scanJobTimeout: 5m`, explicit
  requests/limits, no server/PVC). `infra-assessment` (node OS checks) is
  deliberately **not** covered, so results do not include CIS/host audits.
- **Neutral:** Reports live as CRs (queryable with `kubectl`), metrics live in
  Prometheus, and dashboards live in git — three consistent, GitOps-managed
  surfaces. Helm/`trivy-operator` values nesting has one sharp edge
  (`podSecurityContext` is top-level, `scanJobPodTemplate*` is under
  `trivyOperator:`) — documented in the runbook.

## Findings triage (accepted risk)

A scanner reports **findings**, not breaches. On a 2-node LAN-only homelab the
operator surfaced 897 vulnerabilities / 140 misconfigs on first scan. We adopt an
explicit triage policy instead of chasing a zero count:

- **Remediate what we own and can fix cheaply.** The one actionable hotspot was
  the demo workload `podinfo` pinned to an old image (`6.7.1`: **6 Critical + 36
  High**). Bumped to `6.15.0` → **0 Critical, 0 High, 0 Medium, 0 Low** for that
  image (commit `71c3d02`). Cluster-wide Criticals went **6 → 0**.
- **Accept upstream/system-image findings.** The bulk of the count lives in
  base/OS packages of images we do not build (k3s `coredns`/`metrics-server`,
  Flux controllers, `kube-state-metrics`, `klipper-helm`). These are remediated by
  keeping the platform current (k3s/Flux/kube-prometheus-stack upgrades), not by
  per-CVE action. Most are `Unknown` severity (scanner could not assign a rating).
- **RBAC (73 cluster-role + 11 role) and config-audit (140)** findings are
  predominantly on required system objects (`cluster-admin`, `system:*`,
  monitoring/kube-system components). Reviewed and **accepted**; the only
  workload we own (`podinfo`) is already `restricted`-compliant.
- **Exposed Secrets = 0** maintained.

Accepted findings are re-reviewed when the platform is upgraded, not chased
individually. The dashboard (`Number and Type of Security Issues`) is read by
**severity** (Critical/High first), not by the raw total.

## References
- [runbook 08](../runbooks/08-security-hardening.md) (execution + verification)
- [system-inventory — Security](../system-inventory.md#security-phase-7)
- [ADR-0007 — Phase 7 security hardening](0007-security-hardening.md)
- [Trivy Operator](https://github.com/aquasecurity/trivy-operator) · chart `0.37.0`
- [Grafana dashboard 17813](https://grafana.com/grafana/dashboards/17813)
- [troubleshooting-log](../troubleshooting-log.md) — PSS values nesting; flux-system label revert
