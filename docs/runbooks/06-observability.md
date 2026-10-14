# Runbook 06 — Observability stack (kube-prometheus-stack) via Flux

**Goal:** deploy a lightweight metrics + dashboard stack (`kube-prometheus-stack`)
declaratively through Flux, expose Grafana at `grafana.local` through the existing
Envoy Gateway, and prove Prometheus scrapes the cluster — all sized for a 2-node
lab (3 GiB + 1536 MiB).

**Scope:** documents what exists in the repo and cluster at `main@sha1:1f798951`
(HEAD 2026-10-15). Alertmanager is intentionally **disabled** (no notification
target; saves memory).

## Topology

| Component | Namespace | Source |
|---|---|---|
| kube-prometheus-stack (Prometheus, Grafana, operator, kube-state-metrics, node-exporter) | `monitoring` | `infrastructure/monitoring/` → HelmRelease via `HelmRepository prometheus-community` |
| Prometheus PVC | `monitoring` | `local-path` StorageClass, 2Gi |
| Grafana route | `monitoring` → `envoy-gateway-system` | HTTPRoute `grafana` host `grafana.local` + ReferenceGrant `allow-monitoring-to-gateway` |
| Grafana admin | `monitoring` | SOPS-encrypted `grafana-admin` Secret (`admin-user` / `admin-password`) |

## Preconditions

- Cluster healthy: 2 nodes Ready (`k8s-cp-01` 192.168.123.11, `k8s-worker-01` 192.168.123.12).
- Phase 3 complete: Flux Kustomizations `flux-system` / `infrastructure` / `apps` Ready.
- Envoy Gateway `eg` Programmed at `192.168.123.11`.
- `k3s` StorageClass `local-path` (default) present.
- Workspace reachable (`devpod ssh k8s-homelab-kvm`); `sops`/`age` available; age key at `~/.config/sops/age/keys.txt`.

## Execution order

### 1. Trim the chart for the small cluster (Decision 4)
- Chose `kube-prometheus-stack` chart **92.7.0** (app v0.94.1) and trimmed values
  inline in the HelmRelease:
  - `alertmanager.enabled: false`
  - `prometheus.prometheusSpec`: `retention: 6h`, `retentionSize: 1500MB`,
    requests/limits, and a 2Gi `volumeClaimTemplate` on `local-path`
  - explicit requests/limits for operator, Grafana, kube-state-metrics, node-exporter
  - `grafana.fullnameOverride: grafana` (stable Service name for the route)

### 2. Manifests (all under `infrastructure/monitoring/`)
- `namespace.yaml` — `monitoring`
- `helmrepository.yaml` — `prometheus-community` (`https://prometheus-community.github.io/helm-charts`)
- `helmrelease.yaml` — `kube-prometheus-stack` 92.7.0 with the trimmed values;
  `install.crds: Create`, `upgrade.crds: CreateReplace` (chart ships 20 CRDs)
- `secret.sops.yaml` — encrypted Grafana admin credentials
- `grafana-httproute.yaml` — host `grafana.local` → Service `grafana:80`
- `referencegrant.yaml` — in `envoy-gateway-system`, allow the `monitoring` HTTPRoute
- `kustomization.yaml` — aggregates the above
- `infrastructure/kustomization.yaml` gains `- monitoring`

### 3. Encrypt the Grafana secret
```bash
cd /home/wasim/Sync/Repos/k8s-homelab-kvm
# write plaintext secret.sops.yaml, then:
devpod ssh k8s-homelab-kvm --command \
  'cd /workspaces/k8s-homelab-kvm && sops -e -i infrastructure/monitoring/secret.sops.yaml'
```

### 4. Commit and let Flux reconcile
```bash
git add infrastructure/monitoring infrastructure/kustomization.yaml
git commit -m "feat(monitoring): add kube-prometheus-stack via Flux (Phase 6)"
git push origin main
devpod ssh k8s-homelab-kvm --command \
  'flux reconcile kustomization infrastructure -n flux-system --with-source'
```

## Verification

### HelmRelease + pods
```bash
devpod ssh k8s-homelab-kvm --command 'flux get helmreleases -A'
devpod ssh k8s-homelab-kvm --command 'kubectl -n monitoring get pods'
# Expect a Ready HelmRelease + 6 pods Running (grafana, operator, kube-state-metrics,
# 2x node-exporter, prometheus).
```

### PVC + Service + route
```bash
devpod ssh k8s-homelab-kvm --command 'kubectl -n monitoring get pvc,svc grafana,httproute'
```

### Prometheus targets
```bash
devpod ssh k8s-homelab-kvm --command 'kubectl -n monitoring get --raw \
  "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets"' \
  | python3 -c 'import sys,json;t=json.load(sys.stdin)["data"]["activeTargets"];print(len(t),"targets;",sum(x["health"]=="up" for x in t),"up")'
# Expect: 15 targets; 15 up
```

### Grafana through the gateway
```bash
devpod ssh k8s-homelab-kvm --command \
  'curl -s -H "Host: grafana.local" http://192.168.123.11/api/health'
# Expect: {"database":"ok","version":"13.2.4",...}
devpod ssh k8s-homelab-kvm --command \
  'curl -s -o /dev/null -w "%{http_code}\n" -H "Host: grafana.local" http://192.168.123.11/'
# Expect: 200
```

### Node memory after deploy
```bash
devpod ssh k8s-homelab-kvm --command 'kubectl top nodes'
# Observed: cp 1847Mi/2977Mi (63%), worker 903Mi/1463Mi (61%)
```

## Outputs

- HelmRelease `kube-prometheus-stack` **Ready** (chart 92.7.0)
- Pods: Grafana 13.2.4, Prometheus v3.15.0, operator v0.94.1, kube-state-metrics v2.20.0, node-exporter v1.12.1
- Prometheus: 15/15 targets `up`; PVC `prometheus-...-0` Bound (2Gi, `local-path`)
- Grafana reachable at `grafana.local` (HTTP 200)
- All Kustomizations Ready at `main@sha1:1f798951`

## Troubleshooting (recorded)

See [`troubleshooting-log.md`](../troubleshooting-log.md) for the full entries:
- **HelmRelease schema error** — `spec.upgrade.remediation.retryInterval` is not a
  field; the retry strategy belongs at `spec.upgrade.strategy`. Fixed in `1f79895`.
- **`flux reconcile` appears to hang** — it blocks until the Kustomization is
  ready; poll `flux get kustomizations` in a loop instead of a single blocking call.

## GitOps notes

- The whole stack is one `HelmRelease`; changing values = edit the manifest and push.
- Grafana credentials are SOPS-encrypted in git and decrypted by Flux in-cluster.
- `local-path` is node-local: the Prometheus PVC is pinned to whichever node the
  pod schedules on. Acceptable for a lab; Longhorn is the stretch upgrade.

## Shutdown (per runbook 03)

```bash
devpod stop
vm stop k8s-worker-01  # wait shut off
vm stop k8s-cp-01      # wait shut off
kvm off
```
