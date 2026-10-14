# Runbook 06 — Observability stack (kube-prometheus-stack) via Flux

**Goal:** deploy a lightweight metrics + dashboard stack (`kube-prometheus-stack`)
declaratively through Flux, expose Grafana at `grafana.local` through the existing
Envoy Gateway, and prove Prometheus scrapes the cluster — all sized for a 2-node
lab (3 GiB + 1536 MiB).

**Scope:** documents what exists in the repo and cluster at `main@sha1:9550bb43`
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
  - `grafana.resources` = `100m/256Mi` requests, `500m/512Mi` limits, and
    `grafana.sidecar.resources` = `64Mi`/`128Mi` for the dashboard/datasource
    sidecars (Grafana 13 indexes dashboards in memory — a 256Mi limit OOMKills
    it; see the troubleshooting log)
  - `kubeEtcd`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` →
    `enabled: false`. k3s uses a **SQLite** datastore and embeds the control
    plane, so these ServiceMonitors have no endpoints and the stock dashboards
    would only ever show "No data". Disabling them also removes their
    ServiceMonitors + dashboards (12→8 monitors, 28→24 dashboards).
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

### Dashboards actually load (proves the OOM fix)
```bash
# Grafana can list its dashboards (expect 24) …
devpod ssh k8s-homelab-kvm --command \
  'curl -s -u admin:<pw> -H "Host: grafana.local" \
     "http://192.168.123.11/api/search?type=dash-db" \
   | python3 -c "import sys,json;print(len(json.load(sys.stdin)),\"dashboards\")"'
# … and can query Prometheus through its datasource proxy (expect a result)
devpod ssh k8s-homelab-kvm --command \
  'curl -s -u admin:<pw> -H "Host: grafana.local" \
     "http://192.168.123.11/api/datasources/proxy/uid/prometheus/api/v1/query?query=count(up)"'
```

### No OOMKill / headroom
```bash
devpod ssh k8s-homelab-kvm --command \
  'kubectl -n monitoring top pod -l app.kubernetes.io/name=grafana --containers'
# grafana ~317Mi (< 512Mi limit); restartCount 0
devpod ssh k8s-homelab-kvm --command \
  'kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana \
     -o jsonpath="{.items[0].status.containerStatuses[0].restartCount}"'
# Expect: 0
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
- Grafana reachable at `grafana.local` (HTTP 200); **24** dashboards provisioned
- All Kustomizations Ready at `main@sha1:9550bb43`

## Access the UIs

**Grafana** — via the Gateway. Add the host to your workstation's `/etc/hosts`
(one-time, needs sudo):
```
192.168.123.11 grafana.local
```
Then browse to <http://grafana.local> and log in as `admin` with the password
from the SOPS secret:
```bash
devpod ssh k8s-homelab-kvm --command \
  "kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
```

> **Note:** any Grafana rollout (a HelmRelease change or a pod restart)
> invalidates existing browser sessions, so you will be asked to log in again.
> The stored credentials are unchanged — re-run the command above.

**Prometheus** — not exposed through the Gateway (ClusterIP only). Reach the UI
with a port-forward tunnel from your workstation:
```bash
devpod ssh k8s-homelab-kvm \
  -L 9090:127.0.0.1:9090 \
  --command 'kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090'
# then browse to http://localhost:9090
```

## Troubleshooting (recorded)

See [`troubleshooting-log.md`](../troubleshooting-log.md) for the full entries:
- **HelmRelease schema error** — `spec.upgrade.remediation.retryInterval` is not a
  field; the retry strategy belongs at `spec.upgrade.strategy`. Fixed in `1f79895`.
- **`flux reconcile` appears to hang** — it blocks until the Kustomization is
  ready; poll `flux get kustomizations` in a loop instead of a single blocking call.
- **Grafana OOMKilled → Envoy `upstream connect error` on Dashboard pages** —
  the `256Mi` limit was too low for Grafana 13's in-memory dashboard index;
  raised to `512Mi`. Fixed in `9550bb4`.
- **etcd / scheduler / controller-manager dashboards show "No data"** — k3s has
  no etcd and does not expose those metrics; disabled via the component flags in
  `9550bb4`.

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
