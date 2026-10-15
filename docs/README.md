# k8s-homelab-kvm — Documentation Index

A 2-node k3s homelab on libvirt/KVM, with the operator toolchain in a FOSS-only
Devpod (Podman) workspace. This index links every document.

Current phase: **6 complete** (Phases 0–3, 5–6: k3s, workspace, k9s, GitOps with
Flux/SOPS, and the observability stack), plus the **Flux Web UI** (Flux migrated
to the Flux Operator). **Phase 7 (security hardening) is next.** See the
[roadmap](roadmap.md) for the forward plan and decisions.

---

## Runbooks (do-this, in order)

| # | Runbook | Covers |
|---|---|---|
| 01 | [Install k3s](runbooks/01-install-k3s.md) | node prep, control plane, worker join, verify |
| 02 | [Operator workspace](runbooks/02-devpod-workspace.md) | Podman + Devpod, FOSS base, mounts, runArgs |
| 03 | [Session lifecycle](runbooks/03-session-lifecycle.md) | start/stop order (`kvm on` → VMs → `devpod up`) |
| 04 | [k9s single pane](runbooks/04-k9s-single-pane.md) | observe/inspect the cluster (k9s, gruvbox, hotkeys) |
| 05 | [GitOps with Flux CD](runbooks/05-gitops-flux.md) | Flux bootstrap, SOPS/age, Envoy Gateway, podinfo workload |
| 06 | [Observability](runbooks/06-observability.md) | kube-prometheus-stack via Flux, Grafana route, Prometheus targets |
| 07 | [Flux Web UI](runbooks/07-flux-webui.md) | migrate Flux to the Flux Operator, Flux Status UI at `flux.local` |
| 08 | [Security hardening](runbooks/08-security-hardening.md) | trivy scanner, PSS per namespace, RBAC, secrets hygiene |

## ADRs (why)

| # | Decision |
|---|---|
| 0001 | [TLP over `tuned`](adr/0001-tlp-over-tuned.md) |
| 0002 | [Implicit CPU model via `--osinfo`](adr/0002-implicit-cpu-model.md) |
| 0003 | [Operator environment in a Devpod workspace](adr/0003-devpod-workspace.md) |
| 0004 | [Ingress / Gateway API strategy](adr/0004-gateway-api-and-ingress.md) *(accepted — Envoy Gateway)* |
| 0005 | [No Ansible — node config stays scripted](adr/0005-no-ansible-node-config.md) *(accepted)* |
| 0006 | [Flux managed by the Flux Operator (Web UI)](adr/0006-flux-operator-managed.md) *(accepted)* |
| 0007 | [Security hardening (trivy, PSS, RBAC)](adr/0007-security-hardening.md) *(accepted)* |

## Reference

| Doc | What |
|---|---|
| [System inventory](system-inventory.md) | verified host + cluster + workspace state |
| [Roadmap](roadmap.md) | phase plan (remaining: 7–8) + decision log |
| [Troubleshooting log](troubleshooting-log.md) | every real failure: symptom → cause → fix → lesson |

## Code / config

| Path | What |
|---|---|
| [`../scripts/`](../scripts) | phase scripts (`preflight`, `10-`, `20-`, `30-`, `40-`) |
| [`../inventory/nodes.yml`](../inventory/nodes.yml) | node addresses, roles, resources |
| [`../terraform/`](../terraform) | libvirt `k8s` network XML (Terraform deferred — [ADR-0005](adr/0005-no-ansible-node-config.md)) |
| [`../ansible/`](../ansible) | dropped — node config stays scripted ([ADR-0005](adr/0005-no-ansible-node-config.md)) |
| [`../config/k9s/`](../config/k9s) | k9s config, hotkeys, gruvbox skin (mounted via `K9S_CONFIG_DIR`) |
| [`../clusters/`](../clusters) | Flux app-of-apps (`clusters/k8s-homelab/`) |
| [`../infrastructure/`](../infrastructure) | cluster controllers as git-managed manifests (Envoy Gateway, monitoring, Flux Operator) |
| [`../apps/`](../apps) | workloads (podinfo) with encrypted secrets |
| [`../.devcontainer/`](../.devcontainer) | `Containerfile` + `devcontainer.json` |

## Reading order (newcomer)

1. [System inventory](system-inventory.md) — what exists right now
2. [Runbook 03](runbooks/03-session-lifecycle.md) — how to turn it on
3. [Runbook 01](runbooks/01-install-k3s.md) → [Runbook 02](runbooks/02-devpod-workspace.md)
4. [ADRs](adr) for the reasoning behind each choice
