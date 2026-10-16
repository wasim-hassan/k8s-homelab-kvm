# Runbook 02 — Operator workspace (Podman + Devpod)

**Goal:** run every cluster-operations tool (`kubectl`, `helm`, `terraform`,
`k9s`, `yq`, `nvim`, `flux`, `sops`, `age`) inside a **reproducible,
host-independent Devpod workspace**, so the Fedora workstation stays minimal and
the toolchain is defined as code.

This is the **operator/client** environment. The cluster itself still runs in the
two libvirt VMs — the workspace never hosts Kubernetes workloads.

**Topology**

| Layer | What | Where |
|---|---|---|
| Spec | `.devcontainer/devcontainer.json` + `.devcontainer/Containerfile` | open `containers.dev` standard, in-repo |
| Runtime | Podman 5.8.7 (rootless) | host |
| Orchestrator | Devpod CLI v0.6.15, `docker` provider pointed at `podman` | host (`~/.local/bin/devpod`) |
| Base image | `quay.io/fedora/fedora:44` (FOSS, Quay registry) | pulled by Podman |
| Target | k3s cluster `v1.37.1+k3s1` | `k8s-cp-01` / `k8s-worker-01` VMs |

**Naming note.** The folder/file `.devcontainer/devcontainer.json`, the JSON key
`"dockerfile"`, and the Devpod provider id `docker` are mandated by the **open
`containers.dev` standard** and by Devpod — they are not the Docker or VS Code
products. Everything we control is FOSS-named: the build file is a
**`Containerfile`** (Podman convention), the base is Fedora, and the user is
`dev`.

---

## Preconditions

- Rootless Podman installed (`podman version` → 5.8.7).
- `devpod` on `PATH`.
- `~/.kube/config` (cluster-admin, mode `600`) pointing at
  `https://192.168.123.11:6443`.
- `~/.ssh/k8s-homelab-kvm` (mode `600`) and the `Host k8s-*` block in
  `~/.ssh/config`.
- `~/.cache/k3s-homelab/k3s-v1.37.1+k3s1` (checksum-verified binary cache).
- `~/.config/nvim` (LazyVim) present.
- `~/.config/sops/age/keys.txt` (age private key, mode `600`) for SOPS (Phase 3).

---

## Execution order

Run from the repo root (`~/Sync/Repos/k8s-homelab-kvm`).

### One-time setup

```bash
# 1. Install Devpod (single self-contained Go binary, no package manager)
install -m 0755 devpod-linux-amd64 ~/.local/bin/devpod

# 2. Disable telemetry (OSS default is on)
devpod context set-options -o TELEMETRY=false

# 3. Register the docker provider and point it at Podman
devpod provider add docker --use
devpod provider set-options docker -o DOCKER_PATH=/usr/bin/podman
```

### Start the workspace

```bash
devpod up . --ide none              # build image + create container
devpod ssh k8s-homelab-kvm          # or: ssh k8s-homelab-kvm.devpod
```

`--ide none` stops Devpod launching an IDE; we are CLI-only (Neovim inside).

### Day-to-day

```bash
devpod list                 # workspaces
devpod up . --ide none      # (re)start
devpod ssh k8s-homelab-kvm
devpod stop k8s-homelab-kvm # stop the container, keep it
devpod delete k8s-homelab-kvm   # destroy container (mounts are host dirs)
```

> After a **host reboot** the container shows `Exited (0)` and `podman ps` is
> empty — that is the normal stopped state (rootless containers don't
> auto-start). Resume with `devpod up . --ide none`. For the full
> host→VM→workspace start order, see [runbook 03](03-session-lifecycle.md).
>
> **Run the cluster scripts from inside the workspace.** `20-…`, `30-…` and
> `40-verify.sh` require `kubectl` on `PATH`, which now lives only in the
> workspace. `preflight.sh` and `10-prepare-nodes.sh` need only `ssh`/`python3`
> and still run on the host.

---

## Why it is built this way

### The workspace is the operator, not the cluster

Mischa van den Burg's pattern: keep the host OS clean and disposable, and put
the whole working environment in a container described by `.devcontainer/`.
Rebuild it on any machine and you get the identical toolchain. The cluster stays
in the VMs, exactly as Phase 1 built it.

### FOSS base image + user

- **Base:** `quay.io/fedora/fedora:44` — Fedora on Red Hat's FOSS Quay registry.
  No Microsoft base image, no `vscode` user, no Docker Hub dependency.
- **User:** `dev`, uid/gid **1000**. uid 1000 is required so that Podman's
  `--userns=keep-id` maps it to the host user (uid 1000) and the bind-mounted
  credentials are readable. Mount targets are `/home/dev/...`.
- **`kitty-terminfo`** is installed so TUI tools (`k9s`) can run under the kitty
  terminal (`TERM=xterm-kitty`).

### `runArgs` — the three flags that matter

```jsonc
"--network=host",              // reach 192.168.123.11:6443 directly
"--userns=keep-id",            // map host user 1000 -> container 1000
"--security-opt=label=disable" // Fedora SELinux would block the mounts
```

- **`--network=host`** — shares the host netns, so the k3s API at
  `192.168.123.11:6443` is reachable with no port juggling.
