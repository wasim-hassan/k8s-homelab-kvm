# System Inventory — k8s-homelab-kvm

Verified state of the host and cluster. Every value below was confirmed by running
the command shown, not assumed.

Last verified: 2026-10-15

---

## Host

| Item | Value | How verified |
|---|---|---|
| OS | Fedora Linux 44 Workstation | `hostnamectl` |
| Kernel | 7.2.8-200.fc44.x86_64 | `uname -r` |
| CPU | AMD Ryzen 5 5600H (Zen 3), 6C/12T | `lscpu` |
| Virtualization | AMD-V present | `/dev/kvm` exists |
| x86-64 level | **v3** (AVX, AVX2, BMI1/2, FMA all present) | `/proc/cpuinfo` flags |
| Crypto accel | AES-NI, PCLMULQDQ, SHA-NI, ERMS, RDPID | `/proc/cpuinfo` flags |
| RAM | 15 GiB total, ~9 GiB available with cluster up | `free -h` |
| Swap | 8 GiB zram | `swapon --show` |
| Disk | 475 GB LUKS root, ~314 GB free | `df -h /` |
| cgroup | v2 (unified) | `stat -fc %T /sys/fs/cgroup` |

### Power management — TLP only

| Item | Value |
|---|---|
| TLP | 1.10.2 (`tlp`, `tlp-rdw` installed) |
| `tlp.service` | active |
| `tlp-rdw.service` | inactive (expected — only needed for power-profiles-daemon) |
| `tuned` | **not installed** (intentional) |
| scaling driver | `amd-pstate` (passive mode) |
| governor | `schedutil` |
| `/etc/tlp.conf` | entirely defaults (all lines commented) |

**Decision:** TLP exclusively. `tuned` is deliberately absent — both tools fight
over the CPU governor and running them together causes instability. The current
defaults are TLP's recommended pairing for passive `amd-pstate`. Do not "fix"
this. See [ADR-0001](adr/0001-tlp-over-tuned.md).

---

## Virtualization stack

| Component | Version |
|---|---|
| qemu-kvm | 10.2.2 |
| libvirt (daemon + client) | 12.0.0 |
| virt-manager | 5.1.0 |
| qemu-guest-agent | 10.2.2 |
| edk2-ovmf | installed |
| xorriso | 1.5.8 |

**User/group:** `wasim` is a member of `wheel` and `libvirt`.

**Daemon model:** Fedora ships the *modular* libvirt daemons. `virtqemud` is
socket-activated and exits after ~120 s idle — this is normal, and the next
`virsh`/`virt-manager` call transparently restarts it. Several daemons
(`virtinterfaced`, `virtsecretd`, `virtstoraged`, `virtnodedevd`,
`virtnwfilterd`) are `enabled` but `inactive` because they too are
socket-activated.

**Images cached at:** `~/Documents/kvm-iso/cloudinit-vms/`
- `ubuntu-24.04-server-cloudimg-amd64.img` (597 MB, refreshed 2026-09-26)
- `AlmaLinux-9-GenericCloud-latest.x86_64.qcow2` (562 MB)

**Base image provenance:** VMs are created by the external tool
`~/Sync/Repos/kvm-vm-provisioner` via the `vm` Bash function. This project does
not modify that repo.

---

## SSH access

| Item | Value |
|---|---|
| Key | `~/.ssh/k8s-homelab-kvm` (ed25519, unencrypted) |
| Fingerprint | `SHA256:EDOpAhf7IgLKXDb32RYkU+ggEQ+r73Km/HTQudiT29Q` |
| Perms | private `600`, public `644`, `~/.ssh` `700` |
| Host config | `~/.ssh/config` block `Host k8s-cp-01 k8s-worker-01 k8s-worker-02` |
| Login user | `ratlab` |

**Why a dedicated key:** blast-radius separation. If a lab VM is compromised,
the attacker's credential is the lab key, not the personal `id_ed25519`.
Unencrypted is intentional — this key is used by unattended automation, and an
encrypted key would force `ssh-agent` plumbing into every later script.

---

## Cluster nodes

