# Runbook 01 — Install k3s (control plane + worker)

**Goal:** turn the two provisioned Ubuntu VMs into a working 2-node k3s
cluster, with a cluster-admin kubeconfig on the workstation.

**Topology**

| Node | Role | IP | RAM | Notes |
|---|---|---|---|---|
| `k8s-cp-01` | control-plane (server) | 192.168.123.11 | 2 GiB | also the only scheduler target until more workers exist |
| `k8s-worker-01` | worker (agent) | 192.168.123.12 | 1 GiB | joins via server token |

Version: **`v1.37.1+k3s1`**, pinned. Matches the **workspace** `kubectl`
v1.37.1. The cluster tooling lives in the Devpod workspace, **not** on the host —
see [ADR-0003](../adr/0003-devpod-workspace.md) and
[runbook 02](02-devpod-workspace.md).

---

## Preconditions

- `./scripts/preflight.sh` → **21/21**
- Both VMs running and on their reserved IPs
- Passwordless `sudo` over SSH on both nodes (verified)
- Guest outbound internet (NAT) working — needs `get.k3s.io` and distro mirrors

If any of these is false, stop and fix it first. The scripts assume them
and will fail loudly rather than work around them.

---

## Execution order

> **Where these run.** Steps **1–3** and the `virsh` commands run on the
> **host**. Steps **4–6** (`20-…`, `30-…`, `40-verify.sh`) call `kubectl`, which
> now exists **only in the Devpod workspace** — run them **inside** the
> workspace. See [runbook 02](02-devpod-workspace.md).

### On the host (repo root `~/Sync/Repos/k8s-homelab-kvm`)

```bash
# 1. Baseline: converge kernels, persist modules + sysctl
./scripts/10-prepare-nodes.sh

# 2. Reboot so the upgraded kernel is the running kernel
virsh shutdown k8s-cp-01
virsh shutdown k8s-worker-01
# wait for both to show "shut off"
virsh start k8s-cp-01
virsh start k8s-worker-01
sleep 60

# 3. Confirm the substrate is still intact
./scripts/preflight.sh
```

### Inside the workspace (`/workspaces/k8s-homelab-kvm`)

> Enter with `devpod ssh k8s-homelab-kvm` first. These scripts shell out to the
> nodes over SSH (the key and `~/.ssh/config` are mounted in), so they work from
> inside the workspace exactly as they would on a host that had `kubectl`.

```bash
# 4. Install the control plane + pull kubeconfig to ~/.kube/config
./scripts/20-install-k3s-server.sh

# 5. Join the worker
./scripts/30-join-worker.sh

# 6. Independent health check
./scripts/40-verify.sh
```

Expected end state: `kubectl get nodes` shows both nodes `Ready`.

---

## Why the steps are ordered this way

### Kernel convergence before k3s (step 1 → 2)

The nodes were provisioned on different kernel patch levels
(`6.8.0-137` and `6.8.0-142`). `dist-upgrade` installs the newer kernel,
but the running kernel is still the old one until reboot — and kernel
modules load against the **running** kernel. Doing the upgrade first and
rebooting once means `overlay`/`br_netfilter` are loaded against the
kernel that k3s will actually run on. Otherwise you can end up with
modules loaded into a kernel the node reboots out of.

### Persisted modules and sysctl (step 1)

`10-prepare-nodes.sh` writes:

- `/etc/modules-load.d/k8s.conf` → `overlay`, `br_netfilter`, `nf_conntrack`
- `/etc/sysctl.d/99-kubernetes.conf` → bridge-nf-call-ip(6)tables, ip_forward

Both are **persisted across reboot**, not just applied in the moment.
`modprobe` and `sysctl --system` are run too, so the current boot is also
correct. Without persistence, a node silently loses the bridge sysctls
after a reboot and pods lose networking.

### Version pinning (step 4)

`INSTALL_K3S_VERSION` is set explicitly. An unpinned install follows the
`stable` channel and can advance the control plane independently of the
host `kubectl`. Pinning makes the install reproducible and the result
checkable.

### The k3s binary is staged from the host, not downloaded by the nodes

The installer scripts run with `INSTALL_K3S_SKIP_DOWNLOAD=true`. Before
installing, `lib.sh`:

1. downloads the pinned binary **once** to the host cache
   (`~/.cache/k3s-homelab/k3s-<version>`),
2. verifies its SHA256 against the release `sha256sum-amd64.txt`,
3. `scp`s it to the node and installs it at `/usr/local/bin/k3s`.

**Why:** GitHub release downloads are heavily throttled from this network
(~260 KB/s on the host, ~61 KB/s from inside the VMs), and inside the VM
the download stalled at 0 bytes for over 10 minutes. The 78 MiB binary
takes ~5 min on the host but potentially 20+ min in-guest. Staging on the
host transfers it over the local libvirt bridge instead, which is not
subject to the WAN throttle — and the slow path runs exactly once for both
nodes. This also gives a clean checksum checkpoint.

`INSTALL_K3S_SKIP_DOWNLOAD=true` makes the installer call
`verify_k3s_is_executable`, which requires the binary to already exist at
`/usr/local/bin/k3s`. The staging step guarantees that.

To move the cache location, set `K3S_CACHE_DIR` when invoking the scripts.

---

## Design decisions in this runbook

### Traefik is disabled

The server is installed with `--disable traefik`.

- **Cost if enabled:** ~180 MiB RSS and ~40 CRDs/RBAC objects on a control
  plane with ~1.5 GiB free.
- **When you need it:** the day you expose an HTTP(S) service to the LAN.
- **How to add it later:** either install k3s with Traefik on next rebuild,
  or add the standard HelmRelease:

  ```bash
  helm repo add traefik https://traefik.github.io/charts
  helm repo update
  kubectl create namespace traefik
  helm install traefik traefik/traefik -n traefik
  ```

