# AGENTS.md — k8s-homelab-kvm

Contract for any AI agent working in this repo. Read this **first**.

This repo builds and documents a **2-node k3s homelab on libvirt/KVM**, operated
from a **FOSS-only Devpod (Podman) workspace**. It is documentation-first:
every change is verified and documented.

## Read these first (canonical docs — do NOT duplicate their content here)

| Doc | Use it for |
|---|---|
| [`docs/roadmap.md`](docs/roadmap.md) | phases, **open decisions**, next actions |
| [`docs/system-inventory.md`](docs/system-inventory.md) | verified host/cluster/workspace state |
| [`docs/runbooks/`](docs/runbooks) | do-this procedures (01 install, 02 workspace, 03 session, 04 k9s, 05 GitOps/Flux, 06 observability, 07 Flux Web UI) |
| [`docs/adr/`](docs/adr) | *why* each decision was made |
| [`docs/troubleshooting-log.md`](docs/troubleshooting-log.md) | every real failure: symptom → cause → fix → lesson |

**Rule:** this file **points to** those docs and must **never copy** them.
State changes go in the docs (and `system-inventory.md`), not here.

## What this project is
- A 2-node k3s cluster running on libvirt/KVM VMs.
- Operator tooling (kubectl, helm, flux, …) runs **inside a Devpod
  workspace**, not on the host.
- Everything is documented; the repo doubles as a portfolio piece.

## Hard constraints (non-negotiable)
- **FOSS only.** No proprietary components, no vendor lock-in.
- **FOSS-only naming.** Avoid `docker`, `vscode`, `dev-container`,
  `mcr.microsoft.com` in anything we name. The mandated spec names
  (`.devcontainer/devcontainer.json`, the `"dockerfile"` key) come from the open
  `containers.dev` standard — keep them; they are not the Docker/VS Code apps.
- **Workspace container:** base image `quay.io/fedora/fedora:44`; runs as the
  uid-1000 `dev` user.
- **Host power: TLP only.** `tuned` must remain **absent** — they fight over the
  CPU governor. See [ADR-0001](docs/adr/0001-tlp-over-tuned.md).
- **Lightweight & minimal.** Prefer fewer tools and one tool where possible;
  size choices to the small cluster (~3 GiB RAM total).
- **Host stays "OS free".** Install as little as possible on the host; cluster
  tooling lives in the workspace.
- **Theme: gruvbox** everywhere (bat, kitty, vim, nvim, zed, k9s).
- **Do NOT modify** the external repo `~/Sync/Repos/kvm-vm-provisioner` or the
  `kvm` / `vm` shell functions.
- **NEVER `vm destroy`** — it wipes the disk. Shut down gracefully.
- **NEVER commit secrets** (tokens, keys, kubeconfigs).
- **Commit/push only when the user explicitly asks.**

## Architecture snapshot
> Authoritative, verified values live in
> [`docs/system-inventory.md`](docs/system-inventory.md). Summary only:

| | `k8s-cp-01` | `k8s-worker-01` |
|---|---|---|
| Role | control plane | worker |
| IP | 192.168.123.11 | 192.168.123.12 |
| RAM | 3 GiB | 1536 MiB |

- Guest OS Ubuntu 24.04.5 · k3s `v1.37.1+k3s1` · containerd `2.3.4-k3s1`
- CNI: **Flannel** (k3s default) · Traefik **disabled**
- Cluster login user: `ratlab` · Workspace user: `dev` (uid 1000)
- Ingress: **Envoy Gateway** v1.9.2 (installed via Flux; Gateway `eg`
  `Programmed` at `192.168.123.11`). See
  [ADR-0004](docs/adr/0004-gateway-api-and-ingress.md)
- GitOps: **Flux CD** v2.9.6, **managed by the Flux Operator** (chart `0.61.0`)
  via a `FluxInstance` since 2026-10-15; **Flux Status Web UI** at `flux.local`.
  See [ADR-0006](docs/adr/0006-flux-operator-managed.md) and
  [runbook 07](docs/runbooks/07-flux-webui.md)
- Host: Fedora 44 Workstation · kubeconfig at `~/.kube/config` (host)

## Conventions
- All docs live in `docs/`. One ADR per non-trivial decision.
- Runbook format mirrors `~/Sync/Repos/runbook` (see the `runbook-writer` skill).
- Commit messages: concise, imperative, scope-prefixed (`docs:`, `feat:`, `fix:`).
- After a change: update `system-inventory.md` (state), `troubleshooting-log.md`
  (failures), and `roadmap.md` (phase status).

## Session workflow
1. Start the environment per [runbook 03](docs/runbooks/03-session-lifecycle.md):
   `kvm on` → `vm start k8s-cp-01` → `vm start k8s-worker-01` → `devpod up . --ide none`.
2. Read [`docs/roadmap.md`](docs/roadmap.md) for the current phase and open
   decisions **before** starting work.
3. Verify before asserting. Distinguish verified facts from assumptions; if
   unsure, check — do not guess.
4. After work: verify, then document.

## Guardrails / anti-patterns
| Don't | Do instead |
|---|---|
| `vm destroy` | `ssh <node> sudo poweroff` |
| `kvm off` before both VMs show `shut off` | wait until `virsh list --all` shows `shut off` |
| Run `kubectl`-dependent scripts on the host | run them inside the workspace (`devpod ssh`) |
| Run `ssh` inside a `while read` loop without `-n` | add `-n` |
| Use the host's `rm` expecting a real delete | the host `rm` is a **trash wrapper** — use `command rm -f` to truly delete |
| Mount host creds into a rootless-Podman container with one flag | needs **both** `--userns=keep-id` **and** `--security-opt=label=disable` |
| Use short image names with Podman | use **fully-qualified** names (`quay.io/...`) |
| Rely on `SHELL` in the `Containerfile` | Podman builds **OCI**; `RUN` uses `/bin/sh` |
| Install `tuned` on the host | leave it absent (TLP only) |
| Commit secrets | keep them out; extend `.gitignore` |
| Duplicate doc content into this file | point to the doc |

## Private context
Personal objectives and the per-session log live in `AGENTS.local.md`
(**gitignored**). It is loaded via `opencode.json` → `instructions`.
