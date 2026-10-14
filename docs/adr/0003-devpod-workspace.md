# ADR-0003: Operator environment runs in a Devpod workspace

- **Status:** Accepted
- **Date:** 2026-10-12
- **Deciders:** wasim (with AI assistant review)

## Context

Phase 1 installed the cluster tooling directly on the Fedora workstation:
`kubectl` v1.37.1 and `helm` v4.3.0 in `~/.local/bin`, plus a pre-existing
`/usr/bin/terraform` v1.16.4. Cluster scripts (`20-…`, `30-…`, `40-verify.sh`)
require `kubectl` on the host `PATH`.

That works, but on a daily driver it costs:

1. **Host pollution.** Every tool is another thing installed and abandoned.
2. **No reproducibility.** The toolchain exists only as whatever happens to be
   installed.
3. **OS coupling.** Tools match this specific Fedora host.
4. **Version drift.** Nothing enforces `kubectl` tracking the server version.

The operator's reference style (Mischa van den Burg) is a containerized working
environment described by `devcontainer.json`, run locally. Requirements:
**FOSS only, no proprietary vendor, no VS Code**, CLI/Neovim workflow
(Kitty + LazyVim), and the existing k3s cluster left intact in the VMs.

## Decision

**Move the operator toolchain into an in-repo Devpod workspace** described by
`.devcontainer/devcontainer.json` + `.devcontainer/Containerfile`, run by
**Podman** via the **Devpod** CLI (`docker` provider → `podman`). Host-installed
`kubectl` and `helm` are removed afterwards.

Concretely:

- Base image **`quay.io/fedora/fedora:44`** (Fedora on Red Hat's FOSS Quay
  registry) — no Microsoft base image, no `vscode` user.
- Build file is a **`Containerfile`** (Podman's native name); the spec's
  `"dockerfile"` key points at it.
- Tools pinned + checksum-verified where upstream allows: `kubectl` v1.37.1,
  `helm` v4.3.0, `terraform` v1.16.4, `k9s` v0.51.0 (`.rpm`), `yq` v4.54.1,
  `nvim` v0.12.6.
- Workspace runs as **`dev`** (uid/gid 1000) with `--userns=keep-id` and
  `--security-opt=label=disable`, so it can read host-mounted credentials.
- The cluster is **not** moved. The workspace is a client/operator only.

### What we cannot rename (and why that is fine)

The folder/file `.devcontainer/devcontainer.json`, the JSON key `"dockerfile"`,
and the Devpod provider id `docker` are fixed by the **open `containers.dev`
standard** and by Devpod's built-in provider. They name an *open spec* and a
provider that literally drives **Podman** — they are not the Docker or VS Code
products. Everything we control is FOSS-named (`Containerfile`, Fedora base,
`dev` user).

## Rationale

1. **Reproducible + host-independent.** The environment is code; `devpod up .`
   yields the identical toolchain anywhere.
2. **Host stays minimal.** Only `podman` and the single `devpod` binary are
   added.
3. **FOSS + no lock-in.** Devpod is MPL-2.0, client-only, single Go binary. The
   spec is the open `containers.dev` standard, so the same config could run
   under other tooling later.
4. **CLI-native.** `devpod ssh` gives a shell; Neovim (LazyVim) runs inside via a
   bind mount of `~/.config/nvim`. No VS Code, no proprietary IDE layer.
5. **Least change to Phase 1.** VMs, k3s install, networking, and scripts are
   untouched. Only *where* the client tools live changes.

### Why Podman over Docker

Podman is rootless, daemonless, and already the operator's runtime. Devpod's
`docker` provider accepts any Docker-API-compatible CLI, so it is pointed at
`/usr/bin/podman` — no Docker daemon, no socket juggling.

## Consequences

**Positive**
- One command rebuilds the entire operator environment anywhere.
- Tool versions are pinned and (mostly) checksum-verified as code.
- Host cleanup: `kubectl`/`helm` removed from `~/.local/bin`.
- Fully FOSS stack: Fedora + Podman + Devpod + Neovim; vendor-neutral naming.

**Negative — accepted risks**
- **Devpod is an extra dependency.** Not in dnf/apt; installed manually and
  **without an upstream checksum** (upstream publishes none). Local SHA256 is
  recorded in the inventory.
- **Two tools are unverified.** `yq` and `neovim` upstream publish no
  `sha256sum`-compatible file. Recorded as a known gap.
- **Rootless Podman quirks.** Requires `--userns=keep-id` **and**
  `--security-opt=label=disable` on a Fedora host, plus OCI-format caveats
  (`SHELL` ignored, FQ image names).
- **Spec names stay.** `.devcontainer/devcontainer.json` and the `"dockerfile"`
  key cannot be renamed without breaking Devpod auto-detection.
- **Scripts must run in-workspace.** `kubectl`-dependent scripts no longer run on
  the bare host.

## Verification

```bash
devpod up . --ide none
devpod ssh k8s-homelab-kvm --command \
  'id; kubectl get nodes; ssh k8s-cp-01 "sudo -n k3s --version"; nvim --version | head -1'
```

- ✅ `uid=1000(dev)`, both nodes `Ready`, k3s reachable over SSH
- ❌ `Permission denied` on mounts → missing `keep-id` and/or `label=disable`

## Revisit when

- Devpod adds an upstream checksum file (then verify the binary too).
- `yq`/`neovim` begin publishing `sha256sum` files (then verify them).
- A dotfiles git repo exists (then Devpod's `--dotfiles` can replace the nvim
  bind mount).
- More than one project needs the same environment (then consider a shared base
  image / registry cache).
