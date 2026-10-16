# System Inventory — k8s-homelab-kvm

Verified state of the host and cluster. Every value below was confirmed by running
the command shown, not assumed.

Last verified: 2026-10-16

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
| 3 | Flux upgraded to **operator-managed** (Flux Operator 0.61.0 + FluxInstance) with the Flux Web UI at `flux.local` ([ADR-0006](adr/0006-flux-operator-managed.md), [runbook 07](runbooks/07-flux-webui.md)) | ✅ done |
| 7 | Security hardening — trivy CLI, PSS, RBAC, secrets hygiene ([ADR-0007](adr/0007-security-hardening.md)) | ✅ done |
| 7b | **Trivy Operator** + Grafana dashboard (continuous scanning); `flux-system` PSS labels made declarative ([ADR-0008](adr/0008-trivy-operator.md)) | ✅ done |
| 8 | CI/CD — GitHub Actions builds `ratlab-demo` → GHCR (trivy + SBOM + provenance) ([ADR-0009](adr/0009-ci-cd-image-automation.md)) | ✅ done |
| 8 | Flux image automation — image-reflector + image-automation controllers, ImageRepository/ImagePolicy/ImageUpdateAutomation, SOPS write key ([ADR-0009](adr/0009-ci-cd-image-automation.md)) | ✅ done |
| 8 | `ratlab-demo` workload deployed via Flux (Deployment/Service/HTTPRoute), image tag managed by Flux | ⏳ pending manual GHCR visibility + write deploy key |

### Deferred / not yet done

- Git repository **initialized + pushed** to private GitHub
  (`wasim-hassan/k8s-homelab-kvm`) on 2026-10-14.
- `virsh autostart` still `disable` for both VMs (they do not start with the host).
- Host trash is **empty** (0 B) as of 2026-10-12.
- `~/.cache/k3s-homelab/k3s-v1.37.1+k3s1` (78 MiB, verified) is **retained** — it
  is bind-mounted read-only into the workspace.
- The **Flux Web UI** was added 2026-10-15 by migrating Flux to the Flux Operator
  (a Phase 3 evolution) — see [runbook 07](runbooks/07-flux-webui.md) and
  [ADR-0006](adr/0006-flux-operator-managed.md). Requires `192.168.123.11 flux.local`
  in the host `/etc/hosts` (manual, needs sudo).
- **Phase 7 (Security hardening)** — done 2026-10-15: RBAC audit + least-privilege for `podinfo`, PSS applied (podinfo/envoy/flux-system `restricted`, monitoring `privileged` with documented node-exporter exception), trivy v0.75.0 pinned + checksum-verified in devcontainer, secrets hygiene audit (SOPS-only). NetworkPolicy waits on Phase 4 (Cilium). See [runbook 08](runbooks/08-security-hardening.md) and [ADR-0007](adr/0007-security-hardening.md). Phase 6 is complete — see [runbook 06](runbooks/06-observability.md).
- **Phase 7b (Trivy Operator)** — done 2026-10-16: continuous in-cluster scanning (image/config/secret/RBAC) via the Trivy Operator, results in a Grafana dashboard; infra-assessment disabled to stay `restricted`. `flux-system` PSS labels moved from imperative to declarative (`FluxInstance.spec.commonMetadata`); `podinfo` remediated to 6.15.0 (findings triage). See [ADR-0008](adr/0008-trivy-operator.md).

---

## Security (Phase 7)

Verified 2026-10-15. See [ADR-0007](adr/0007-security-hardening.md) and [runbook 08](runbooks/08-security-hardening.md).

**Scanner (single tool):** **Trivy v0.75.0** — pinned + SHA256-verified in `.devcontainer/Containerfile` (`trivy_0.75.0_Linux-64bit.tar.gz` vs `trivy_0.75.0_checksums.txt`). `trivy config` = manifest/IaC policy (kube-linter replacement, no vuln DB); `trivy fs --scanners secret` = secret scan; image CVE/SBOM deferred to Phase 8. Containerfile now ends `USER dev`.

**RBAC (cluster-admin holders — all required, no stray grants):**

| ClusterRoleBinding | Subjects |
|---|---|
| `cluster-admin` | Group `system:masters` (built-in) |
| `cluster-reconciler-flux-system` | `kustomize-controller`, `helm-controller` |
| `flux-operator` | `flux-operator` |
| `helm-kube-system-gateway-api-crd` | `helm-gateway-api-crd` (CRD install job) |

- `podinfo` uses dedicated `ServiceAccount podinfo`, `automountServiceAccountToken: false`, **no** Role/RoleBinding (no API access).
- Flux Web UI: `ClusterRoleBinding flux-admin → ClusterRole flux-web-admin` (**not** cluster-admin); host-only at `flux.local`.
- Non-default ServiceAccounts: only Flux (5), Gateway (3), monitoring (5), kube-system built-ins.

**Pod Security Standards (namespace labels):**

