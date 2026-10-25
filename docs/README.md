# Documentation

Everything about the homelab lives here. If you want the current state of the
system, read the [system inventory](system-inventory.md). If you want to bring it
up, start with [runbook 03](runbooks/03-session-lifecycle.md).

All planned phases (0 through 8) are complete: k3s, the operator workspace, k9s,
GitOps with Flux and SOPS, observability, security hardening, the Trivy Operator,
the Flux Web UI, and the CI/CD pipeline with image automation. The
[roadmap](roadmap.md) tracks what is deferred.

## Runbooks

Step-by-step procedures, meant to be followed in order.

| # | Runbook | What it covers |
|---|---|---|
| 01 | [Install k3s](runbooks/01-install-k3s.md) | Provision the nodes and form the cluster |
| 02 | [Devpod workspace](runbooks/02-devpod-workspace.md) | The FOSS-only operator environment on Podman |
| 03 | [Session lifecycle](runbooks/03-session-lifecycle.md) | Host → VM → workspace start and stop order |
| 04 | [k9s](runbooks/04-k9s-single-pane.md) | Terminal UI for the cluster, gruvbox theme and hotkeys |
| 05 | [GitOps with Flux CD](runbooks/05-gitops-flux.md) | Bootstrap, SOPS/age, Envoy Gateway, first workload |
| 06 | [Observability](runbooks/06-observability.md) | kube-prometheus-stack via Flux, Grafana route |
| 07 | [Flux Web UI](runbooks/07-flux-webui.md) | Move Flux to the Flux Operator, Status UI at `flux.local` |
| 08 | [Security hardening](runbooks/08-security-hardening.md) | Trivy, PSS, RBAC, secrets hygiene, Trivy Operator |
| 09 | [CI/CD and image automation](runbooks/09-ci-cd-image-automation.md) | GitHub Actions → GHCR, then Flux updates the tag |

## Architecture decision records

One short record per non-trivial decision.

| # | Decision |
|---|---|
| 0001 | [TLP over `tuned`](adr/0001-tlp-over-tuned.md) |
| 0002 | [Implicit CPU model via `--osinfo`](adr/0002-implicit-cpu-model.md) |
| 0003 | [Operator environment in a Devpod workspace](adr/0003-devpod-workspace.md) |
| 0004 | [Ingress and Gateway API strategy](adr/0004-gateway-api-and-ingress.md) |
| 0005 | [No Ansible: node config stays scripted](adr/0005-no-ansible-node-config.md) |
| 0006 | [Flux managed by the Flux Operator](adr/0006-flux-operator-managed.md) |
| 0007 | [Security hardening](adr/0007-security-hardening.md) |
| 0008 | [Continuous scanning with the Trivy Operator](adr/0008-trivy-operator.md) |
| 0009 | [CI/CD and Flux image automation](adr/0009-ci-cd-image-automation.md) |

## Reference

| Doc | What it holds |
|---|---|
| [System inventory](system-inventory.md) | The verified state of the host, cluster, and workspace |
| [Roadmap](roadmap.md) | Phase plan, decision log, and deferred work |
| [Tooling evaluation](tooling-evaluation.md) | Candidate tools, licenses, footprint, and verdicts |
| [Troubleshooting log](troubleshooting-log.md) | Every real failure: symptom, cause, fix, lesson |

## Code and configuration

| Path | What it is |
|---|---|
| [`../scripts/`](../scripts) | Preflight and provisioning scripts (`preflight`, `10-`, `20-`, `30-`, `40-`) |
| [`../inventory/nodes.yml`](../inventory/nodes.yml) | Node addresses, roles, resources |
| [`../terraform/`](../terraform) | libvirt network XML (Terraform itself is deferred, see ADR-0005) |
| [`../config/k9s/`](../config/k9s) | k9s config, hotkeys, gruvbox skin |
| [`../clusters/`](../clusters) | Flux app-of-apps entrypoint |
| [`../infrastructure/`](../infrastructure) | Cluster controllers as Git-managed manifests |
| [`../apps/`](../apps) | Workloads and their encrypted secrets |
| [`../images/`](../images) | Application source built by CI |
| [`../.devcontainer/`](../.devcontainer) | The workspace `Containerfile` and `devcontainer.json` |
| [`../.github/workflows/`](../.github/workflows) | CI (build and scan) and lint workflows |

## Reading order

1. [System inventory](system-inventory.md) to see what exists right now.
2. [Runbook 03](runbooks/03-session-lifecycle.md) to bring it up.
3. [Runbook 01](runbooks/01-install-k3s.md) and
   [runbook 02](runbooks/02-devpod-workspace.md) to understand how it was built.
4. The [ADRs](adr) for the reasoning behind each choice.
