# ADR-0006: Flux is managed by the Flux Operator (for the Web UI)

- **Status:** Accepted
- **Date:** 2026-10-15
- **Deciders:** wasim (with AI assistant review)

## Context

Phase 6 was complete and Flux was bootstrapped with the **Flux CLI**
(`flux bootstrap github`), with Flux managed by the bootstrap manifests in
`clusters/k8s-homelab/flux-system/`. The request was for a **browser-launchable
Flux dashboard** — "a WebUI for Flux CD like Argo CD, Jenkins or Grafana have."

The options were researched from vendor sources:

| UI | Verdict |
|---|---|
| `fluxcd/webui` (Flux's own) | ✗ **Archived** — no longer developed. |
| **Weave GitOps** (classic Flux UI) | ✗ Last stable **v0.38.0 (Dec 2023)**; Weaveworks shut down Feb 2024; repo "transitioning to community-driven". Critically, **it cannot read HelmRelease `v2`** (it still queries the deprecated `v2beta1` API) — this cluster runs HelmRelease **v2**, so its application views would be broken. Ruled out. |
| Generic k8s UIs (Headlamp/Lens/Kubernetes Dashboard) | ✗ Not GitOps-aware (show CRDs, no Flux semantics). |
| **Flux Operator Web UI** (`fluxoperator.dev`) | ✓ **Actively maintained (2026)** by the Flux core maintainers (ControlPlane); Argo CD-style status, delivery graph, logs, and reconcile/suspend/resume actions. Requires the **Flux Operator**. |

The Web UI is embedded in the Flux Operator, and the vendor states the UI is
**officially supported only on clusters managed by the Flux Operator**. So using
it means either (a) adopting the operator (migrating Flux) or (b) an unsupported
UI-only install. The migration from a CLI-bootstrapped cluster is documented as
**zero-downtime**: install the operator, create a `FluxInstance` mirroring the
bootstrap, and the operator adopts the Flux components, GitRepository and
Kustomization.

## Decision

**Adopt the Flux Operator** and let it manage Flux via a `FluxInstance`, to gain
the supported Flux Web UI.

- Operator installed declaratively (`infrastructure/flux-operator/`): OCIRepository
  - HelmRelease, chart **0.61.0**.
- `FluxInstance flux` mirrors the original bootstrap (same repo/branch/path and
  `pullSecret`), so adoption is transparent.
- The repo-managed Flux manifests (`clusters/k8s-homelab/flux-system/`) are
  **removed** — the operator owns Flux now. This is safe because the operator
  marks its objects `kustomize.toolkit.fluxcd.io/prune: Disabled`.
- The Web UI is exposed at `flux.local` through the existing Envoy Gateway, and
  bound to the built-in `flux-web-admin` role via an **anonymous** identity
  (host-only reachability, no SSO).

## Rationale / alternatives considered

| Alternative | Verdict |
|---|---|
| **Keep CLI-bootstrapped Flux, no UI** | ✓ Valid, and the fallback. But it leaves the stated goal unmet; the CLI + k9s remain available regardless. |
| **Weave GitOps** | ✗ Unmaintained and broken against HelmRelease `v2` on this cluster. |
| **Flux Operator, UI-only (unsupported)** | ✗ Works but is explicitly unsupported by the maintainers and still needs the operator CRDs; not worth the fragility. |
| **Flux Operator + FluxInstance (chosen)** | ✓ Supported, zero-downtime, and future-proofs Flux upgrades (the operator manages the distribution). |
| **SSO (Dex/Keycloak) now** | ✗ Adds a whole identity stack to a 2-node lab; deferred until there is more than one user or the UI leaves the host. |

The Web UI costs one extra Deployment (`flux-operator`, ~64 Mi request). The
cluster has headroom after the Phase 6 sizing bump.

## Consequences

**Positive**

- A real, maintained, browser-based Flux dashboard (status, graph, actions).
- Flux is now managed from a single `FluxInstance`; the operator handles upgrades
  and keeps the components/source in sync.
- No new host or workspace tooling — the operator runs in-cluster, installed by Flux.

**Negative**

- **Phase 3 architecture changed:** Flux is no longer bootstrapped by the Flux CLI;
  the `flux-system/` bootstrap directory is gone. `flux bootstrap` is no longer the
  upgrade path — the `FluxInstance` distribution version is.
- The Web UI is **anonymous** by default. Mitigated by host-only reachability
  through the Gateway; SSO is the upgrade if exposure grows.
- One more controller to run and reason about.

**Neutral**

- The `flux` CLI still works for day-to-day status (`flux get`, `flux trace`);
  `flux trace kustomization flux-system` now reports "not managed by Flux", which
  is expected.

## Revisit when

- The Web UI needs to be reachable beyond the host — add **TLS + SSO** (Dex or
  Keycloak) and least-privilege RBAC instead of anonymous `flux-web-admin`.
- A first-party Flux UI ships — re-evaluate against the operator's UI.
- The cluster grows — reconsider whether a full Flux Operator (vs. CLI bootstrap)
  still matches the "lightweight" preference.
