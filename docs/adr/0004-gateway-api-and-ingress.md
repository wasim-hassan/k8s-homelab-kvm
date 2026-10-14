# ADR-0004: Ingress / Gateway API strategy

- **Status:** Proposed (decision deferred to Phase 3 — GitOps)
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

**Deferred.** No ingress/Gateway controller is installed yet. This ADR records
the state and the options so Phase 3 can make an explicit choice before the first
workload is exposed.

**Proposed direction (to confirm in Phase 3):** use the **Gateway API** as the
north-south abstraction (the CRDs are already present) and install a FOSS
controller.

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

- **Phase 3** — install the chosen controller via Flux and supersede this ADR
  with `Accepted` (record the concrete controller + version). This decision is
  tracked, with options and a recommendation, in
  [Open decision 3](../roadmap.md#open-decision-3--ingress--gateway-controller)
  of the [roadmap](../roadmap.md).
- Cilium migration is scheduled — then reconsider whether Cilium should be the
  Gateway API controller, collapsing two decisions into one.
