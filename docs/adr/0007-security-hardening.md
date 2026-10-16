# ADR-0007 — Phase 7 security hardening

- **Status:** Accepted (2026-10-15)
- **Deciders:** AI + user
- **Context:** Harden the k8s-homelab-kvm cluster without over-engineering, using a single FOSS scanner and targeted Pod Security Standards.

## Decision

Adopt **Trivy v0.75.0** (pinned, checksum-verified in the devcontainer image) as the sole security scanner:
- Use `trivy config` for manifest/IaC policy checks (replaces kube-linter). 
- Secret scanning is available via `trivy fs --scanners secret` (no DB). 
- Image CVE, SBOM, and full secret/vuln scans are reserved for **Phase 8** (CI). 
- Pin ≥ 0.75.0 (post the 2026-03 malicious `0.69.4` incident); binary is installed in the workspace image with SHA256 against `trivy_0.75.0_checksums.txt`.

Apply **Pod Security Standards (PSS)** per namespace:
- `podinfo`: `enforce/restricted`, `warn/restricted`, `audit/restricted`. Deployment hardened: dedicated `ServiceAccount`, `automountServiceAccountToken: false`, `runAsNonRoot: true` + numeric `runAsUser:100`/`runAsGroup:101` + `fsGroup:101`, `seccompProfile: RuntimeDefault`, container `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`.
- `envoy-gateway-system`: `enforce/restricted`, `warn/restricted`, `audit/restricted`. Verified Envoy pods have no `hostPort`/`hostNetwork`/`hostPID` and only `configMap`/`secret`/`emptyDir`/`projected` volumes; all containers satisfy restricted.
- `flux-system` (Flux Operator–owned namespace): `enforce/restricted`, `warn/restricted`, `audit/restricted` applied **imperatively** (`kubectl label`), because the namespace is managed by the Flux Operator (`app.kubernetes.io/managed-by: flux-operator`) and the FluxInstance bootstraps/maintains the namespace's lifecycle. The controller pods in `flux-system` satisfy restricted; only Flux controllers run in that namespace (target workloads run elsewhere). This is documented as an intentional, reviewable exception to pure-GitOps management of that specific namespace label set. **⚠️ Amended 2026-10-15:** the imperative labels reverted after a VM restart, so they are now set **declaratively** via `FluxInstance.spec.commonMetadata.labels` — see [ADR-0008](0008-trivy-operator.md).
- `monitoring`: `enforce/privileged`, `warn/baseline`, `audit/baseline`. Rationale: `kube-prometheus-stack-prometheus-node-exporter` requires `hostNetwork: true`, `hostPID: true`, and `hostPath` volumes. No PSS level above privileged permits this; other monitoring components (Grafana, kube-state-metrics, operator, Prometheus) satisfy restricted. The baseline warn/audit layer surfaces anything beyond baseline while keeping the node-exporter exception explicit.

**RBAC**: No workload gets cluster-admin. Cluster-admin bindings remain limited to: `system:masters` (built-in), `cluster-reconciler-flux-system` (Flux kustomize/helm controllers), `flux-operator` (required), `helm-kube-system-gateway-api-crd` (CRD install job). The Flux Web UI uses `ClusterRoleBinding flux-admin` binding to `ClusterRole flux-web-admin` (not cluster-admin) and is host-only via Gateway (`flux.local`). `podinfo` now has its own `ServiceAccount` with token automount disabled and no Role/RoleBinding (no API access). All non-default ServiceAccounts were enumerated and only Flux/Gateway/monitoring system ServiceAccounts exist.

**Secrets hygiene**: `trivy fs --scanners secret` found 0 secrets. Only SOPS-encrypted secrets are tracked (`apps/podinfo/secret.sops.yaml`, `infrastructure/monitoring/secret.sops.yaml`). `.gitignore` covers `.env`, `*.agekey`, `keys.txt`, `tfstate`, `AGENTS.local.md`. `.sops.yaml` contains only the age public recipient; the private key is not committed (`~/.config/sops/age/keys.txt`).

## Consequences

- **Positive:** Single, production-standard tool (Trivy) covers manifest misconfig today; container/secret/SBOM coverage deferred cleanly to Phase 8. Targeted PSS hardens podinfo/envoy/flux while preserving node observability. Least-privilege RBAC for podinfo.
- **Negative:** Image `USER dev` added (non-root) and trivy checksum-verified install increases image size slightly. *(The `flux-system` namespace labels were originally set imperatively; since [ADR-0008](0008-trivy-operator.md) they are managed declaratively via `FluxInstance.spec.commonMetadata`.)*
- **Neutral:** The security posture is now verifiably enforced in app namespaces and audited in the target scope; `trivy config .` reports **0 findings** after acceptances.

## Accepted deviations (`.trivyignore`)

`trivy config` is clean (0 findings). The following are explicit, reviewed acceptances, located in [`.trivyignore`](../../.trivyignore):

| Check | Finding | Why accepted |
|---|---|---|
| `DS-0026` | No HEALTHCHECK | `.devcontainer/Containerfile` builds an operator **workspace**, not a long-running service. |
| `KSV-0020` / `KSV-0021` | UID/GID ≤ 10000 | podinfo runs as its image's own non-root user (uid 100/gid 101). PSS `restricted` requires non-root, not a UID > 10000; matching the image user avoids permission surprises. Enforced via numeric `runAsUser`/`runAsGroup`. |
| `KSV-0125` | Untrusted registry | `ghcr.io` is GitHub's FOSS registry (trusted here); the check's default list is Docker Hub-centric. Image pinned `ghcr.io/stefanprodan/podinfo:6.7.1`. |

## References
- [runbook 08](../runbooks/08-security-hardening.md) (execution details)
- [system-inventory](../system-inventory.md#security-phase-7)
- [trivy](https://github.com/aquasecurity/trivy) v0.75.0
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [ADR-0006](0006-flux-operator-managed.md)
- [ADR-0008 — Trivy Operator + Grafana dashboard](0008-trivy-operator.md) (amends the `flux-system` label handling)