| | `k8s-cp-01` | `k8s-worker-01` |
|---|---|---|
| Role | control plane | worker |
| Guest OS | Ubuntu 24.04.5 LTS | Ubuntu 24.04.5 LTS |
| Kernel | 6.8.0-146-generic | 6.8.0-146-generic |
| vCPU | 2 | 2 |
| RAM total | 2907 MiB (3 GiB) | 1463 MiB (1536 MiB) |
| RAM available (idle) | ~1600 MiB | ~880 MiB |
| Disk | 29 GiB usable, 26 GiB free | 29 GiB usable, 27 GiB free |
| MAC | `52:54:00:17:ef:cf` | `52:54:00:96:63:19` |
| IP | 192.168.123.11 | 192.168.123.12 |
| CPU model | `host-passthrough` | `host-passthrough` |
| qemu-guest-agent | active | active |
| k3s service | `k3s.service` (server) | `k3s-agent.service` (agent) |
| SSH alias | `ssh k8s-cp-01` | `ssh k8s-worker-01` |

> **Kernel convergence:** both nodes originally ran different patch levels
> (`6.8.0-137` vs `6.8.0-142`). `10-prepare-nodes.sh` ran `dist-upgrade` and both
> were rebooted, so they now both run **6.8.0-146-generic**.

### Kernel prerequisites (persisted)

`10-prepare-nodes.sh` writes these on every node and they survive reboot:

| File | Contents |
|---|---|
| `/etc/modules-load.d/k8s.conf` | `overlay`, `br_netfilter`, `nf_conntrack` |
| `/etc/sysctl.d/99-kubernetes.conf` | `bridge-nf-call-ip(6)tables=1`, `ip_forward=1` |

### CPU model — why `host-passthrough`

Both nodes run `<cpu mode='host-passthrough' check='none' migratable='on'/>`.