- **`--userns=keep-id`** — rootless Podman's *default* mapping does **not** map
  the host user to the same uid inside; without this, every bind-mounted host
  file is unreadable.
- **`--security-opt=label=disable`** — on an enforcing Fedora host the files
  carry `user_home_t`, which the container domain cannot read even with
  `keep-id`.

Both of the last two are required **together**; see the troubleshooting log.

### Mounts

| Host source | Container target | Mode | Why |
|---|---|---|---|
| `~/.kube` | `/home/dev/.kube` | rw | cluster credential |
| `~/.ssh/k8s-homelab-kvm` | `/home/dev/.ssh/k8s-homelab-kvm` | ro | node SSH key |
| `~/.cache/k3s-homelab` | `/home/dev/.cache/k3s-homelab` | ro | verified k3s binary |
| `~/.config/nvim` | `/home/dev/.config/nvim` | rw | LazyVim config |
| `~/.config/sops` | `/home/dev/.config/sops` | rw | age key for SOPS (Phase 3) |

`KUBECONFIG=/home/dev/.kube/config` is set via `containerEnv`/`remoteEnv`.

> The image pre-creates `/home/dev/.config` (dev-owned). Otherwise Podman creates
> that parent **root-owned** when it attaches the nvim mount, and tools like
> `k9s` cannot create `/home/dev/.config/k9s`.

### Checksum verification in the Containerfile

Every tool is pinned and verified where upstream allows:

- **kubectl** — `dl.k8s.io` serves a **bare hash with no filename**, so
  `sha256sum -c` cannot consume it; the build assembles the `"<hash>  <path>"`
  line manually.
- **helm** — matched against the upstream `.sha256sum` (expected vs actual).
- **terraform** — matched against HashiCorp's `SHA256SUMS`.
- **k9s** — Fedora is rpm-based, so the **`.rpm`** artifact is verified against
  the release `checksums.sha256` and installed with `dnf`.
- **flux** — verified against the release `flux_<ver>_checksums.txt`.
- **sops** — verified against the release `sops-v<ver>.checksums.txt`.
- **age** — installed from the Fedora repo as a **GPG-signed RPM** (the upstream
  release ships no `sha256` file, only signature `.proof` files).
- **yq / neovim** — upstream publishes **no** `sha256sum`-compatible file, so
  these are downloaded **unverified** (recorded as a known gap in the inventory).

### OCI image format quirks (Podman)

- Podman builds **OCI-format** images, where the `SHELL` directive is **ignored**
  and `RUN` executes under `/bin/sh` — no bashisms or `pipefail`.
- Short-name resolution fails without a TTY; use **fully-qualified** images.

---

## Troubleshooting

### `sha256sum: <file>: No such file or directory` / `Syntax error: end of file unexpected`

A `RUN` containing a `{ …; }` block **with un-escaped newlines** is terminated at
the first newline. Keep every physical line ending in `\`, or use
`printf '%s\n'` on a single continued line (see `.devcontainer/Containerfile`).

### `ls: cannot open directory '/workspaces/...': Permission denied`

The mounts are unreadable. You need **both** fixes:

```bash
podman inspect -f '{{.HostConfig.UsernsMode}} {{.HostConfig.SecurityOpt}}' <ctr>
ls -Zd ~/.kube        # user_home_t on a Fedora host
```

Add `--userns=keep-id` **and** `--security-opt=label=disable`, then
`devpod up . --ide none --recreate`.

### `k9s` exits immediately / `could not create … /home/dev/.config/k9s`

Two causes seen:

1. **TERM** — kitty sets `TERM=xterm-kitty`; without kitty terminfo the TUI
   can't start. Fixed by installing `kitty-terminfo` in the image.
2. **Config dir** — `/home/dev/.config` must exist and be dev-owned in the image.

Diagnose inside the workspace:

```bash
echo $TERM ; infocmp xterm-kitty >/dev/null && echo terminfo-OK
ls -ld ~/.config
```

### `devpod up` reuses a stale image

Changes to **runArgs** or **mounts** apply only on recreate:

```bash
devpod up . --ide none --recreate
```

---

## Verification checklist

Run **inside** the workspace (`devpod ssh k8s-homelab-kvm`):

- [ ] `id` → `uid=1000(dev)`
- [ ] `touch /workspaces/k8s-homelab-kvm/.w && rm .w` → writable
- [ ] `ls ~/.kube/config` → readable
- [ ] `kubectl get nodes` → **both nodes `Ready`**
- [ ] `kubectl get pods -A` → `coredns`, `metrics-server`,
      `local-path-provisioner`, `gateway-api-crd` job
- [ ] `ssh k8s-cp-01 'sudo -n k3s --version'` → `v1.37.1+k3s1`
- [ ] `helm version --short`, `terraform version`, `k9s version --short`,
      `yq --version`, `nvim --version`
- [ ] `flux --version` (v2.9.6), `sops --version` (3.13.3), `age --version` (1.3.1)
- [ ] `infocmp xterm-kitty` → present (k9s runs under kitty)
- [ ] `ls ~/.config/nvim`, `~/.cache/k3s-homelab`, `~/.config/sops/age/keys.txt`
      → mounted

Verified 2026-10-12 (core toolchain) and 2026-10-14 (`flux`/`sops`/`age` + age
key mount) on `quay.io/fedora/fedora:44`: all pass.