| Namespace | enforce | warn / audit | Note |
|---|---|---|---|
| `podinfo` | **restricted** | restricted | Deployment hardened (runAsNonRoot, numeric uid 100, RuntimeDefault seccomp, drop ALL, no priv-esc, read-only rootfs) |
| `envoy-gateway-system` | **restricted** | restricted | Verified: no hostPort/hostNetwork; only configMap/secret/emptyDir/projected volumes |
| `flux-system` | **restricted** | restricted | Set **declaratively** via `FluxInstance.spec.commonMetadata.labels` (operator re-applies every reconcile; [ADR-0008](adr/0008-trivy-operator.md)) |
| `trivy-system` | **restricted** | restricted | Trivy Operator + unprivileged scan jobs (numeric non-root uid 10000, RuntimeDefault, drop ALL, roFS) |
| `monitoring` | **privileged** | baseline | node-exporter needs `hostNetwork`+`hostPID`+`hostPath` — documented exception; other monitoring pods satisfy restricted |
| `default`, `kube-public`, `kube-node-lease` | — | — | No workloads / system-managed |
| `kube-system` | — | — | System-managed (k3s) |

**Secrets hygiene:** `trivy fs --scanners secret .` → **0 secrets**. Only SOPS ciphertext tracked (`apps/podinfo/secret.sops.yaml`, `infrastructure/monitoring/secret.sops.yaml`); `.sops.yaml` holds only the public age recipient; private key at `~/.config/sops/age/keys.txt` (never committed); `.gitignore` covers `.env`, `*.agekey`, `keys.txt`, `tfstate`, `AGENTS.local.md`.

**Not done here:** NetworkPolicy — deferred until a policy-capable CNI (Phase 4/Cilium).

### Security scanning (Phase 7b — Trivy Operator)

Verified 2026-10-16, reconciled at `main@sha1:8c2d051`. Continuous in-cluster
scanning; results rendered in Grafana (the "web UI"). See
[ADR-0008](adr/0008-trivy-operator.md) and [runbook 08](runbooks/08-security-hardening.md).

| Item | Value |
|---|---|
| Component | **Trivy Operator** (chart **0.37.0**, app **v0.35.0**) via `HelmRelease` in `trivy-system` |
| Source | `HelmRepository aqua` → `https://aquasecurity.github.io/helm-charts` |
| Images | operator `mirror.gcr.io/aquasec/trivy-operator:0.35.0` (uid 10000); scan jobs `mirror.gcr.io/aquasec/trivy` (forced non-root) |
| Mode | `trivy.mode: Standalone` — no server, no PVC (each job pulls the DB to its `/tmp` emptyDir) |
| Scans | image CVE, config-audit, exposed-secret, RBAC (+ cluster-RBAC) |
| Disabled | **infra-assessment / node-collector** (`infraAssessmentScannerEnabled: false`) — needs hostPath+root, incompatible with `restricted` |
| Reports (CRs) | `vulnerabilityreports` 20 · `configauditreports` 41 · `exposedsecretreports` 20 · `rbacassessmentreports` 12 · `clusterrbacassessmentreports` 97 · `infraassessmentreports` 0 |
| Metrics | info metrics enabled (`metricsExposedSecretInfo`, `metricsRbacAssessmentInfo`, `metricsClusterComplianceInfo`, `metricsConfigAuditInfo`); ServiceMonitor `release=kube-prometheus-stack` |
| Dashboard | Grafana **17813** "Trivy Operator Dashboard" as a `ConfigMap` (`grafana_dashboard=1`) in `infrastructure/monitoring/dashboards/` |
| Manifests | [`../infrastructure/trivy-operator/`](../infrastructure/trivy-operator), [`../infrastructure/monitoring/dashboards/`](../infrastructure/monitoring/dashboards) |

