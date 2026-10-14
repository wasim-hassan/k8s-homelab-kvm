# k8s-homelab-kvm — Documentation Index

A 2-node k3s homelab on libvirt/KVM, with the operator toolchain in a FOSS-only
Devpod (Podman) workspace. This index links every document.

Current phase: **2 complete** (operator workspace + k9s single pane). Next:
**Phase 3 — GitOps** (FluxCD + SOPS/age, ingress, first workload) — see the
[roadmap](roadmap.md), which also lists the open decisions blocking it.

---

## Runbooks (do-this, in order)

| # | Runbook | Covers |
|---|---|---|
| 01 | [Install k3s](runbooks/01-install-k3s.md) | node prep, control plane, worker join, verify |
| 02 | [Operator workspace](runbooks/02-devpod-workspace.md) | Podman + Devpod, FOSS base, mounts, runArgs |
| 03 | [Session lifecycle](runbooks/03-session-lifecycle.md) | start/stop order (`kvm on` → VMs → `devpod up`) |
| 04 | [k9s single pane](runbooks/04-k9s-single-pane.md) | observe/inspect the cluster (k9s, gruvbox, hotkeys) |

## ADRs (why)

| # | Decision |
|---|---|
| 0001 | [TLP over `tuned`](adr/0001-tlp-over-tuned.md) |
| 0002 | [Implicit CPU model via `--osinfo`](adr/0002-implicit-cpu-model.md) |
| 0003 | [Operator environment in a Devpod workspace](adr/0003-devpod-workspace.md) |
| 0004 | [Ingress / Gateway API strategy](adr/0004-gateway-api-and-ingress.md) *(proposed)* |

## Reference

| Doc | What |
|---|---|
| [System inventory](system-inventory.md) | verified host + cluster + workspace state |
| [Roadmap](roadmap.md) | Phase 3–8 forward plan + open decisions |
| [Troubleshooting log](troubleshooting-log.md) | every real failure: symptom → cause → fix → lesson |

## Code / config

| Path | What |
|---|---|
| [`../scripts/`](../scripts) | phase scripts (`preflight`, `10-`, `20-`, `30-`, `40-`) |
| [`../inventory/nodes.yml`](../inventory/nodes.yml) | node addresses, roles, resources |
| [`../terraform/`](../terraform) | libvirt `k8s` network XML (Terraform code pending) |
| [`../ansible/`](../ansible) | node config as code (pending) |
| [`../config/k9s/`](../config/k9s) | k9s config, hotkeys, gruvbox skin (mounted via `K9S_CONFIG_DIR`) |
| [`../.devcontainer/`](../.devcontainer) | `Containerfile` + `devcontainer.json` |

## Reading order (newcomer)

1. [System inventory](system-inventory.md) — what exists right now
2. [Runbook 03](runbooks/03-session-lifecycle.md) — how to turn it on
3. [Runbook 01](runbooks/01-install-k3s.md) → [Runbook 02](runbooks/02-devpod-workspace.md)
4. [ADRs](adr) for the reasoning behind each choice