This is **not** configured explicitly anywhere. The external provisioner passes
`--osinfo ubuntu24.04` to `virt-install`, and virt-install's osinfo mapping
selects `host-passthrough` automatically. Verified empirically: defining a domain
*without* `--osinfo` produces no `<cpu>` element at all (which would fall back to
libvirt's `qemu64` baseline).

**This is a hidden dependency.** If the `--osinfo` flag is ever dropped from the
provisioner, the VMs silently regress to `qemu64` and lose hardware AES-NI,
AVX2, and BMI2 — which matters because containerd, etcd, and the API server are
TLS-heavy, and because Talos Linux (planned for a later phase) refuses to boot on
anything below x86-64-v2.

**Verify with:** `virsh dumpxml <vm> | grep '<cpu'`

See [ADR-0002](adr/0002-implicit-cpu-model.md).

---

## Kubernetes (k3s)

| Item | Value |
|---|---|
| Distribution | k3s |
| Version | `v1.37.1+k3s1` (pinned) |
| Container runtime | containerd `2.3.4-k3s1` |
| CNI | Flannel (k3s default) |
| Server flags | `--node-name`, `--node-ip`, `--write-kubeconfig-mode 644`, `--disable traefik` |
| Pod CIDR | `10.42.0.0/16` (cp `10.42.0.x`, worker `10.42.1.x`) |
| Service CIDR | `10.43.0.0/16` (CoreDNS at `10.43.0.10`, API ClusterIP `10.43.0.1`) |
| kubeconfig | `~/.kube/config` on the host, mode `600`, server `https://192.168.123.11:6443` |
| Binary cache | `~/.cache/k3s-homelab/k3s-v1.37.1+k3s1` (host, checksum-verified) |

**Both nodes verified `Ready`.** Core add-ons running: `coredns`,
`local-path-provisioner`, `metrics-server`, and the `gateway-api-crd` Helm job
(completed). **Traefik is intentionally disabled.**

**End-to-end smoke test (2026-10-10):** a `busybox` pod scheduled onto
`k8s-worker-01` (IP `10.42.1.3`) resolved
`kubernetes.default.svc.cluster.local` → `10.43.0.1` via CoreDNS
(`10.43.0.10`). This confirms scheduling, Flannel pod networking, and
cluster DNS all work across nodes.

See [runbook 01](runbooks/01-install-k3s.md).

---

## Operator environment (Devpod workspace)

The Kubernetes/IaC toolchain now lives in an in-repo **Devpod workspace**,
**not** on the host, run by **Podman** via **Devpod**. See
[ADR-0003](adr/0003-devpod-workspace.md) and
[runbook 02](runbooks/02-devpod-workspace.md).

| Layer | Value |
|---|---|
| Podman (rootless) | 5.8.7 |
| Devpod | v0.6.15 (`~/.local/bin/devpod`) |
| Devpod provider | `docker` v0.0.1, `DOCKER_PATH=/usr/bin/podman` |
| Base image | `quay.io/fedora/fedora:44` (FOSS, Quay registry) |
| Build file | `.devcontainer/Containerfile` (Podman convention) |
| Workspace | `k8s-homelab-kvm` → `ssh k8s-homelab-kvm.devpod` |
| Container user | `dev` (uid 1000) |
| Telemetry | disabled (`TELEMETRY=false`) |

Tools **inside the workspace** (pinned in `.devcontainer/Containerfile`):

| Tool | Version | Checksum |
|---|---|---|
| `kubectl` | v1.37.1 | verified (bare-hash compare) |
| `helm` | v4.3.0 | verified (upstream `.sha256sum`) |
| `terraform` | v1.16.4 | verified (HashiCorp `SHA256SUMS`) |
| `k9s` | v0.51.0 | verified (`.rpm` vs release `checksums.sha256`) |
| `yq` | v4.54.1 | **unverified** — no upstream checksum file |
| `nvim` | v0.12.6 | **unverified** — no upstream checksum file |
| `flux` | v2.9.6 | verified (release `checksums.txt`) |
| `sops` | v3.13.3 | verified (release `checksums.txt`) |
| `age` | v1.3.1 | Fedora RPM (GPG-signed, Fedora repo) |

Required `runArgs`: `--network=host`, `--userns=keep-id`,
`--security-opt=label=disable`. All three are necessary (rootless-Podman uid
mapping **and** Fedora SELinux); see ADR-0003 and the troubleshooting log.
`kitty-terminfo` is installed so `k9s` runs under the kitty terminal.

> **Devpod publishes no upstream checksum file.** The local SHA256 of
> `~/.local/bin/devpod` is
> `cc50bce09229d5a6d448ac1d4494327f4b8f7a20321e5fcee3bfec1aef0d20c5` — there is
> nothing official to verify it against.

### Secrets — SOPS + age (Phase 3)

Cluster secrets are encrypted with **SOPS** to an **age** recipient, so only
ciphertext is committed ([`../.sops.yaml`](../.sops.yaml)).

| Item | Value |
|---|---|
| age recipient (public) | `age1za7r9mcftlnw5dgs2w7je46apenkftkm65navsqxdfst0pwtpe3sale4vh` |
| age key (private) | `~/.config/sops/age/keys.txt` (mode `600`, **never** committed) |
| Workspace access | `~/.config/sops` → `/home/dev/.config/sops` (bind mount) |
| Config | [`../.sops.yaml`](../.sops.yaml) — encrypts `data`/`stringData` of `*.sops.yaml` |
| In-cluster key | Secret `sops-age` in `flux-system` (key `age.agekey`) — created at bootstrap |

The private key is generated once (`age-keygen`, 2026-10-14) and lives **outside**
the repo; only the public recipient is in git. Round-trip verified inside the
workspace (encrypt → ciphertext → decrypt).

### Observability — k9s single pane

`k9s` (v0.51.0, workspace) is the single TUI for listing/inspecting the cluster.
Its config is **repo-hosted** at [`../config/k9s/`](../config/k9s) and mounted into
the workspace at `/home/dev/.config/k9s`; `K9S_CONFIG_DIR` points k9s at it, so
nothing is added to the host `$HOME`.

| Item | Value |
|---|---|
| Config dir | `config/k9s/` → `/home/dev/.config/k9s` (`K9S_CONFIG_DIR`) |
| Landing view | pods, **all namespaces** (`clusters/default/default/config.yaml`) |
| Skin | `gruvbox-dark-hard` (matches host `bat`/`kitty`/`vim`) |
| Hotkeys | `Shift-0` nodes · `Shift-1` pods · `Shift-2` dp · `Shift-3` svc · `Shift-4` events · `Shift-5` ns · `Shift-H` pulses |

`k9s` is Kubernetes-only; the two VMs surface as the **Nodes** view. See
[runbook 04](runbooks/04-k9s-single-pane.md).

### Host tooling (after Phase 2 cleanup)

`kubectl` and `helm` were **removed** from `~/.local/bin` (they now exist only
inside the workspace). `terraform` v1.16.4 is **deliberately retained** at
`/usr/bin/terraform` (pre-existing, not installed by this project).

The host `PATH` no longer provides `kubectl`/`helm`, so `20-…`, `30-…` and
`40-verify.sh` must be run **inside the workspace** (`devpod ssh
k8s-homelab-kvm`). `preflight.sh` and `10-prepare-nodes.sh` need only
`ssh`/`python3` and still run on the host.

> **Note:** `dl.k8s.io` publishes `kubectl.sha256` as a **bare hash with no
> filename**, so `sha256sum -c` cannot consume it; verification is a manual hash
> compare. Helm, by contrast, publishes a normal `hash  filename` line.

---

## Networking

| Network | Subnet | Bridge | Autostart | Purpose |
|---|---|---|---|---|
| `default` | 192.168.122.0/24 | virbr0 | yes | libvirt built-in, unused by this cluster |
| `k8s` | 192.168.123.0/24 | virbr1 | yes | cluster traffic |

**`k8s` network definition:** [`../terraform/libvirt-k8s-net.xml`](../terraform/libvirt-k8s-net.xml)
(UUID `a547ca9d-acb1-486a-9ae3-e5cf44d2b88b`)

- Gateway: `192.168.123.1`
- DHCP dynamic pool: `192.168.123.128` – `192.168.123.254`
- Static reservations: `192.168.123.11` (cp), `192.168.123.12` (worker)

**Why a dedicated network rather than `default`:** two reasons.
1. `default` hands out addresses from a dynamic pool with no reservations, so
   node IPs change across reboots — that breaks Ansible inventories and any
   Terraform target referencing a fixed address.
2. The host's `kvm off` / `kvm on` functions run `virsh net-destroy default` on
   every session. Anything hand-edited into `default` is therefore fragile.

**Subnet choice:** `192.168.123.0/24` cannot overlap `default`'s active
`192.168.122.0/24`, or Linux routing breaks. `.10-99` is deliberately left
outside the DHCP pool for the static reservations.

### Name resolution

Node names resolve via `/etc/hosts` on both the host and each VM:

| Host file | Node files |
|---|---|
| `192.168.123.11 k8s-cp-01` | same two lines |
| `192.168.123.12 k8s-worker-01` | |

Verified bidirectional: `k8s-cp-01` → `k8s-worker-01` and back both ping.

> The `<host name='...'>` attribute in the network XML also makes dnsmasq serve
> these records on `192.168.123.1:53`, but `/etc/resolv.conf` is not pointed at
> that resolver, so `/etc/hosts` remains the mechanism actually in use.

---

## Memory budget

| Consumer | RAM |
|---|---|
| Host OS + desktop + TLP + libvirt daemons | ~4–5 GiB |
| `k8s-cp-01` | 3 GiB |
| `k8s-worker-01` | 1536 MiB |
| **Total** | **~9–10 GiB of 15 GiB** |

> **Bumped 2026-10-15 (Decision 4)** ahead of the Phase 6 monitoring stack:
> `k8s-cp-01` 2 GiB → 3 GiB, `k8s-worker-01` 1 GiB → 1536 MiB. Done on
> shut-off domains (`setmaxmem` then `setmem`, `--config`); `memory_mib` in
> [`inventory/nodes.yml`](../inventory/nodes.yml) updated to match.

**Watch items:**
- `k8s-worker-01` had **~880 MiB available** idle before Phase 6 — headroom for
  node-exporter and scheduling.
- `k8s-cp-01` had **~1600 MiB available** with the control plane up, which is
  what made room for the trimmed Prometheus/Grafana stack.
- **After Phase 6** (monitoring stack running, 2026-10-15): `kubectl top nodes`
  reports `k8s-cp-01` **1847 Mi / 2977 Mi (63%)** and `k8s-worker-01`
  **903 Mi / 1463 Mi (61%)** — both nodes below 65% with all 6 monitoring pods up.

Bump commands if a future phase needs more (raise the max **before** the current
size; do it on a shut-off domain so it persists cleanly):

```bash
# Example: raise k8s-cp-01 from 3 GiB to 4 GiB (adjust size per node).
virsh shutdown k8s-cp-01
virsh setmaxmem k8s-cp-01 4096M --config
virsh setmem    k8s-cp-01 4096M --config
virsh start k8s-cp-01
```

(Set `setmaxmem` before `setmem`. Update `memory_mib` in `inventory/nodes.yml`
to match.)

---

## Not yet installed

Recorded so the runbooks don't assume availability.

On the **host**: `tuned` (intentional), `k3d`, `flux`, `pipx`, `genisoimage`.
**`ansible` is intentionally *not* adopted** (2026-10-15) — keep
`scripts/10-prepare-nodes.sh`; see [ADR-0005](adr/0005-no-ansible-node-config.md).

In the **workspace**: `kubeseal`, `kustomize` — still confirmed absent on
**2026-10-14**. `kubectl -k` covers Kustomize, so a standalone `kustomize` binary
is not planned. `flux`, `sops` and `age` were added to the `Containerfile` on
2026-10-14 (Phase 3), with checksum verification where upstream publishes one.

Also installed and verified:

On the **host**: `nvim` 0.12.5, `terraform` v1.16.4 (`/usr/bin`), `python3` +
PyYAML 6.0.3, `jq` 1.8.1, `virt-install`, `git` 2.55.0, `virsh` (host
`kubectl`/`helm` removed — see the workspace section above).

In the **workspace**: `kubectl` v1.37.1, `helm` v4.3.0, `terraform`
v1.16.4, `k9s` v0.51.0, `yq` v4.54.1, `nvim` v0.12.6, `flux` v2.9.6,
`sops` v3.13.3, `age` v1.3.1, `git`, `jq`, `python3` + PyYAML.

---

## Current phase status

| Phase | Item | Status |
|---|---|---|
| 0 | Host prerequisites (KVM, libvirt, TLP) | ✅ done |
| 0 | SSH key | ✅ done |
| 0 | `k8s` libvirt network + IP reservations | ✅ done |
| 0 | Two VMs created and reachable | ✅ done |
| 1 | Node prep (kernel convergence, modules, sysctl) | ✅ done |
| 1 | Host tooling (kubectl, helm, terraform) | ✅ done |
| 1 | k3s installed on control plane | ✅ done |
| 1 | Worker joined | ✅ done |
| 1 | Cluster verified (13/13) + DNS smoke test | ✅ done |
| 2 | Operator Devpod workspace defined (Podman + Devpod, Fedora base) | ✅ done |
| 2 | Workspace builds, runs as `dev`, cluster reachable from workspace | ✅ done |
| 2 | Host tooling cleaned up (`kubectl`/`helm` removed, trash emptied) | ✅ done |
| 2 | k9s single pane (repo-hosted config, gruvbox, mounted via `K9S_CONFIG_DIR`) | ✅ done |
| 3 | GitOps tooling in workspace (`flux` v2.9.6, `sops` v3.13.3, `age` v1.3.1) | ✅ done |
| 3 | age key + [`.sops.yaml`](../.sops.yaml); SOPS round-trip verified | ✅ done |
| 3 | `flux bootstrap github` → Flux controllers in-cluster + SOPS/age wired + Envoy Gateway + podinfo | ✅ done |
| 5 | IaC re-scoped — Ansible dropped, Terraform deferred ([ADR-0005](adr/0005-no-ansible-node-config.md)) | ✅ done |
| 6 | Monitoring stack (`kube-prometheus-stack` 92.7.0) deployed via Flux `HelmRelease` | ✅ done |
| 6 | Grafana exposed at `grafana.local` (HTTPRoute + ReferenceGrant), admin via SOPS secret | ✅ done |
| 6 | Decision 4 (sizing) resolved — VMs bumped, stack fits under 65% per node | ✅ done |

### Deferred / not yet done

- Git repository **initialized + pushed** to private GitHub
  (`wasim-hassan/k8s-homelab-kvm`) on 2026-10-14.
- `virsh autostart` still `disable` for both VMs (they do not start with the host).
- Host trash is **empty** (0 B) as of 2026-10-12.
- `~/.cache/k3s-homelab/k3s-v1.37.1+k3s1` (78 MiB, verified) is **retained** — it
  is bind-mounted read-only into the workspace.
- Next: **Phase 7 (Security hardening)** — RBAC, Pod Security Standards, secrets
  hygiene audit. NetworkPolicy waits on Phase 4 (Cilium). Phase 6 is complete —
  see [runbook 06](runbooks/06-observability.md).

---

## GitOps state (Phase 3 — Flux CD)

Verified 2026-10-15, reconciled at `main@sha1:46196596`.

| Item | Value |
|---|---|
| Flux version | **v2.9.6** (source / kustomize / helm / notification controllers) |
| Bootstrap | `flux bootstrap github` (read-only **deploy key**, `--token-auth=false`) |
| Git source | `ssh://git@github.com/wasim-hassan/k8s-homelab-kvm` (branch `main`, path `clusters/k8s-homelab`) |
| App-of-apps | [`../clusters/k8s-homelab/`](../clusters/k8s-homelab) — `flux-system` + `infrastructure.yaml` + `apps.yaml` |
| Kustomizations | `flux-system`, `infrastructure`, `apps` — all `Ready=True` |
| SOPS decryption | `spec.decryption` (`provider: sops`, `secretRef: sops-age`) on `infrastructure` + `apps` |

### Envoy Gateway (infrastructure)

| Item | Value |
|---|---|
| Version | **v1.9.2** (chart `1.9.2+be034275b55d`) |
| Source | OCIRepository `gateway-helm` → `oci://docker.io/envoyproxy/gateway-helm` |
| Delivery | HelmRelease `envoy-gateway` (releaseName `eg`) in `envoy-gateway-system` |
| GatewayClass | `eg` — `Accepted=True` |
| Gateway | `eg` — `Programmed=True`, address **`192.168.123.11`** |
| Manifests | [`../infrastructure/envoy-gateway/`](../infrastructure/envoy-gateway) |

### First workload (podinfo)

| Item | Value |
|---|---|
| Namespace | `podinfo` |
| Image | `ghcr.io/stefanprodan/podinfo:6.7.1` |
| Resources | requests `cpu 10m / mem 32Mi`; limits `cpu 200m / mem 64Mi` |
| Service | ClusterIP `80` → container `9898` |
| Routing | HTTPRoute `podinfo` host `podinfo.local` → Gateway `eg`; ReferenceGrant `allow-podinfo-to-gateway` |
| Secret | SOPS-encrypted `podinfo-message` (decrypted in-cluster) → `PODINFO_UI_MESSAGE` |
| Manifests | [`../apps/podinfo/`](../apps/podinfo) |

### Monitoring (Phase 6 — observability)

Verified 2026-10-15, reconciled at `main@sha1:e535a647`.

| Item | Value |
|---|---|
| Chart | **kube-prometheus-stack 92.7.0** (app v0.94.1) via `HelmRepository prometheus-community` |
| Delivery | HelmRelease `kube-prometheus-stack` in `monitoring` — `Ready=True` |
| Prometheus | **v3.15.0**; retention `6h` / `1500MB`; PVC 2Gi on `local-path` (Bound) |
| Grafana | **13.2.4** (distroless), Service `grafana:80`, route host `grafana.local` |
| Grafana resources | `requests 100m/384Mi`, `limits 500m/768Mi`; sidecars `64Mi`/`128Mi` (raised 2026-10-15 to 768Mi for headroom after near-limit usage — commits `e535a64`, earlier `9550bb4`) |
| operator | `prometheus-operator` v0.94.1 |
| kube-state-metrics | v2.20.0 |
| node-exporter | v1.12.1 (DaemonSet, 1 per node) |
| Alertmanager | **disabled** (no notification target; saves memory) |
| k3s control-plane monitors | et **disabled** — `kubeEtcd`/`kubeControllerManager`/`kubeScheduler`/`kubeProxy` off (k3s uses SQLite and embeds the control plane; no endpoints) |
| Targets | 15 active, **15 up** |
| ServiceMonitors | 8 |
| Dashboards | 24 provisioned ConfigMaps (`grafana_dashboard=1`) |
| Secret | SOPS-encrypted `grafana-admin` (`admin-user` / `admin-password`) |
| Manifests | [`../infrastructure/monitoring/`](../infrastructure/monitoring) |