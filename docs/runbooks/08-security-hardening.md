# Runbook 08 — Phase 7 / 7b: Security hardening + continuous scanning (trivy, PSS, RBAC, Trivy Operator)

**Goal:** Add a minimal, verifiable security posture to the cluster using a single FOSS scanner. Harden podinfo to `restricted`, enforce PSS on app/infra namespaces, apply least-privilege for podinfo, audit secrets, document exceptions. **Phase 7b:** add the **Trivy Operator** for continuous in-cluster scanning and surface its results in Grafana (the "web UI").

**Topology:** 2-node k3s (`k8s-cp-01` 192.168.123.11, `k8s-worker-01` 192.168.123.12), Devpod workspace, GitOps (Flux Operator + FluxInstance).

**Preconditions:** Phases 0–6 done; cluster healthy (`kubectl get nodes -o wide` Ready); Flux Healthy; podinfo accessible at `podinfo.local`. Workspace rebuilt with `trivy 0.75.0` (checksum-verified). No secrets in git.

## 01. Scanner (trivy) — baseline
- Verify: `trivy --version` → `Version: 0.75.0`.
- Scan manifests (no vuln DB): `trivy config . --skip-dirs .git` (record findings). Adopted `trivy config` as kube-linter replacement; image/vuln/SBOM deferred to Phase 8.
- Containerfile update: checksum-verified tarball, `USER dev` added (addresses `DS-0002`). `DS-0026` (no HEALTHCHECK) accepted for dev workspace.

## 02. RBAC audit & fixes
- Audit cluster-admin holders: `kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + ([.subjects[]|.kind+":"+ .name]|join(","))'`. Expect: `cluster-admin` (system:masters), `cluster-reconciler-flux-system` (kustomize+helm controllers), `flux-operator` (flux-operator SA), `helm-kube-system-gateway-api-crd` (CRD job) — all required. No stray bindings.
- podinfo: add `ServiceAccount podinfo` (ns `podinfo`), `automountServiceAccountToken: false`, no Role/RoleBinding (no API access). Add `spec.template.spec.serviceAccountName: podinfo` + `automountServiceAccountToken: false` at pod level.
- Enumerate non-default SAs: `kubectl get sa -A --no-headers | grep -v "default "`. Only Flux/Gateway/monitoring/kube-system components.
- Flux Web UI binding remains `ClusterRoleBinding flux-admin → ClusterRole flux-web-admin` (not cluster-admin); host-only exposure `flux.local`.

## 03. Pod Security Standards
- Harden podinfo: pod `securityContext` with `runAsNonRoot: true`, numeric `runAsUser:100`, `runAsGroup:101`, `fsGroup:101`, `seccompProfile.type: RuntimeDefault`. Container `securityContext`: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`. (podinfo runs as uid `100(app)` from image.)
- Apply namespace labels (GitOps where possible, imperative where operator-owned):
  - `apps/podinfo/namespace.yaml`: `pod-security.kubernetes.io/enforce=restricted`, `warn=restricted`, `audit=restricted`.
  - `infrastructure/envoy-gateway/namespace.yaml`: same (restricted).
  - `infrastructure/monitoring/namespace.yaml`: `enforce=privileged`, `warn=baseline`, `audit=baseline` (node-exporter needs `hostNetwork`/`hostPID`/`hostPath`; other monitoring pods satisfy restricted).
- `flux-system` is Flux Operator–owned. The PSS labels are set **declaratively** via `FluxInstance.spec.commonMetadata.labels` (see §08) — **not** imperatively (that approach reverts; see §08). The operator re-applies them on every reconcile.
- Dry-run/rollout: `flux reconcile kustomization apps --with-source` → `kubectl -n podinfo rollout status deploy/podinfo --timeout=60s` (OK). `flux reconcile kustomization infrastructure --with-source`. All pods in affected namespaces `Running`.
- Verify PSS labels: `kubectl get ns -o custom-columns=NAME:.metadata.name,PSS-ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce,PSS-WARN:.metadata.labels.pod-security\.kubernetes\.io/warn,PSS-AUDIT:.metadata.labels.pod-security\.kubernetes\.io/audit`.

## 04. Secrets hygiene
- `trivy fs --scanners secret . --skip-dirs .git` → 0 secrets.
- Only SOPS ciphertext tracked: `apps/podinfo/secret.sops.yaml`, `infrastructure/monitoring/secret.sops.yaml`. `.sops.yaml` has only public age recipient. `.gitignore` blocks `.env`, `*.agekey`, `keys.txt`, `tfstate`, `AGENTS.local.md`.
- No private age key (`~/.config/sops/age/keys.txt`) committed.

## 05. Verification (end-to-end)
- Nodes Ready: `kubectl get nodes`.
- Workloads: `kubectl get pods -A | grep -v Running | grep -v Completed` → empty (expect Completed for some jobs; Running all others).
- RBAC: cluster-admin holders exactly the 4 above; podinfo has no RoleBindings; SA automount disabled.
- PSS: `podinfo, envoy-gateway-system, flux-system` restricted-enforced/audited; `monitoring` privileged+baseline warn/audit.
- URLs: `curl -I http://podinfo.local` 200; `curl -I http://grafana.local`/`flux.local` reachable (host `/etc/hosts`).
- Scanner: `trivy --version` 0.75.0; `trivy config . --skip-dirs .git` runs (baseline recorded).

