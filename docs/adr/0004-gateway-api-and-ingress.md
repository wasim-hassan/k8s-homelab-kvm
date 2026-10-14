# ADR-0004: Ingress / Gateway API strategy

- **Status:** Accepted — 2026-10-14 (**Envoy Gateway**)
- **Date:** 2026-10-13
- **Deciders:** wasim (with AI assistant review)

## Context

Exposing HTTP(S) services inside a cluster needs an *ingress/Gateway*
implementation. Two things are already true in this cluster:

1. **Traefik is disabled.** The k3s server was installed with
   `--disable traefik` ([runbook 01](../runbooks/01-install-k3s.md)), so k3s ships
   no ingress controller. The host also has no ingress pods:
   `kubectl get pods -A | grep -iE 'ingress|gateway|traefik'` → none.

2. **The Gateway API v1 CRDs are installed, but with no controller.** A
   `helm-install-gateway-api-crd` Job exists in `kube-system`, and the cluster has
   the standard CRDs:
   ```
   gatewayclasses.gateway.networking.k8s.io      (v1)
   gateways.gateway.networking.k8s.io            (v1)
   httproutes.gateway.networking.k8s.io          (v1)
   grpcroutes / tcproutes / tlsroutes / udproutes
   referencegrants / backendtlspolicies / listenersets
   ```
   Verified with `kubectl get crd | grep -i gateway`. There is **no
   GatewayClass** and no controller Deployment, so the CRDs are currently inert —
   nothing is serving traffic.

**Unrecorded provenance.** The Gateway API CRDs were installed out-of-band (a
Helm Job, not one of this repo's scripts — `grep helm scripts/*` is empty). The
**original rationale for installing them was never written down**, so this ADR
records the *verified state* and defers the *decision* rather than inventing a
reason.

## Decision

**Accepted (2026-10-14): use the Gateway API**
(https://gateway-api.sigs.k8s.io/) as the north-south abstraction (the CRDs are
already present) and install **Envoy Gateway** as the controller, delivered
*via* Flux (HelmRelease). Tracked as
[Decision 3](../roadmap.md#resolved-decisions-2026-10-14).

Rationale: CNCF-hosted and Apache-2.0 (strong FOSS story), full Gateway API
support, and it keeps the ingress choice **independent** of the CNI choice (no
coupling to the skipped Cilium migration).

> **History:** this ADR was first filed as *Proposed / deferred* on 2026-10-13;
> the options are retained below. The decision was made in Phase 3.

### Options

| Option | API | FOSS | Notes |
|---|---|---|---|
| **Envoy Gateway** | Gateway API | ✅ CNCF | Dedicated Gateway API impl; no CNI change; clean FOSS story |
| **Cilium Gateway API** | Gateway API | ✅ CNCF | Also replaces Flannel/kube-proxy — but changing CNI ≈ reinstalling k3s (roadmap item) |
| **nginx Gateway Fabric** | Gateway API | ✅ | Gateway API flavor of NGINX |
| **ingress-nginx** | Ingress (not Gateway API) | ✅ | Simplest, most docs; ignores the CRDs already installed |
| **Traefik** (re-enable) | both | ✅ | Would reverse the Phase 1 "Traefik disabled" decision |

## Rationale

- The Gateway API CRDs are already in the cluster, so honoring them avoids
  throwing away existing state and teaches the modern, role-oriented API.
- Keeping the ingress choice *separate* from the CNI choice means the first
  workload isn't blocked on the bigger Cilium migration.
- Deferring avoids installing a controller before there is any workload to route.

## Consequences

**Positive**
- First workload can be exposed through whichever controller Phase 3 picks,
  managed entirely by Flux (HelmRelease).
- No premature vendor/tech lock-in for ingress.

**Negative — accepted risks**
- **Idle CRDs.** The Gateway API CRDs sit unused until a controller is installed;
  a `Gateway` object would stay `Pending` with no `GatewayClass`.
- **Extra provisioning step.** Phase 3 must install + configure a controller
  before the first HTTPRoute can serve.
- **Undocumented history.** Because the CRD install was out-of-band, the
  "why" may never be known — treat the CRDs as pre-existing state, not a design
  commitment.

## Verification (current state)

```bash
kubectl get crd | grep -i gateway        # CRDs present
kubectl get gatewayclass                 # none (no controller installed)
kubectl get pods -A | grep -iE 'ingress|gateway|traefik'   # no controller
```

## Revisit when

- **Done — Phase 3 (2026-10-14):** controller chosen = **Envoy Gateway**, to be
  installed via Flux. Record the concrete chart version in
  [system-inventory.md](../system-inventory.md) once installed.
- Cilium ever gets scheduled — then reconsider whether Cilium should be the
  Gateway API controller, collapsing two decisions into one (currently skipped —
  see the [roadmap](../roadmap.md#resolved-decisions-2026-10-14)).
