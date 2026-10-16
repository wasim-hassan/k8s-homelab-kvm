# Runbook 04 — k9s single pane (observe / inspect the cluster)

**Goal:** one terminal, one tool to **list, inspect and watch everything inside
the cluster** — nodes, pods, workloads, services, config, events — live, in the
gruvbox theme the rest of the host already uses.

**The tool is `k9s` (v0.51.0), already installed in the workspace.** There is
nothing else to install. It is a Kubernetes client: it talks to the API server
through the mounted `~/.kube/config`. The CPU/MEM columns come from the
`metrics-server` add-on.

> **Scope.** k9s sees **Kubernetes only**. Your two libvirt VMs appear as the
> **Nodes view** (`k8s-cp-01`, `k8s-worker-01`) — that is the VM layer, from
> inside the cluster. It does **not** show libvirt power state or host processes;
> that is `btop` / `virsh` on the host, outside k9s's scope.

---

## Why it looked empty at first

k9s opens **scoped to one namespace**, which defaults to `default`. All of the
cluster's pods live in `kube-system`, so the `default` pod view is legitimately
empty. This is a **configuration** issue, not a broken tool.

The config in this repo fixes it: k9s now **opens on the Namespaces view (all
namespaces)** and jumps anywhere with one keystroke.

---

## Where the config lives (and why)

`K9S_CONFIG_DIR` (k9s's own env var) points k9s at a **single directory** from
which it reads *everything*: the static `config.yaml`, `hotkeys.yaml`,
`skins/`, and the dynamic per-context state under `clusters/`.

That directory is **inside this repo** — [`../../config/k9s/`](../../config/k9s) — and
is bind-mounted into the workspace at `/home/dev/.config/k9s`. Your `$HOME` gets
**no** new dotfiles; the config is version-controllable with the rest of the
project.

| File | Purpose |
|---|---|
| `config/k9s/config.yaml` | skin, refresh rate, CPU/MEM thresholds (warn 80/crit 90), log view |
| `config/k9s/hotkeys.yaml` | one-key jumps (Shift-0..5, Shift-X, Shift-H) |
| `config/k9s/skins/gruvbox-dark-hard.yaml` | gruvbox skin (vendored, Apache-2.0) |
| `config/k9s/clusters/default/default/config.yaml` | start on **all** namespaces, view `namespaces` |

The `clusters/<context>/<cluster>/` path is `<context>` = `default` and
`<cluster>` = `default` — both confirmed from `~/.kube/config`.

`devcontainer.json` wires it up with:

- mount `config/k9s` → `/home/dev/.config/k9s`
- `K9S_CONFIG_DIR=/home/dev/.config/k9s` (in both `containerEnv` and `remoteEnv`)

> Because the mount **replaces** the whole config dir, changes to any file above
> are picked up on the next k9s launch — no rebuild needed. Kubernetes
> namespaces are flat (no hierarchy); favorites pinned to `podinfo`,
> `kube-public`, `default`, `all`, `kube-system`, `monitoring`. (`config.yaml` is
> k9s's per-context **runtime state** — k9s rewrites it on exit, so re-commit it if
> favorites/view change.)

---

## Launch

```bash
# from the host, if not already in a workspace shell
devpod ssh k8s-homelab-kvm

# then, inside the workspace
k9s
```

It lands on the **Namespaces** view, all namespaces, live. (Press `Shift-1` for
Pods; `k9s -A` forces all-namespaces too, but the config already makes that the
default.)

---

## The one-glance views

| Press / type | You see |
|---|---|
| *(launch)* | **Namespaces** view (all namespaces) |
| `Shift-0` | **Nodes** — `k8s-cp-01`, `k8s-worker-01` (your VMs), usage + pod counts |
| `Shift-1` | Pods (all namespaces) |
| `Shift-2` | Deployments |
| `Shift-3` | Services |
| `Shift-4` | Events |
| `Shift-5` | Namespaces |
| `Shift-X` | **XRay Deployments** (tree: `Deployment → ReplicaSet → Pod`) — `xray deploy` |
| `Shift-H` | **Cluster health** (`:pulses`) |

---

## Core keys (verified against k9s docs)

| Key | Action |
|---|---|
| `?` | help + full key list |
| `ctrl-a` | list **every** resource alias (pods, nodes, CRDs, …) |
| `:` + resource | go to a view, e.g. `:nodes`, `:pods`, `:svc`, `:events` |
| `:ns` | switch namespace |
| `0` | toggle all-namespaces (confirm with `?` on your build) |
| `/` | filter within the current view |
| `d` | describe the selected resource |
| `l` / `p` | logs / previous-container logs |
| `s` / `a` | shell / attach (pods) |
| `y` | view YAML |
| `e` | edit (writes back to the cluster) |
| `ctrl-w` | toggle wide columns |
| `esc` | back |
| `:q` or `ctrl-c` | quit |

**Custom hotkeys** are defined in `hotkeys.yaml` (the `Shift-*` rows above).

---

## What lives where (mental model)

| You want | k9s view |
|---|---|
| VMs (as cluster nodes) | `Shift-0` / `:nodes` |
| Pods + their containers | `Shift-1` / `:pods` |
| Workloads | `:dp`, `:sts`, `:ds` |
| Exposed services | `:svc` |
| Config & secrets | `:cm`, `:secret` |
| What just happened | `Shift-4` / `:events` |
| Cluster down / health | `Shift-H` (`:pulses`) |
| Resource relationships | `:xray <resource>` (e.g. `:xray deploy`) |

---

## Verification checklist

- [ ] `devpod ssh k8s-homelab-kvm --command 'echo $K9S_CONFIG_DIR'` → `/home/dev/.config/k9s`
- [ ] `k9s version --short` → `v0.51.0`
- [ ] Launch `k9s` → opens on the **Namespaces** view (all namespaces), not empty
- [ ] Theme is gruvbox (dark background `#1d2021`)
- [ ] `Shift-0` shows both nodes `Ready`
- [ ] `Shift-H` renders the pulses/health view

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod view is empty | You're on the `default` namespace. Press `0`, or set `namespace.active: all` — the repo config already does this. |
| Launch errors reading config | `K9S_CONFIG_DIR` not set, or mount missing. Re-check `devcontainer.json` and `devpod up --recreate .`. |
| No CPU/MEM numbers | `metrics-server` not ready: `kubectl -n kube-system get pods -l k8s-app=metrics-server`. |
| Skin looks default | `config.yaml` `ui.skin` must be `gruvbox-dark-hard` **and** the file must exist in `skins/`. |
| Settings reset after a rebuild | The config dir must be the **repo mount**, not a container-local path. Confirm the mount in `devcontainer.json`. |
| `Error: open /dev/tty: no such device or address` | k9s needs a real terminal. `--headless` only hides the **header** — it is *not* a TTY-free mode. Run k9s in an interactive shell. |
| `Validation failed ... portForwardAddress is not allowed` | v0.51.0 removed that key from the per-context config. Keep the per-context file to `cluster`/`readOnly`/`namespace`/`view`/`featureGates`. |
