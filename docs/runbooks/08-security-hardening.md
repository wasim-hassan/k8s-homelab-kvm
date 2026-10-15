# Runbook 08 — Phase 7: Security hardening (trivy, PSS, RBAC, secrets hygiene)

**Goal:** Add a minimal, verifiable security posture to the cluster using a single FOSS scanner. Harden podinfo to `restricted`, enforce PSS on app/infra namespaces, apply least-privilege for podinfo, audit secrets, document exceptions.

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
- `flux-system` is Flux Operator–owned. Operator sets `warn: restricted` (verified); enforce+audit applied imperatively: `kubectl label ns flux-system pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/audit-version=latest --overwrite`.
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

## Notes / exceptions
- Flux-system namespace labels set imperatively (operator-owned, SSA/annotation `kustomize.toolkit.fluxcd.io/ssa: Ignore`). Documented in ADR-0007.
- monitoring node-exporter exception: requires privileged; baseline warn/audit to surface gaps.
- trivy 0.75.0 pinned (post malicious 0.69.4). Image/vuln/SBOM via `trivy image/fs` deferred to Phase 8.
- Accepted deviations live in [`.trivyignore`](../../.trivyignore): `DS-0026` (no HEALTHCHECK — workspace image), `KSV-0020`/`KSV-0021` (podinfo UID/GID 100/101 — image's own non-root user), `KSV-0125` (ghcr.io registry — trusted here). Rationale in [ADR-0007](../adr/0007-security-hardening.md#accepted-deviations-trivyignore).
- After acceptances `trivy config . --skip-dirs .git` reports **0 findings** (exit 0).
- No NetworkPolicy added (deferred to Phase 4/Cilium per roadmap).