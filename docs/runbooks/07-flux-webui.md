# Runbook 07 — Flux Web UI (Flux Operator)

**Goal:** run a browser-based Flux dashboard (Argo CD-style) by migrating Flux to
be managed by the **Flux Operator**, and expose its **Flux Status Web UI** at
`flux.local` through the existing Envoy Gateway.

**Scope:** documents what exists in the repo and cluster at
`main@sha1:4271ca66` (HEAD 2026-10-15). The Web UI is anonymous (read-only by
default); it is bound to the built-in `flux-web-admin` role so reconciles and
other actions are available, and it is only reachable from the host via the
Gateway.

> **Why the operator?** There is no first-party Flux UI (`fluxcd/webui` is
> archived), and **Weave GitOps** is unmaintained and cannot read HelmRelease
> `v2` (it still calls the deprecated `v2beta1` API — we run HelmRelease `v2`).
> The **Flux Operator** (by the Flux core maintainers) is the only actively
> maintained Flux UI, and the migration from a CLI-bootstrapped cluster is
> **zero-downtime**. See [ADR-0006](../adr/0006-flux-operator-managed.md).

## Topology

| Component | Namespace | Source |
|---|---|---|
| Flux Operator (chart `0.61.0`, app v0.61.0) + Web UI | `flux-system` | `infrastructure/flux-operator/` → OCIRepository `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` + HelmRelease `flux-operator` |
| FluxInstance `flux` (adopts the Flux components + source) | `flux-system` | `clusters/k8s-homelab/flux-instance/` → Kustomization `flux-instance` |
| Web UI route | `flux-system` → `envoy-gateway-system` | HTTPRoute `flux-operator` host `flux.local` (created by the chart's `web.httpRoute` values) + ReferenceGrant `allow-flux-system-to-gateway` |
| Web UI identity | cluster | anonymous user `admin` in group `flux-admin` → ClusterRoleBinding `flux-admin` → ClusterRole `flux-web-admin` |

## Preconditions

- Cluster healthy: 2 nodes Ready (`k8s-cp-01` 192.168.123.11, `k8s-worker-01` 192.168.123.12).
- Phase 3 complete: Flux Kustomizations `flux-system` / `infrastructure` / `apps` Ready.
- Envoy Gateway `eg` Programmed at `192.168.123.11`.
- Workspace reachable (`devpod ssh k8s-homelab-kvm`); `flux` v2.9.6 present.

## Execution order

### 1. Install the operator (no Flux migration yet)
`infrastructure/flux-operator/` holds:
- `ocirepository.yaml` — OCIRepository `flux-operator`, tag pinned **`0.61.0`**.
- `helmrelease.yaml` — HelmRelease `flux-operator` (releaseName `flux-operator`)
  with `install.crds: Create` / `upgrade.crds: CreateReplace` and values:
  - `web.enabled: true`
  - `web.httpRoute.enabled: true` → `parentRefs: [{name: eg, namespace:
    envoy-gateway-system}]`, `hostnames: ["flux.local"]`
  - `web.config.authentication` = anonymous `admin` in group `flux-admin`
  - trimmed `resources` (`100m/64Mi` requests, `500m/256Mi` limits)
- `rbac.yaml` — ClusterRoleBinding `flux-admin` → `flux-web-admin`
  (the ClusterRole is created by the operator).
- `referencegrant.yaml` — in `envoy-gateway-system`, allow HTTPRoutes from
  `flux-system` to Gateway `eg`.
- `kustomization.yaml` — aggregates the above.
- `infrastructure/kustomization.yaml` gains `- flux-operator`.

### 2. Adopt Flux with a FluxInstance (separate Kustomization!)
`clusters/k8s-homelab/flux-instance/` holds `fluxinstance.yaml` — a `FluxInstance`
named `flux` mirroring the original `flux bootstrap` (distribution `2.9.x` @
`ghcr.io/fluxcd`; components source/kustomize/helm/notification; `sync` =
GitRepository `ssh://git@github.com/wasim-hassan/k8s-homelab-kvm`, branch `main`,
path `clusters/k8s-homelab`, `pullSecret: flux-system`).

It is applied by its **own** Kustomization `clusters/k8s-homelab/flux-instance.yaml`
with `dependsOn: [infrastructure]`.

> **Critical:** the FluxInstance must **not** live in the same directory as the
> operator install. `kustomize-controller` **dry-runs the entire resource set**
> before applying it, so a `FluxInstance` whose CRD does not exist yet aborts the
> whole apply (nothing is created). Splitting it into a `dependsOn` Kustomization
> guarantees the operator CRDs exist first. See the troubleshooting log.

### 3. Retire the repo-managed Flux manifests
Because the operator now owns the Flux components, GitRepository and Kustomization,
delete `clusters/k8s-homelab/flux-system/` (`gotk-components.yaml`,
`gotk-sync.yaml`) and drop `- flux-system` from
`clusters/k8s-homelab/kustomization.yaml`. This is safe: the operator annotates
every object it manages with `kustomize.toolkit.fluxcd.io/prune: Disabled`
(and `ssa: Ignore`), so the old Kustomization cannot prune the Flux CRDs or
controllers.

### 4. Commit and let Flux reconcile
```bash
cd /home/wasim/Sync/Repos/k8s-homelab-kvm
git add infrastructure clusters
git commit -m "feat(flux): add Flux Operator and adopt Flux via FluxInstance"
git push origin main
devpod ssh k8s-homelab-kvm --command \
  'flux reconcile source git flux-system && flux reconcile kustomization flux-system'
```

## Verification

### Operator + FluxInstance
```bash
devpod ssh k8s-homelab-kvm --command 'flux get helmreleases -A'      # flux-operator Ready
devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get fluxinstance'
# NAME   READY   STATUS                         REVISION
# flux   True    Reconciliation finished ...    v2.9.6@sha256:...
```

### Adoption (Flux now managed by the operator)
```bash
devpod ssh k8s-homelab-kvm --command 'flux trace kustomization flux-system'
# Expect: "object not managed by Flux"  ← the operator owns it now
devpod ssh k8s-homelab-kvm --command 'flux get kustomizations -A'    # all Ready
devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get deploy'
# helm/kustomize/notification/source controllers unchanged (no restarts) + flux-operator
devpod ssh k8s-homelab-kvm --command 'kubectl get crd | grep -c fluxcd'   # CRDs intact
```

### Route + UI
```bash
devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get httproute flux-operator'
devpod ssh k8s-homelab-kvm --command 'curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: flux.local" http://192.168.123.11/'   # Expect: 200
```

## Access the UI

Add the host to your workstation's `/etc/hosts` (one-time, needs sudo):
```
192.168.123.11 flux.local
```
Then browse to <http://flux.local>. No login is required (anonymous), and the UI
runs as the `flux-admin` group, which is bound to `flux-web-admin` (view +
reconcile/suspend/resume/restart actions).

> The UI is **not** exposed to the LAN/WAN — only via the Gateway address reachable
> from the host. Keep it that way; if it ever needs to be reachable more widely,
> add TLS + SSO (Dex/Keycloak) instead of leaving anonymous access open.

## Troubleshooting (recorded)

See [`troubleshooting-log.md`](../troubleshooting-log.md) for the full entry:
- **`no matches for kind "FluxInstance"` → the whole `infrastructure` apply
  aborted** — `kustomize-controller` dry-runs the set first, so the FluxInstance
  blocked the operator from being created. Fixed by moving the FluxInstance into a
  dedicated `dependsOn` Kustomization.

## GitOps notes

- The operator chart (`0.61.0`) is pinned in the OCIRepository; bump the tag to upgrade.
- The `FluxInstance` **is** the desired state of Flux itself — the operator
  reconciles the controllers, the GitRepository and the sync Kustomization from it.
- After migration, `flux-system` Kustomization objects carry
  `app.kubernetes.io/managed-by: flux-operator`.
- Rollback: remove `infrastructure/flux-operator` + `flux-instance`, restore
  `clusters/k8s-homelab/flux-system/`, and re-run `flux bootstrap` (minutes).

## Shutdown (per runbook 03)

```bash
devpod stop
vm stop k8s-worker-01  # wait shut off
vm stop k8s-cp-01      # wait shut off
kvm off
```
