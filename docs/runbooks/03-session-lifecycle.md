# Runbook 03 — Session lifecycle (start / stop the homelab)

**Goal:** bring the whole homelab up and take it down in the correct order, every
time, without corrupting the cluster or the VM disks.

There are **three layers**, in this order:

| Layer | Start | Stop | Why order matters |
|---|---|---|---|
| Virtualization host services | `kvm on` | `kvm off` | daemons + networks must exist before VMs |
| The two VMs (k3s nodes) | control plane **first**, then worker | worker **first**, control plane last | etcd must be the last to stop, first to be ready |
| Operator workspace | `devpod up . --ide none` | `devpod stop k8s-homelab-kvm` | needs host net + kubeconfig; independent of the VMs |

> The VMs have `virsh autostart` **disabled** and `kvm off` **masks** the libvirt
> daemons, so nothing auto-starts on boot. You must run `kvm on` by hand each
> session — by design.

---

## Start (morning / after a reboot)

```bash
# 1. Host: unmask + start libvirt daemons, restart the default network.
#    (Requires your fingerprint if sudo is configured with polkit auth.)
kvm on

# 2. Start the CONTROL PLANE first.
vm start k8s-cp-01

# 3. Wait until it is actually running with its reserved IP (not just "defined").
vm
#   -> k8s-cp-01   running   192.168.123.11
#      k8s-worker-01 shut off -

# 4. Give k3s a moment, then start the WORKER.
vm start k8s-worker-01
vm
#   -> both running, 192.168.123.11 / 192.168.123.12

# 5. Resume the operator workspace.
cd ~/Sync/Repos/k8s-homelab-kvm
devpod up . --ide none
```

### Verify the session is healthy

```bash
# from inside the workspace
devpod ssh k8s-homelab-kvm --command 'kubectl get nodes'
# expect: k8s-cp-01 and k8s-worker-01 both Ready
```

If a node is `NotReady`, give it ~30–60 s (k3s agent reconnect + Flannel), then
re-run. Persistent `NotReady` → see the troubleshooting log.

---

## Stop (evening / before shutting down the laptop)

Stop in the **reverse** order. k3s/etcd writes continuously, so let the control
plane flush last.

```bash
# 1. Stop the workspace (optional but tidy).
devpod stop k8s-homelab-kvm

# 2. Shut down the WORKER first.
ssh k8s-worker-01 sudo poweroff

# 3. Shut down the CONTROL PLANE last.
ssh k8s-cp-01 sudo poweroff

# 4. WAIT for both to reach "shut off". Do NOT use a fixed sleep.
watch -n2 'virsh list --all'
#   -> both "shut off", then Ctrl-C

# 5. Stop + mask the virtualization services and free RAM.
kvm off
```

**Do not** use `kvm off` before both VMs report `shut off`, and **never** use
`vm destroy` — that is a hard power-off and wipes the disk.

---

## Why this order

- **Control plane first / last.** The worker is an agent of the server; starting
  it before the server just means it retries. The server holds etcd, so on
  shutdown it should be the last writer to stop.
- **Wait for the real state, not a timer.** `kvm off`'s own code waits only 5
  seconds before stopping the daemon, and libvirt kills any still-running domain
  when its daemon stops — an unclean power-off. Always confirm `shut off` first
  (this was a real incident — see the troubleshooting log, 2026-10-10).
- **`kvm on` before `vm start`.** The `k8s` libvirt network and the `virsh`
  daemons must be up, or `vm start` has nothing to attach to.

---

## Quick commands

```bash
# status
kvm                       # daemon + VM + network status
vm                        # list VMs with IPs
virsh list --all          # raw domain states

# start / stop
kvm on                    # host services
vm start k8s-cp-01        # control plane first
vm start k8s-worker-01    # worker second
devpod up . --ide none    # workspace

ssh k8s-worker-01 sudo poweroff   # worker first
ssh k8s-cp-01     sudo poweroff   # control plane last
devpod stop k8s-homelab-kvm       # workspace
kvm off                           # host services (frees RAM)
```

---

## Verification checklist

- [ ] `kvm` → all daemons `active`, both networks (`k8s`, `default`) `active`
- [ ] `vm` → both VMs `running` with reserved IPs (`.11`, `.12`)
- [ ] `devpod up . --ide none` → container up, no rebuild
- [ ] `kubectl get nodes` (in workspace) → both `Ready`
- [ ] On stop: `virsh list --all` shows both `shut off` **before** `kvm off`