**Findings triage (accepted).** Trivy findings are **not** driven to zero. The one
workload we own, `podinfo`, was remediated by upgrading `6.7.1 → 6.15.0`
(report `critical=0 high=0 medium=0 low=0`, was 6/36/16/7) — which took
cluster-wide **Critical 6 → 0**, total **897 → 701**. The remaining findings are
on upstream/system images (coredns, flux controllers, klipper-helm,
kube-state-metrics, …) and required system RBAC objects; they are remediated by
platform upgrades and otherwise **accepted** (see [ADR-0008](adr/0008-trivy-operator.md#findings-triage-accepted-risk)).

---

## CI/CD + image automation (Phase 8)

Added 2026-10-16. See [ADR-0009](adr/0009-ci-cd-image-automation.md) and
[runbook 09](runbooks/09-ci-cd-image-automation.md).

| Item | Value |
|---|---|
| App built | `ratlab-demo` — Go HTTP server, `scratch` image, `USER 65532:65532` ([`images/ratlab-demo/`](../images/ratlab-demo)) |
| Registry | `ghcr.io/wasim-hassan/ratlab-demo` (GHCR) |
| CI | GitHub Actions [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml) — buildx build/push; tags from `docker/metadata-action` (`{{version}}`, `{{major}}.{{minor}}`, branch, `sha`, `latest`) |
| Supply chain | trivy image scan (`aquasecurity/trivy-action@0.36.0`, SARIF, severity CRITICAL/HIGH, ignore-unfixed) · SBOM (`anchore/sbom-action@v0` / syft, SPDX-JSON) · provenance (`actions/attest-build-provenance@v4`, pushed to registry) |
| Flux components added | `image-reflector-controller`, `image-automation-controller` (via `FluxInstance.spec.components`) |
| `ImageRepository` | `flux-system/ratlab-demo` → `ghcr.io/wasim-hassan/ratlab-demo`, 5m |
| `ImagePolicy` | `flux-system/ratlab-demo` — semver `>=0.1.0` |
| `ImageUpdateAutomation` | `flux-system/flux-system` — `update.strategy: Setters`, commits to `main` |
| Write GitRepository | `flux-system/flux-git-write` (`source.toolkit.fluxcd.io/v1`) backed by SOPS Secret `flux-git-write` (`identity`/`identity.pub`/`known_hosts`) |
| Setter marker | `apps/ratlab-demo/deployment.yaml`: `# {"$imagepolicy": "flux-system:ratlab-demo"}` |
| Workload | `ratlab-demo` ns (PSS `restricted`) — Deployment/Service/HTTPRoute, routed at `ratlab-demo.local` |
| Tag convention | release-driven: only `vX.Y.Z` tags match the `ImagePolicy` (main pushes produce unmatched `sha`/`latest`) |
| Manual prerequisites | (1) write deploy key added on GitHub; (2) GHCR package `ratlab-demo` set **public** |

**Verified this session:** image ref+automation controllers `1/1 Running`; CRDs
`imagerepositories/imagepolicies/imageupdateautomations` present; `image-automation`
Kustomization `Ready`; the write `GitRepository`, `ImageRepository`, `ImagePolicy`,
`ImageUpdateAutomation` objects created. **Pending (manual, GitHub-side):** adding
the write deploy key (`flux-git-write` source currently `Ready=False: unable to
authenticate`) and making the GHCR package public (`ImageRepository` currently
`DENIED: requested access to the resource is denied`) — until then `ratlab-demo`
is `ImagePullBackOff`.

---

## GitOps state (Phase 3 — Flux CD, now operator-managed)

Verified 2026-10-16, reconciled at `main@sha1:8c2d051`.

| Item | Value |
|---|---|
| Flux version | **v2.9.6** (source / kustomize / helm / notification controllers) |
| Managed by | **Flux Operator 0.61.0** via `FluxInstance flux` — migrated from CLI bootstrap 2026-10-15 ([ADR-0006](adr/0006-flux-operator-managed.md), [runbook 07](runbooks/07-flux-webui.md)) |
| Git source | `ssh://git@github.com/wasim-hassan/k8s-homelab-kvm` (`refs/heads/main`, path `clusters/k8s-homelab`) |
| App-of-apps | [`../clusters/k8s-homelab/`](../clusters/k8s-homelab) — `infrastructure.yaml` + `flux-instance.yaml` + `apps.yaml` |
| Kustomizations | `flux-system`, `infrastructure`, `flux-instance`, `apps` — all `Ready=True` |
| SOPS decryption | `spec.decryption` (`provider: sops`, `secretRef: sops-age`) on `infrastructure` + `apps` |

> The original `flux bootstrap` manifests (`clusters/k8s-homelab/flux-system/`)
> were removed once the operator adopted Flux. The operator annotates its objects
> `kustomize.toolkit.fluxcd.io/prune: Disabled` (and `ssa: Ignore`), so the old
> Kustomization could not prune the Flux CRDs/components. The `flux-system`
> Kustomization/GitRepository now carry `app.kubernetes.io/managed-by: flux-operator`.

### Flux Operator + Web UI

| Item | Value |
|---|---|
| Chart | **flux-operator 0.61.0** (app v0.61.0) via OCIRepository `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` |
| Delivery | HelmRelease `flux-operator` in `flux-system` — `Ready=True` |
| FluxInstance | `flux` — `Ready=True`, distribution `v2.9.6@sha256:40bc63c1…` |
| Web UI | Flux Status on Service `flux-operator:9080`; HTTPRoute `flux-operator` host `flux.local` (`Accepted=True`) |
| Identity | anonymous user `admin` in group `flux-admin` → ClusterRoleBinding `flux-admin` → ClusterRole `flux-web-admin` (view + actions) |
| ReferenceGrant | `allow-flux-system-to-gateway` (in `envoy-gateway-system`) |
| Manifests | [`../infrastructure/flux-operator/`](../infrastructure/flux-operator) + [`../clusters/k8s-homelab/flux-instance/`](../clusters/k8s-homelab/flux-instance) |

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
| Image | `ghcr.io/stefanprodan/podinfo:6.15.0` |
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
| Dashboards | 25 provisioned ConfigMaps (`grafana_dashboard=1`) — 24 from the chart + **Trivy Operator Dashboard** (17813, Phase 7b) |
| Secret | SOPS-encrypted `grafana-admin` (`admin-user` / `admin-password`) |
| Manifests | [`../infrastructure/monitoring/`](../infrastructure/monitoring) |