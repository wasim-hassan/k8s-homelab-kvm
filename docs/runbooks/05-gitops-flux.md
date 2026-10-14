# Runbook 05 — GitOps with Flux CD, SOPS/age, Envoy Gateway and podinfo

**Goal:** describe the exact GitOps setup on this cluster: Flux CD bootstrapped with a read-only deploy key, app-of-apps (flux-system/infrastructure/apps), SOPS+age decryption, Envoy Gateway (v1.9.2) via OCI+HelmRelease, and the first workload (podinfo) with requests/limits, HTTPRoute, ReferenceGrant, and an encrypted Secret decrypted in-cluster.

**Scope:** this documents what exists in the repo and cluster at `main@sha1:46196596` (HEAD 2026-10-14 18:25 UTC).

## Topology

| Component | Namespace | Source |
|---|---|---|
| Flux CD (controllers) | `flux-system` | installed by `flux bootstrap github` (v2.9.6) |
| Git source | `flux-system` (GitRepository `flux-system`) | `ssh://git@github.com/wasim-hassan/k8s-homelab-kvm` branch `main` |
| OCI source | `envoy-gateway-system` (OCIRepository `gateway-helm`) | `oci://docker.io/envoyproxy/gateway-helm` tag `v1.9.2@sha256:be034275` |
| App-of-apps | `flux-system` | `clusters/k8s-homelab/{kustomization.yaml,infrastructure.yaml,apps.yaml}` |
| Infrastructure (EG) | `envoy-gateway-system` | `infrastructure/envoy-gateway/{namespace,ocirepository,helmrelease,gatewayclass,gateway}.yaml` (Helm chart 1.9.2+be034275b55d) |
| Workload (podinfo) | `podinfo` | `apps/podinfo/{namespace,secret.sops.yaml,deployment,service,httproute,referencegrant}.yaml` |

## Preconditions

- Cluster healthy: 2 nodes Ready (k8s-cp-01, k8s-worker-01).
- Workspace reachable (`devpod ssh k8s-homelab-kvm`).
- Git repo at `/home/wasim/Sync/Repos/k8s-homelab-kvm` (clean, HEAD=4619659).
- `flux`/`sops`/`age` in workspace; age key at `~/.config/sops/age/keys.txt` (mode 600, never committed).
- `.sops.yaml` present with correct recipient.

## Execution order

### 1. Bootstrap Flux (completed)
- Used `flux bootstrap github --owner=wasim-hassan --repository=k8s-homelab-kvm --branch=main --path=clusters/k8s-homelab --personal --token-auth=false` with deploy key (read-only default). Controllers: source/kustomize/helm/notification (v2.9.6). Synced to `main@sha1:f23e2d6`, `df1643d`.
- Output under `clusters/k8s-homelab/flux-system/{gotk-components.yaml,gotk-sync.yaml,kustomization.yaml}`.

### 2. SOPS/age (completed)
- `age-keygen` → `~/.config/sops/age/keys.txt`. Public recipient in `.sops.yaml`.
- `kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/home/dev/.config/sops/age/keys.txt` (out-of-band). 
- Decryption wired on `infrastructure` and `apps` Kustomizations (`spec.decryption.provider=sops`, `secretRef.name=sops-age`).
- Demo secret `apps/podinfo/secret.sops.yaml` encrypted; Flux decrypts in-cluster → `podinfo-message` has `PODINFO_UI_MESSAGE: Hello from an SOPS-encrypted secret via Flux!`.

### 3. Envoy Gateway (completed)
- `infrastructure/envoy-gateway/namespace.yaml`, `ocirepository.yaml` (gateway-helm v1.9.2), `helmrelease.yaml` (chart 1.9.2+be034275b55d), `gatewayclass.yaml` (controller `gateway.envoyproxy.io/gatewayclass-controller`), `gateway.yaml` (listener HTTP:80, allowedRoutes All), `kustomization.yaml`.
- `infrastructure/kustomization.yaml` references `envoy-gateway/`; `infrastructure.yaml` Kustomization (flux-system) applies it with decryption.
- Gateway `eg` in `envoy-gateway-system` becomes Programmed (address `192.168.123.11`), GatewayClass Accepted.

### 4. First workload (completed)
- `apps/podinfo/` with requests/limits (Deployment), Service (ClusterIP 80→9898), HTTPRoute `podinfo.local` referencing Gateway `eg` in `envoy-gateway-system`, ReferenceGrant allowing HTTPRoute from `podinfo` to Gateway, SOPS secret, and `apps/kustomization.yaml`.
- `apps.yaml` Kustomization depends on `infrastructure`.

## Verification

### Host + workspace start
```bash
kvm; vm  # VMs running
cd ~/Sync/Repos/k8s-homelab-kvm && devpod up . --ide none
```

### Cluster + Flux
```bash
devpod ssh k8s-homelab-kvm --command 'kubectl get nodes -o wide'
devpod ssh k8s-homelab-kvm --command 'flux get kustomizations -A'
devpod ssh k8s-homelab-kvm --command 'flux get sources all -A'
devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get pods'
```

### Envoy Gateway
```bash
devpod ssh k8s-homelab-kvm --command 'kubectl -n envoy-gateway-system get gatewayclass,gateway,helmrelease,svc'
```

### Podinfo + SOPS
```bash
devpod ssh k8s-homelab-kvm --command 'kubectl -n podinfo get all,httproute,referencegrant'
devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get secret sops-age -o jsonpath="{.metadata.name}"'
devpod ssh k8s-homelab-kvm --command 'kubectl -n podinfo get secret podinfo-message -o jsonpath="{.data.PODINFO_UI_MESSAGE}" | base64 -d; echo'
```

### Routing test
```bash
devpod ssh k8s-homelab-kvm --command 'curl -sS -H "Host: podinfo.local" http://192.168.123.11/ | jq -r ".message"'
# Expected: Hello from an SOPS-encrypted secret via Flux!
```

## Outputs

- Kustomizations: flux-system/apps/infrastructure READY at `main@sha1:46196596`
- Gateway: Programmed, address `192.168.123.11`
- Podinfo: pod Running, HTTPRoute Accepted+ResolvedRefs
- Decrypted secret present; routing returns expected message

## Troubleshooting (recorded)

- **Duplicate `upgrade:` key** (2026-10-14): `HelmRelease/envoy-gateway` had two `upgrade:` blocks → `kustomize build failed` on `main@sha1:8c55a7a`. Fixed in `4619659` by removing first block. Verify after fix with `flux get kustomization infrastructure`.
- **Post-reboot transient** (2026-10-14): after VM reboot, Flannel `subnet.env` missing, CoreDNS/metrics-server startup churn, DNS lookup `github.com` transient on CoreDNS — self-healed within minutes. No active errors.

## GitOps notes

- Root `clusters/k8s-homelab/kustomization.yaml` aggregates `flux-system`, `infrastructure.yaml`, `apps.yaml`.
- Infrastructure and apps Kustomizations reference `sops-age` secret for decryption; flux-system Kustomization does not need decryption.
- Deploy key is read-only (default); `sops-age` and age key are out-of-band (never committed).

## Shutdown (per runbook 03)

```bash
devpod stop
vm stop k8s-worker-01  # wait shut off
vm stop k8s-cp-01      # wait shut off
kvm off
```