## 06. Docs + commit
- ADR-0007 written. Runbook 08 written. Update `docs/system-inventory.md` (Security Phase 7 section: RBAC matrix, PSS table, scanner). Update `docs/roadmap.md` (Phase 7 status → done or next steps noted), `docs/README.md`, `AGENTS.md` if index changes.
- Commit: `feat(security): Phase 7 hardening (trivy, PSS, RBAC for podinfo)` + follow-up fix for numeric runAsUser. Push from host.

## 07. Phase 7b — Trivy Operator (continuous scanning) + Grafana dashboard
**Goal:** continuous, in-cluster scanning of running workloads, viewed in Grafana. See [ADR-0008](../adr/0008-trivy-operator.md). Trivy has no official web UI; the "UI" is a Grafana dashboard fed by the operator's Prometheus metrics.
- **Manifests** ([`infrastructure/trivy-operator/`](../../infrastructure/trivy-operator)): `namespace.yaml` (`trivy-system`, PSS `restricted` ×3), `helmrepository.yaml` (`aqua`), `helmrelease.yaml` (chart **0.37.0**, app v0.35.0), `kustomization.yaml`. Wired into `infrastructure/kustomization.yaml`.
- **Values that matter** (nesting is sharp — verify with `helm template`):
  - top-level: `serviceMonitor.enabled` + `serviceMonitor.labels.release=kube-prometheus-stack`, `resources`, `podSecurityContext`, `securityContext`.
  - `operator:` `scanJobsConcurrentLimit: 2`, `scanJobTimeout: 5m`, `metrics*Info: true`, **`infraAssessmentScannerEnabled: false`** (node-collector needs hostPath+root).
  - `trivyOperator:` `scanJobPodTemplatePodSecurityContext` + `scanJobPodTemplateContainerSecurityContext` (numeric non-root uid 10000, RuntimeDefault, drop ALL, roFS).
  - `trivy:` `mode: Standalone`, `ignoreUnfixed: true`, `imageScanCacheDir: /tmp/trivy/.cache`.
- **Dashboard:** [`infrastructure/monitoring/dashboards/trivy-operator-dashboard.yaml`](../../infrastructure/monitoring/dashboards/trivy-operator-dashboard.yaml) — Grafana dashboard **17813**, `__inputs`/`__requires` stripped, `${DS_PROMETHEUS}` → `prometheus`, `ConfigMap` labelled `grafana_dashboard: "1"`, annotation `kustomize.toolkit.fluxcd.io/substitute: disabled`.
- **Deploy:** commit → push → `flux reconcile source git flux-system` + `flux reconcile kustomization infrastructure --with-source`.
- **Verify:**
  - `kubectl -n trivy-system get helmrelease trivy-operator` → `Ready=True`, chart `0.37.0`.
  - `kubectl -n trivy-system get pods` → operator `1/1 Running`.
  - Reports appear: `kubectl get vulnerabilityreports,configauditreports,exposedsecretreports,rbacassessmentreports -A`.
  - `kubectl get infraassessmentreports -A` → **0** (infra assessment disabled) and no node-collector jobs.
  - Prometheus scrapes it: ServiceMonitor labelled `release=kube-prometheus-stack`; the active Prometheus scrape config contains `trivy-operator` targets.
  - Grafana → *Trivy Operator Dashboard* (admin creds from the SOPS `grafana-admin` secret) at `http://grafana.local`.

## 08. flux-system PSS labels — declarative (fix)
- The `enforce`/`audit` labels applied imperatively in §03 **reverted after a VM restart** (namespace is Flux-Operator–owned).
- Fix: add `spec.commonMetadata.labels` (the six PSS labels) to the `FluxInstance` ([`clusters/k8s-homelab/flux-instance/fluxinstance.yaml`](../../clusters/k8s-homelab/flux-instance/fluxinstance.yaml)). The operator re-applies them on every reconcile.
- **Verify:** `kubectl get ns flux-system -o jsonpath="{.metadata.labels}"` → all six PSS labels present; `kubectl -n flux-system get fluxinstance flux` → `Ready=True`.


## Notes / exceptions
- Flux-system namespace labels are now set **declaratively** via `FluxInstance.spec.commonMetadata.labels` (the earlier imperative approach reverted after a restart — see §08 and [ADR-0008](../adr/0008-trivy-operator.md)).
- monitoring node-exporter exception: requires privileged; baseline warn/audit to surface gaps.
- Trivy Operator (Phase 7b): infra-assessment/node-collector **disabled** (needs hostPath+root, incompatible with `restricted`) — image/config/secret/RBAC scans only. See [ADR-0008](../adr/0008-trivy-operator.md).
- trivy 0.75.0 pinned (post malicious 0.69.4). Image/vuln/SBOM via `trivy image/fs` deferred to Phase 8.
- Accepted deviations live in [`.trivyignore`](../../.trivyignore): `DS-0026` (no HEALTHCHECK — workspace image), `KSV-0020`/`KSV-0021` (podinfo UID/GID 100/101 — image's own non-root user), `KSV-0125` (ghcr.io registry — trusted here). Rationale in [ADR-0007](../adr/0007-security-hardening.md#accepted-deviations-trivyignore).
- After acceptances `trivy config . --skip-dirs .git` reports **0 findings** (exit 0).
- No NetworkPolicy added (deferred to Phase 4/Cilium per roadmap).