**To reverse at install time:** edit `DISABLE_TRAEFIK=0` in
`20-install-k3s-server.sh` and rebuild. Note that flipping it on an already
installed cluster requires reinstalling or manually deploying Traefik.

### `--write-kubeconfig-mode 644`

Lets the operator read the server's own kubeconfig without sudo. The copy
placed at `~/.kube/config` is still `chmod 600`, because it is a
cluster-admin credential — 644 applies to the file on the node, not the
copy on the workstation.

### Worker RAM is tight

`k8s-worker-01` reports **961 MiB** total (inventory says 1024 — the
hypervisor reserves ~63 MiB). k3s agent idles around 400–500 MiB, leaving
roughly 170–300 MiB of headroom. It fits, but before running real
workloads consider raising it to 1536 MiB:

```bash
virsh shutdown k8s-worker-01
virsh setmaxmem k8s-worker-01 1536M --config
virsh setmem   k8s-worker-01 1536M --config
virsh start k8s-worker-01
```

Also update `memory_mib` in `inventory/nodes.yml` so the docs stay honest.

---

## Troubleshooting

### `get.k3s.io` fails / installer hangs

The installer script is fetched from `get.k3s.io` (small, responds instantly).
The **binary**, however, is staged by the host and never downloaded by the
node, so a slow GitHub connection should not affect installation. If the
install still hangs, confirm the host can reach the release:

```bash
curl -sIL -o /dev/null -w '%{http_code}\n' \
  "https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s"
```

If the host itself cannot reach GitHub, pre-place the binary manually:

```bash
scp /path/to/k3s k8s-cp-01:/tmp/k3s.download
ssh k8s-cp-01 'sudo install -m 0755 /tmp/k3s.download /usr/local/bin/k3s'
```

Also confirm the guests have outbound access at all:

```bash
ssh k8s-cp-01 'curl -sI https://get.k3s.io -o /dev/null -w "%{http_code}\n"'
```

and that the `k8s` libvirt network is `active` in NAT mode
(`virsh net-dumpxml k8s | grep forward`).

### `k3s.service` won't start

```bash
ssh k8s-cp-01 'sudo journalctl -u k3s -n 80 --no-pager'
```

Common causes:

| Symptom in log | Cause | Fix |
|---|---|---|
| `failed to load module overlay` | module not loaded | re-run `10-prepare-nodes.sh` |
| `address already in use :6443` | stale k3s from a previous attempt | `ssh <node> 'sudo k3s-killall.sh'` then reinstall |
| `ip_forward is disabled` | sysctl not applied | re-run `10-prepare-nodes.sh` |

### Worker never reaches `Ready`

```bash
ssh k8s-worker-01 'sudo journalctl -u k3s-agent -n 80 --no-pager'
kubectl describe node k8s-worker-01 | sed -n '/Conditions/,/Events/p'
```

Most common: the token expired mid-join, or `K3S_URL` points at a stale IP.
Re-read the token and re-run `30-join-worker.sh`:

```bash
ssh k8s-cp-01 'sudo cat /var/lib/rancher/k3s/server/node-token'
```

### `kubectl` shows connection refused

The kubeconfig points at `192.168.123.11:6443`. Confirm the host can reach
it:

```bash
timeout 5 bash -c 'echo > /dev/tcp/192.168.123.11/6443' && echo open || echo closed
```

If closed, verify the `k8s` network is active and the firewall `libvirt`
zone is intact (it should be — see the note below).

### `kubectl` is still trying 127.0.0.1

The server writes `127.0.0.1` in `/etc/rancher/k3s/k3s.yaml`. The install
script rewrites it to the node IP. If you copied the file manually:

```bash
sed -i 's|server: https://127.0.0.1:6443|server: https://192.168.123.11:6443|' ~/.kube/config
```

---

## Notes / gotchas discovered while building this

- **Firewalld is not a problem.** The host `libvirt` zone has `target:
  ACCEPT` and a low-priority `reject` rule. That reject blocks traffic
  **destined for the host**, not forwarded or outbound traffic. Host→guest
  and guest→guest are unaffected. No firewall changes are needed.
- **`ufw` reports `inactive` even though `systemctl is-active ufw` says
  `active`.** The daemon runs but has never been enabled, so no rules
  apply. Don't be misled by the service state.
- **The host `rm` is a trash wrapper** (`~/.dotutils/move-to-trash-bin.sh`)
  that rejects `-f`/`-rf`. Scripts use `command rm` where real deletion is
  intended.

---

## Rollback

To tear the cluster down but keep the VMs:

```bash
# On each node
ssh k8s-cp-01   'sudo /usr/local/bin/k3s-uninstall.sh'
ssh k8s-worker-01 'sudo /usr/local/bin/k3s-agent-uninstall.sh'

# On the host
command rm -f ~/.kube/config
```

The VMs return to a clean Ubuntu state; `10-prepare-nodes.sh` changes
(modules, sysctl) remain and are harmless.

---

## Verification checklist

- [ ] `./scripts/preflight.sh` → 21/21
- [ ] `./scripts/10-prepare-nodes.sh` → all modules loaded, sysctl applied
- [ ] reboot completed, both nodes back on reserved IPs
- [ ] `./scripts/20-install-k3s-server.sh` → `k3s.service` active
- [ ] `~/.kube/config` exists, mode `600`
- [ ] `./scripts/30-join-worker.sh` → `k3s-agent.service` active
- [ ] `kubectl get nodes` → both `Ready`
- [ ] `./scripts/40-verify.sh` → all checks passed
- [ ] `https://192.168.123.11:6443` reachable from the host
