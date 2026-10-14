# Troubleshooting Log

Chronological record of every real failure encountered while building this
cluster, with root cause, fix, and verification.

Format: symptom → root cause → fix → how to verify → lesson.

---

## 2026-10-02 — `virsh` reported "libvirt not available"

**Symptom:** Every virtualization command failed. `virsh` returned
`libvirt not available`. The host's `kvm` function reported all virtual
services masked.

**Investigation:**
```bash
systemctl is-active virtqemud virtlogd virtnetworkd   # all inactive
ls -l /etc/systemd/system/virtqemud.service
# -> /dev/null
```

**Root cause:** A previous session had left `/etc/systemd/system/virtqemud.service`
as a symlink to `/dev/null`. systemd treats a symlink to `/dev/null` as an
*explicit* mask, which has higher precedence than the vendor preset — so the
daemon refused to start even though the package was correctly installed.

**Fix:** `kvm on`, which removes the masks, enables the socket units, and
restarts the `default` network.

**Verify:**
```bash
virsh version      # libvirt 12.0.0 / QEMU 12.0.0
virsh net-list --all
```

**Lesson:** A package being installed does not mean its service will start.
Check `systemctl is-enabled` / `is-active` before assuming. Masking survives
package reinstalls, which makes it look like a broken install when it isn't.

---

## 2026-10-02 — "A dependency job for virtqemud.service failed"

**Symptom:** During `kvm on`:
```
A dependency job for virtqemud.service failed. See 'journalctl -xe' for details.
```
…followed immediately by `Started virtqemud.service`.

**Investigation:**
```bash
journalctl -u virtqemud.service --no-pager -n 25
```

**Root cause:** A harmless first-boot ordering race. The journal showed
`Dependency failed` at 12:10:00, then `Starting` at 12:10:09 and `Started`
9 seconds later. libvirt's modular daemons have `After=`/`Requires=` chains that
race on a cold start. The service self-recovered.

A related non-issue in the same log: `virtqemud` logged `Deactivated
successfully` after ~2 minutes. That is the daemon's **120-second idle timeout**,
not a crash. It is socket-activated, so the next `virsh` call relaunches it
transparently.

**Fix:** None needed.

**Verify:**
```bash
virsh version      # succeeds, proving socket activation works
systemctl is-active virtqemud
```

**Lesson:** Not every systemd error is fatal. Read the *whole* journal window,
not just the first line — the recovery is usually a few seconds later. And an
"inactive" socket-activated daemon is normal between uses.

---

## 2026-10-02 — VM creation aborted: `Network not found: 'K8s'`

**Symptom:**
```
ERROR    Network not found: no network with matching name 'K8s'
Domain installation does not appear to have been successful.
```

**Root cause:** libvirt network names are **case-sensitive**, exactly like DNS
hostnames. The prompt had displayed `Network name (default: k8s):` and the
operator entered `K8s`. The network is named `k8s` (lowercase only).

```bash
virsh net-list --name
# default
# k8s          <- lowercase
```

**Fix:** Re-ran `vm run ubuntu` with the network entered as lowercase `k8s`.

**Damage assessment:** None. `virt-install` resolves the network *before*
defining the domain, so no half-built VM was created. Only two unused files
remained (a 597 MB qcow2 and a 370 KB seed ISO), both overwritten on retry.
Confirmed no stub domain was left behind:
```bash
virsh dominfo k8s-worker-01     # error: failed to get domain
virsh list --all --name         # only k8s-cp-01
```

**Lesson:** VM names, hostnames, usernames, and network names are all
case-sensitive. When a prompt shows `(default: x)`, pressing Enter is safer
than typing. `virsh net-list --name` is the authority on valid names.

---

## 2026-10-02 — `virsh net-define` refused to update the `k8s` network

**Symptom:**
```
error: Failed to define network from .../libvirt-k8s-net.xml
error: operation failed: network 'k8s' already exists with uuid
       a547ca9d-acb1-486a-9ae3-e5cf44d2b88b
```

**Root cause:** `virsh net-define` **only creates new networks**. Given an XML
file with no `<uuid>`, libvirt generated a fresh UUID and found the name `k8s`
already taken.

**Fix:** Add the network's existing UUID to the XML. A matching UUID signals
"update this network" rather than "create a new one":
```bash
virsh net-uuid k8s   # a547ca9d-acb1-486a-9ae3-e5cf44d2b88b
```

**Lesson:**

| Situation | `net-define` result |
|---|---|
| New network name | ✅ creates |
| Existing name, no `<uuid>` in file | ❌ `already exists with uuid …` |
| Existing name, matching `<uuid>` | ✅ updates in place |

---

## 2026-10-02 — DHCP reservations silently dropped (`macaddr` vs `mac`)

This one took three attempts and is the most instructive failure so far,
because **it failed silently**.

**Symptom:** `net-define` succeeded (exit 0), the network cycled without error,
VMs rebooted — and they still came back on **random** IPs (`.201`, `.164`)
instead of the reserved `.11` / `.12`.

**Investigation:**
```bash
virsh net-dumpxml --inactive k8s | grep host
# <host name='k8s-cp-01' ip='192.168.123.11'/>     <-- macaddr GONE
```

The reservations existed but with **no MAC address**.

**Root cause — two independent bugs stacked:**

1. **`macaddr` is not the attribute name.** libvirt's network XML uses `mac=`
   for DHCP host reservations. An unrecognised attribute is **silently ignored**
   — no error, no warning. `name=` and `ip=` were valid, so they survived, and
   the reservation *looked* plausible.

2. **Verifying the wrong config source.** `net-define` writes the **persistent**
   config only. `virsh net-dumpxml k8s` shows the **runtime** config. After a
   `net-define` with no cycle, the runtime still showed the old definition —
   which made a successful update look like a failed one. The correct check is
   `virsh net-dumpxml --inactive k8s`.

**Proof (isolated reproduction on a throwaway network):**
```bash
# with macaddr=  -> stripped, no error
# with mac=      -> preserved
<host mac='52:54:00:aa:bb:cc' name='testnode' ip='192.168.251.10'/>
```

**Fix:** Use `mac=` in `terraform/libvirt-k8s-net.xml`.

**Verify:**
```bash
virsh net-dumpxml k8s | grep "<host"
# <host mac='52:54:00:17:ef:cf' name='k8s-cp-01' ip='192.168.123.11'/>
# <host mac='52:54:00:96:63:19' name='k8s-worker-01' ip='192.168.123.12'/>

ping -c1 192.168.123.11   # UP
ping -c1 192.168.123.12   # UP
```

**Lesson — the important one:**

> `net-destroy` + `net-start` re-reads the definition **from disk**. It only
> applies your new XML if `net-define` already succeeded. Wrong order means the
> bridge happily cycles and reverts to the old config — **success with no
> effect**, which is far more dangerous than an outright error.

Three habits that would have caught this on attempt one:

1. **Read the man page for the exact attribute name.** `man virsh` documents
   `net-update` with `<host mac='00:11:22:33:44:55' ip='1.2.3.4'/>`.
2. **Verify the attribute you care about survived the write** — grep for the
   *specific* field, not just the element name.
3. **Reproduce on a throwaway object** before touching production state. A
   scratch network cost 10 seconds and proved the root cause definitively.

---

## 2026-10-02 — Unexpected 596 MB cloud image re-download

**Symptom:** VM creation took 6m26s instead of ~1m15s:
```
⚠️  Cached image is outdated or invalid — re-downloading...
```

**Root cause:** Not a failure. The cached `ubuntu-24.04-server-cloudimg-amd64.img`
was dated **2026-08-10**; Canonical had published a current build dated
**2026-09-26**. The provisioner checks image freshness against upstream metadata
and re-pulls when stale. Checksum verification passed on the download.

**Lesson:** Working as designed. Running an outdated cloud image is how you end
up debugging phantom security and kernel bugs months later. Budget ~6 minutes
when the staleness check triggers.

Related non-issue: the first `vm run` reported `❌ No internet connectivity`,
and the second immediately reported `✅ Internet OK`. A transient false negative
in the connectivity probe — the provisioner's offline-cache fallback handled it
correctly.

---

## 2026-10-10 — `kvm off` powers off VMs after only 5 seconds

**Symptom:** `kvm off` reports "Waiting 5 seconds for VMs to shut down", then
immediately disables and **masks** the libvirt daemons.

**Investigation:**
```bash
grep -nE "shutdown|destroy|sleep 5|mask" ~/Sync/Repos/kvm-vm-provisioner/scripts/kvm-toggle.sh
#  32: virsh shutdown "$vm" || virsh destroy "$vm" || true
#  35: sleep 5
#  41: systemctl mask ${svc}.service
```

**Root cause:** The function waits only 5 seconds, then stops `virtqemud`.
libvirt **kills any still-running domain when its daemon stops**, so a VM that
needs longer than 5s to flush becomes an unclean power-off. `virsh destroy` is
also the fallback, and `|| true` hides any failure.

**Damage assessment (this time):** None. Both VMs were idle, so they completed
ACPI shutdown well within the window and both qcow2 images passed `qemu-img
check` afterwards with "No errors were found". The daemon logged `Deactivated
successfully`, i.e. it waited for QEMU to exit rather than cutting it off.

**Correct approach (and required once k3s/etcd is installed):**
```bash
virsh shutdown k8s-cp-01 k8s-worker-01
# wait until BOTH show "shut off" — do not use a fixed sleep
watch -n2 'virsh list --all'
```

**Lesson:** A fixed 5-second sleep is safe for idle VMs and dangerous for busy
ones. etcd writes continuously; killing it mid-write risks a corrupted cluster.
Shut down gracefully and wait for the actual state transition, not a timer.

---

## 2026-10-10 — `10-prepare-nodes.sh`: first run wrote no files

**Symptom:** Module and sysctl files were never created, yet `modprobe`
"appeared" to run. Output showed:
```
bash: line 1: overlay: command not found
bash: line 2: br_netfilter: command not found
✗ could not write /etc/modules-load.d/k8s.conf
```

**Root cause (two bugs, one investigation):**

1. **Streaming a script and piping data to it conflict.** The helper
   `ssh_root_node` runs `ssh … bash -s`, so the **script body arrives on
   stdin**. The script did `printf '%s\n' "$content" | ssh_root_node …`, which
   meant the *file content* (`overlay`, `br_netfilter`, …) was executed as the
   script, and the `tee` command became a never-used positional argument.

2. **`ssh_root_node` requires a heredoc.** Calling it *without* one (e.g.
   `ssh_root_node "$node" modprobe "$mod"`) sends no script at all; `modprobe`
   and the module name become positional args that never execute. The call
   returned exit 0 and looked successful.

**Fix:**
- Added `write_remote_file()` which base64-encodes content and passes it as a
  **positional argument**, so stdin stays free for the script and no content is
  ever re-interpreted by the shell.
- Simple one-shot commands use `ssh_sudo` (which runs `sudo -n <cmd>`), not
  `ssh_root_node`.

**Verify:**
```bash
ssh k8s-cp-01 'cat /etc/modules-load.d/k8s.conf'      # overlay, br_netfilter, nf_conntrack
ssh k8s-cp-01 'lsmod | grep br_netfilter'             # loaded
```

**Lesson:** Exit code 0 is not proof of work. When a helper's contract is
"read the script from stdin", never also pipe data into it. After any remote
write, **read the file back** and check the exact contents.

---

## 2026-10-10 — Only the first node was ever processed

**Symptom:** `10-prepare-nodes.sh` prepared `k8s-cp-01` and then stopped, while
still reporting success. The worker was silently skipped.

**Root cause:** The inventory loop is `while read … done < <(inv_all)`. `ssh`
**reads its own stdin by default and forwards it to the remote command**, so the
first `ssh` call inside the loop consumed the remaining inventory lines. The
loop ended early because its input stream was gone.

**Fix:** Added `-n` to every non-interactive ssh helper (`ssh_node`,
`ssh_sudo`). `-n` redirects stdin from `/dev/null`, so the loop's input is left
alone.

**Verify:** Both nodes appear in the output and the final tally covers both.

**Lesson:** This is the classic "ssh eats the while-read loop" bug. Any `ssh`
invoked inside a `while read < <(...)` loop must be given `-n` (or explicit
`< /dev/null`), unless you actually intend to stream data to it.

---

## 2026-10-10 — k3s install hung downloading the binary from GitHub

**Symptom:** `20-install-k3s-server.sh` produced no output for 10+ minutes and
was killed by timeout. On the node:
```
curl -o /tmp/k3s-install.*/k3s.bin -sfL \
  https://github.com/k3s-io/k3s/releases/download/v1.37.1%2Bk3s1/k3s
```
…stalled at **0 bytes**.

**Investigation:**
```bash
# partial file size, sampled twice
0 bytes … 0 bytes          # no progress
# host download of the same URL
5.2 MB / 20s ≈ 260 KB/s    # slow but working
# guest download
2.7 MB / 45s ≈ 61 KB/s     # ~4x slower; 78 MiB ≈ 20+ min
```

**Root cause:** Not a bug in the scripts — the network path. GitHub release
downloads are throttled/slow from this location, and slower still from inside
the NAT'd VMs. `get.k3s.io` and `archive.ubuntu.com` respond instantly, so only
the large release download is affected. The initial 0-byte stall was the
connection hanging before any data arrived.

**Fix:** Stage the binary on the **host**, verify it, and push it over the local
libvirt bridge (which is not subject to the WAN throttle):

```bash
# lib.sh
k3s_binary_ensure()   # download to ~/.cache/k3s-homelab/, verify vs
                      # sha256sum-amd64.txt from the same release
k3s_binary_push()     # scp to the node, install -m 0755 /usr/local/bin/k3s
# installer runs with INSTALL_K3S_SKIP_DOWNLOAD=true
```

**Verify:**
```bash
sha256sum ~/.cache/k3s-homelab/k3s-v1.37.1+k3s1
# 92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0  (matches release)
```

Bonus: staging once serves **both** nodes, so the slow path runs exactly once
instead of twice. `INSTALL_K3S_SKIP_DOWNLOAD=true` requires the binary to
already exist at `/usr/local/bin/k3s` — the installer calls
`verify_k3s_is_executable` and fails otherwise.

**Lesson:** When an install step "hangs", measure where it hangs before assuming
the tool is broken. Sampling a partial file's size twice instantly distinguishes
*slow* from *stalled*. Caching a verified binary on the host also makes the
whole install faster and reproducible.

---

## 2026-10-10 — Add-ons stuck `ContainerCreating` for ~80 seconds

**Symptom:** Immediately after install, `40-verify.sh` reported coredns,
metrics-server, and local-path-provisioner as `0/1 ContainerCreating`.

**Investigation:**
```bash
kubectl describe pod -n kube-system -l k8s-app=kube-dns | sed -n '/Events:/,$p'
# Pulled … in 1m19.238s (including waiting). Image size: 24261571 bytes.
```

**Root cause:** Not a failure. First-time image pulls on this network are slow
(coredns alone took 79s), and the pods were correctly `Scheduled` throughout.
Once pulled, all add-ons reached `Running`. The readiness probes
(`connection refused` during startup) are expected before the processes bind.

**Fix:** None. Wait and re-run the verification.

**Lesson:** `ContainerCreating` right after install means "pulling images",
not "broken". Check the pod Events for `Pulling`/`Pulled` before suspecting a
scheduler, CNI, or RBAC problem. On a slow link, budget a couple of minutes.

---

## 2026-10-12 — Containerfile build died at the SSH-config step

**Symptom:** `devpod up . --ide none` built fine up to step 16, then:
```
/bin/sh: 1: Syntax error: end of file unexpected (expecting "}")
Error: building at STEP "RUN mkdir -p /home/dev/.ssh /home/dev/.cache && chmod 700 /home/dev/.ssh && { echo 'Host k8s-cp-01 …';"
```

**Root cause:** A `RUN` in the `Containerfile` was written as a shell brace group:
```
RUN … && { echo 'Host …';
      echo '    User ratlab';
      echo … ; } > /home/dev/.ssh/config
```
Every physical line of a `RUN` must end with `\` to continue. The lines inside
`{ … }` did **not**, so the instruction was terminated at the first newline and
`/bin/sh` received an unterminated `{`.

**Fix:** Replaced the brace group with a single continued line using
`printf '%s\n' 'line1' 'line2' … > file`, with each physical line ending in `\`.

**Verify:**
```bash
devpod up . --ide none          # steps proceed past 16
devpod ssh k8s-homelab-kvm --command 'cat /home/dev/.ssh/config'
```

**Lesson:** In a `RUN` line, "a shell construct spanning lines" still needs a
trailing `\` on every physical line. Prefer constructs that are naturally
single-line-ish (`printf '%s\n'`) over multi-line brace groups.

---

## 2026-10-12 — Helm build step: `sha256sum: <tarball>: No such file or directory`

**Symptom:** The Containerfile helm step failed with:
```
sha256sum: helm-v4.3.0-linux-amd64.tar.gz: No such file or directory
```
even though the download step used `&&` and would have failed loudly had the
`curl` failed.

**Investigation:** Reproduced the download+verify **on the host** in
`/tmp/opencode/helmtest` — it worked perfectly:
```
86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb  helm-v4.3.0-linux-amd64.tar.gz
```
The in-container cause was not conclusively pinned down.

**Fix:** Rewrote the step to be **filename-independent**: download to fixed
names `/tmp/helm.tar.gz` and `/tmp/helm.sha256sum`, add `ls -la` of both, then
compare `expected="$(awk '{print $1}' /tmp/helm.sha256sum)"` against
`actual="$(sha256sum /tmp/helm.tar.gz | awk '{print $1}')"`. On re-run the debug
line printed `expected=… actual=…` (identical) and the step passed.

**Verify:**
```bash
devpod ssh k8s-homelab-kvm --command 'helm version --short'   # v4.3.0+gbec5b06
```

**Lesson:** When a checksum step references a version-stamped filename, any
mismatch between the URL's name and the `-o` path blows up as "file not found"
*after* a successful download. Comparing hashes by content (fixed temp names)
removes the filename coupling, and a `ls -la` in the step makes the next
diagnosis trivial.

---

## 2026-10-12 — Workspace could not read the mounted kubeconfig / SSH key

**Symptom:** `postCreateCommand` passed, but inside the container:
```
kubectl … error loading config file "/root/.kube/config": permission denied
ssh … no such identity: /root/.ssh/k8s-homelab-kvm: Permission denied
ls: cannot open directory '/workspaces/k8s-homelab-kvm': Permission denied
```
First attempt ran as `root`; the same failures persisted after switching to
the uid-1000 `dev` user. `Chown workspace…` logged `open
/workspaces/k8s-homelab-kvm: permission denied`.

**Investigation:**
```bash
podman inspect -f '{{json .HostConfig.IDMappings}}' <ctr>
# {"UidMap":["0:1:1000","1000:0:1","1001:1001:64536"], ...}
getenforce            # Enforcing
ls -Zd ~/.kube        # unconfined_u:object_r:user_home_t:s0
```
Two independent blockers:

1. **Rootless Podman uid mapping.** The default map does **not** place the host
   user (uid 1000) at container uid 1000, so neither container `root` nor the
   uid-1000 user was the host user — every host-owned mount read as "other".
2. **SELinux.** On enforcing Fedora the mounted files are `user_home_t`, which
   the container domain cannot read **even once the uid mapping is fixed**.

Proven by isolation (`podman run` against the built image, mounting `~/.kube`):

| Flags | user 1000 reads `~/.kube/config`? |
|---|---|
| none | ❌ |
| `--userns=keep-id` | ❌ |
| `--security-opt=label=disable` | ❌ |
| **`--userns=keep-id` + `--security-opt=label=disable`** | ✅ `apiVersion: v1` |

**Fix:** Added **both** flags to `runArgs`, and ran as the uid-1000 `dev`
user (`containerUser`/`remoteUser`). Mount targets moved from `/root/…` to
`/home/dev/…`.

**Verify:**
```bash
devpod ssh k8s-homelab-kvm --command \
  'id; kubectl get nodes; ssh k8s-cp-01 "sudo -n k3s --version"'
# uid=1000(dev) … both nodes Ready … k3s v1.37.1+k3s1
```

**Lesson:** A bind mount that "should" be readable can be blocked by **two**
layers at once — the user-namespace id mapping *and* SELinux. Fix them
together; testing them one at a time looks like neither works. Debugging the
mapping inside the running container (`IDMappings`, `ls -ldZ`) is faster than
reasoning about it.

---

## 2026-10-12 — Workspace migrated to a FOSS base image and `dev` user

**Symptom:** Not a crash — a policy violation. The working workspace relied on
`mcr.microsoft.com/devcontainers/base:ubuntu-24.04` (Microsoft image, built-in
`vscode` user) and a `Dockerfile`, which conflicts with the FOSS-only,
no-vendor-lock requirement.

**Root cause:** Inherited defaults from the reference setup, not a defect.

**Fix:** Drop-in replacements, then recreate:
- base `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` → `quay.io/fedora/fedora:44`
- user `vscode` → `dev` (uid/gid 1000; `keep-id` needs uid 1000)
- `Dockerfile` → `Containerfile`; `devcontainer.json` `"dockerfile": "Containerfile"`
- `containerUser`/`remoteUser: "dev"`; mount targets `/home/vscode/…` → `/home/dev/…`
- `k9s`: tarball → Fedora `.rpm` (`k9s_linux_amd64.rpm`), dnf-installed,
  verified against the release `checksums.sha256`
- add `kitty-terminfo` (see the next entry)

> Spec names stay: `.devcontainer/devcontainer.json` and the `"dockerfile"` key
> come from the open `containers.dev` standard, and Devpod's provider id is
> `docker` — renaming them breaks auto-detection. They are not the Docker/VS Code
> apps.

**Verify:**
```bash
devpod up . --ide none --recreate
devpod ssh k8s-homelab-kvm --command 'cat /etc/fedora-release | head -1; id'
```
→ `Fedora Linux 44 (Container Image)`, `uid=1000(dev)`, all tools present, both
nodes `Ready`.

**Lesson:** The base image and the container user are part of the contract with
`runArgs`/`mounts`; changing the uid means moving every mount target and
re-testing ACLs. FOSS-only is satisfiable here because the *spec* filenames are
fixed by an open standard, while the *contents* (base, user, build-file name) are
ours to choose.

---

## 2026-10-12 — `k9s` exited immediately inside the workspace

**Symptom:** `k9s` returned instantly over `devpod ssh` (kitty). A PTY test
surfaced:
```
Error: could not create any of the following paths: [/home/dev/.config/k9s /etc/xdg/k9s]
```

**Investigation:** Two independent causes:
```bash
echo $TERM                 # xterm-kitty
infocmp xterm-kitty        # failed — no terminfo entry → tcell aborts
ls -ld /home/dev/.config   # drwxr-xr-x root root  (not writable by dev)
```
`/home/dev/.config` was created **root-owned** because Podman materializes the
parent directory of the `~/.config/nvim` bind mount. Separately, the Fedora base
has no `script(1)`, so the automated PTY test used Python instead:
`python3 -c 'import pty; pty.spawn(["k9s"])'` under `timeout`.

**Fix:**
- install `kitty-terminfo` in the `Containerfile`
- pre-create `/home/dev/.config` (dev-owned) in the image *before* the nvim mount
- `devpod up . --ide none --recreate`

**Verify:**
```bash
devpod ssh k8s-homelab-kvm --command \
  'TERM=xterm-kitty timeout 5 python3 -c "import pty; pty.spawn([\"k9s\"])"; echo exit=$?'
# exit=124  (k9s stayed running = TUI started)
devpod ssh k8s-homelab-kvm --command 'ls -ld /home/dev/.config'
# drwxr-xr-x … dev dev … /home/dev/.config
```

**Lesson:** A TUI needs **both** a matching terminfo entry (`TERM`) **and** a
writable config directory. Bind-mounting a subdirectory can hand the parent to
root; pre-create and own parents in the image. And on a headless/kitty setup,
test TUI programs under a PTY — a plain `--command` has no TTY.

---

## 2026-10-13 — Workspace shows `Exited (0)` / `pd ps` empty after a host reboot

**Symptom:** The morning after a full host shutdown, `podman ps -a` showed the
workspace container as `Exited (0)`, and `podman ps` (running only) returned
nothing. It looked like the workspace had failed to come back:
```
CONTAINER ID  IMAGE                              STATUS                 NAMES
620bed9fb762  localhost/vsc-k8s-homelab-kvm...   Exited (0) 21 hours ago  charming_lalande
```

**Root cause:** Not a failure. `devpod stop` (or a host reboot) leaves the
container **stopped**, and rootless Podman containers **do not auto-start** after
a reboot. `Exited (0)` is a clean exit. The image
(`localhost/vsc-k8s-homelab-kvm-*:devpod-*`) is intact, so resuming is fast and
rebuilds nothing.

**Fix:** Start it through Devpod — *not* raw `podman start`, which leaves
Devpod's lifecycle state out of sync:

```bash
cd ~/Sync/Repos/k8s-homelab-kvm
devpod up . --ide none
devpod ssh k8s-homelab-kvm --command 'kubectl get nodes'
```

**Verify:** `kubectl get nodes` → both nodes `Ready`.

**Lesson:** `Exited (0)` + empty `podman ps` after a reboot is the **normal
stopped state**, not a breakage. Resume with `devpod up`. The full session start
order is `kvm on` → `vm start k8s-cp-01` (wait `Ready`) → `vm start
k8s-worker-01` → `devpod up` — see [runbook 03](runbooks/03-session-lifecycle.md).

---

## 2026-10-13 — k9s rejected `portForwardAddress` in the per-context config

**Symptom:** After adding the repo-hosted k9s config, `k9s info` reported the
per-context file as invalid and emitted a config warning for
`clusters/default/default/config.yaml`. The offending key was
`portForwardAddress`.

**Root cause:** `k9s` (v0.51.0) decodes its config **strictly**, and
`portForwardAddress` is **not** a valid field for the *per-context* config in
that version. The key was written in the wrong place/schema, so decoding failed.

**Fix:** Removed `portForwardAddress` from
`config/k9s/clusters/default/default/config.yaml`. The config then validated
with **zero warnings**.

**Verify:**
```bash
k9s info                      # no config warnings; reads Config/Hotkeys/Skins
kubectl -n kube-system get pods   # TUI still lands on all-namespace pods
```

**Lesson:** k9s validates its YAML against the running binary's schema — a key
that looks reasonable but is misplaced (or renamed between versions) fails
loudly. **Pin knobs to the installed version** and read back `k9s info` after any
config edit. When a field is rejected, check the schema for *that version*
rather than assuming the option name is universal.

---

## Quick reference — daily commands

```bash
kvm                     # daemon + VM + network status
kvm on                  # start daemons, restart default network, open virt-manager
kvm off                 # shut down VMs and stop daemons (frees RAM)
vm                      # list VMs
vm run ubuntu           # create a VM (prompts for everything)

virsh list --all
virsh domifaddr k8s-cp-01
virsh dumpxml k8s-cp-01 | grep '<cpu'
virsh net-list --all
virsh net-dumpxml k8s
virsh net-dumpxml --inactive k8s     # persistent config, not runtime

ssh k8s-cp-01           # by alias, no -i needed
ssh k8s-worker-01
```

### Cluster scripts (run from repo root)

> `20-…`, `30-…` and `40-verify.sh` need `kubectl` → run them **inside the
> workspace** (`devpod ssh k8s-homelab-kvm`). `preflight.sh` and
> `10-prepare-nodes.sh` run on the host.

```bash
./scripts/preflight.sh              # substrate: host + VMs + network + ssh (21 checks)
./scripts/10-prepare-nodes.sh       # converge kernels, persist modules + sysctl
./scripts/20-install-k3s-server.sh  # control plane + kubeconfig
./scripts/30-join-worker.sh         # join workers
./scripts/40-verify.sh              # cluster health end to end
```

### Devpod workspace (run from repo root)

```bash
devpod up . --ide none              # build + start the workspace
devpod ssh k8s-homelab-kvm          # enter (alias: ssh k8s-homelab-kvm.devpod)
devpod list                         # show workspaces
devpod stop  k8s-homelab-kvm        # stop, keep
devpod up . --ide none              # resume
devpod up . --ide none --recreate   # apply runArgs/mount changes
devpod delete k8s-homelab-kvm       # destroy the container
```

### Cluster commands

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get pods -n kube-system
kubectl describe node k8s-worker-01 | sed -n '/Conditions/,/Events/p'
kubectl logs -n kube-system -l k8s-app=kube-dns

ssh k8s-cp-01   'sudo journalctl -u k3s -n 80 --no-pager'
ssh k8s-worker-01 'sudo journalctl -u k3s-agent -n 80 --no-pager'

# quick DNS test from a throwaway pod
kubectl run dns --rm -it --image=busybox:1.36.1 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

## Anti-patterns

| Don't | Do instead |
|---|---|
| `vm destroy <vm>` — **wipes the disk** | `vm stop <vm>` / `virsh shutdown` |
| Assume `kvm off` is safe while writing | Check `virsh list --all` first |
| Type network names by hand | Press Enter for defaults, or check `virsh net-list --name` |
| Verify with `net-dumpxml` after `net-define` | Use `net-dumpxml --inactive` |
| Copy a libvirt XML attribute from memory | `man virsh`, then grep the written config for that exact field |
| Trust an exit code of 0 as proof a remote write happened | Read the file back and check its exact contents |
| Run `ssh` inside a `while read < <(...)` loop without `-n` | Add `-n` so ssh does not eat the loop's stdin |
| Let the VMs download large binaries from GitHub | Stage + checksum on the host, push over the bridge |
| Put an un-escaped multi-line `{ … }` block in a `RUN` line | End every physical line with `\`, or use `printf '%s\n'` |
| Mount host creds into a rootless-Podman container without `keep-id` | Add `--userns=keep-id` **and** `--security-opt=label=disable` |
| Run `kubectl`-dependent scripts on the bare host | Run them inside the workspace |

---

## 2026-10-14 — Flux: `HelmRelease` rejected (`duplicate upgrade key`)

- **Symptom:** `kustomize build failed` for Kustomization `infrastructure` after
  adding the Envoy Gateway manifests (revision `main@sha1:8c55a7a`). Event:
  `line 18: mapping key "upgrade" already defined at line 12`.
- **Root cause:** `infrastructure/envoy-gateway/helmrelease.yaml` contained two
  `upgrade:` blocks (duplicate YAML key).
- **Fix:** Removed the first `upgrade:` block; consolidated into a single
  `upgrade:` (`strategy: RetryOnFailure` + `crds: CreateReplace` /
  `cleanupOnFail`). Commit `4619659`; `flux reconcile kustomization infrastructure
  -n flux-system`.
- **Verify:** `flux get kustomization infrastructure` → `Ready=True` at
  `main@sha1:46196596`.
- **Lesson:** Duplicate YAML keys slip in during manual edits and kustomize/Helm
  is strict. Run `kustomize build` (or `flux build`) locally before committing.

## 2026-10-14 — Post-reboot churn (`subnet.env`, CoreDNS, DNS lookups)

- **Symptom:** After a VM reboot: `failed to load flannel 'subnet.env'`,
  CoreDNS/metrics-server readiness probes failing, and Flux
  `GitOperationFailed` with DNS lookups to `10.43.0.10:53`.
- **Root cause:** CNI (Flannel) init and CoreDNS/kube-proxy startup churn right
  after the nodes came up; cluster DNS was briefly unavailable.
- **Fix:** None needed — self-healed within minutes as pods restarted.
- **Verify:** `kubectl get pods -A` and `flux get kustomizations -A` all Ready;
  both nodes Ready.
- **Lesson:** Expect brief post-reboot churn on a small cluster. Wait and
  re-check before force-restarting controllers.

## 2026-10-15 — HelmRelease rejected (`spec.upgrade.remediation.retryInterval` not in schema)

- **Symptom:** Kustomization `infrastructure` went `Ready=False` at the
  monitoring commit: `HelmRelease/monitoring/kube-prometheus-stack dry-run
  failed: ... .spec.upgrade.remediation.retryInterval: field not declared in
  schema`.
- **Root cause:** I put the upgrade retry strategy under
  `spec.upgrade.remediation`. In `helm.toolkit.fluxcd.io/v2` the retry strategy
  is a **separate top-level field**, `spec.upgrade.strategy` (`{name,
  retryInterval}`); `spec.upgrade.remediation` only holds
  `retries`/`strategy`/`remediateLastFailure`/`ignoreTestFailures`.
- **Fix:** Moved it to `spec.upgrade.strategy: {name: RetryOnFailure,
  retryInterval: 5m}` (same shape as the working Envoy Gateway HelmRelease).
  Commit `1f79895`.
- **Verify:** `flux get kustomization infrastructure` → `Ready=True`;
  `flux get helmreleases -A` → `kube-prometheus-stack` Ready.
- **Lesson:** When in doubt, read the CRD: `kubectl get crd
  helmreleases.helm.toolkit.fluxcd.io -o json` and inspect
  `...spec.properties.upgrade.properties`. And a **server-side dry run**
  (`kubectl apply --dry-run=server`) catches schema errors before pushing.

## 2026-10-15 — `flux reconcile ... --with-source` looks like it hangs

- **Symptom:** A single `flux reconcile kustomization infrastructure
  --with-source` call produced no output and exceeded a 180s timeout.
- **Root cause:** Not a hang — `flux reconcile` **blocks until the
  reconciliation finishes**, and installing `kube-prometheus-stack` (pulling the
  chart + CRDs + waiting for pods) takes several minutes.
- **Fix:** Instead of one blocking call, reconcile then **poll**:
  `for i in $(seq 1 20); do flux get kustomization infrastructure -n flux-system;
  sleep 15; done`.
- **Verify:** Kustomization reaches `Ready=True` at the pushed revision;
  `kubectl -n monitoring get pods` shows all Running.
- **Lesson:** `flux reconcile` waits; for slow Helm installs, poll status rather
  than wrapping the reconcile in a short timeout.

## 2026-10-15 — Grafana OOMKilled → Envoy "upstream connect error" on the Dashboards page

- **Symptom:** Opening Grafana's **Dashboards** section returned
  `upstream connect error or disconnect/reset before headers (reset reason:
  remote connection failure)` and scattered "error loading" messages.
- **Investigation:**
  ```bash
  kubectl -n monitoring describe pod -l app.kubernetes.io/name=grafana
  # Last State: Terminated, Reason: OOMKilled, Exit Code: 137
  kubectl -n monitoring top pod -l app.kubernetes.io/name=grafana --containers
  # grafana 250Mi  (limit was 256Mi)  → pinned at the cap
  kubectl -n monitoring logs -l app.kubernetes.io/name=grafana -c grafana | grep bleve
  # logger=bleve-backend ... resource=dashboards reason=getStats "Building index using memory"
  ```
- **Root cause:** Grafana 13 builds an **in-memory search index** (bleve) over
  all provisioned dashboards. Loading the dashboard list spiked memory past the
  `256Mi` limit → the container was OOMKilled (exit 137) → Envoy had no healthy
  backend and returned the 5xx. (Restart count was 2; `kubectl top pod` showed
  398Mi because that number is the **pod total**: grafana 250Mi + two sidecars
  ~76Mi each.)
- **Fix:** Raised Grafana to `requests 256Mi` / `limits 512Mi` and bounded the
  dashboard/datasource sidecars via `grafana.sidecar.resources`
  (`64Mi`/`128Mi`). Commit `9550bb4` — values in
  `infrastructure/monitoring/helmrelease.yaml`.
- **Verify:**
  ```bash
  kubectl -n monitoring top pod -l app.kubernetes.io/name=grafana --containers
  # grafana ~317Mi (< 512Mi), restartCount 0
  curl -s -H 'Host: grafana.local' http://192.168.123.11/api/health   # {"database":"ok",...}
  ```
- **Lesson:** On a small cluster it is tempting to set memory limits very low;
  Grafana 13 is not as light as older versions (its new dashboard search indexes
  in memory). `kubectl top pod` without `--containers` reports the **pod total**,
  which can hide which container is actually at its ceiling — always add
  `--containers` when chasing OOMKills.
- **Confirmed fixed (2026-10-15):** after the HelmRelease reconciled, the
  Dashboards page renders data for all dashboards; Grafana `restartCount` stayed
  `0` and memory settled at **~317Mi/512Mi**. Note that a Grafana rollout
  invalidates existing browser sessions, so you are prompted to log in again —
  the stored credentials are unchanged.

## 2026-10-15 — etcd / scheduler / controller-manager dashboards show "No data"

- **Symptom:** In Grafana, the **etcd** dashboard (and likely scheduler /
  controller-manager / proxy) showed `No data` on every panel.
- **Root cause:** k3s uses a **SQLite datastore by default** and embeds the
  control-plane components inside the `k3s server`/`agent` processes, so there is
  no etcd and no exposed scheduler/controller-manager/kube-proxy metrics
  endpoint. `kube-prometheus-stack` still ships ServiceMonitors + dashboards for
  them, but their ServiceMonitors select **no endpoints**, so the panels have
  nothing to query. (Confirmed: neither `/etc/etcd` nor a datastore flag exists,
  and the Prometheus `job` list had no `kube-etcd`/`kube-scheduler`/etc.)
- **Fix:** Disabled the irrelevant components in the HelmRelease values
  (`kubeEtcd`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` →
  `enabled: false`). The chart gates both the ServiceMonitors **and** the
  dashboards on these flags, so this removed 4 ServiceMonitors (12→8) and 4
  dashboards (28→24).
- **Verify:**
  ```bash
  kubectl -n monitoring get servicemonitors            # 8, none etcd/scheduler/cm/proxy
  kubectl -n monitoring get cm -l grafana_dashboard=1  # 24
  curl -s -u admin:<pw> -H 'Host: grafana.local' \
    'http://192.168.123.11/api/search?type=dash-db'    # no etcd/scheduler/cm/proxy
  ```
- **Lesson:** Match a monitoring stack to what the distribution actually runs.
  k3s is not upstream Kubernetes — control-plane components are internal, so
  their stock dashboards are dead weight. Turning off the components keeps the
  Prometheus target list honest.

## 2026-10-15 — FluxInstance aborted the whole Flux Operator install (`no matches for kind "FluxInstance"`)

- **Symptom:** After committing the Flux Operator (OCIRepository + HelmRelease)
  **and** a `FluxInstance` in the same directory, the `infrastructure`
  Kustomization went `Ready=False`:
  ```
  FluxInstance/flux-system/flux dry-run failed: no matches for kind "FluxInstance"
  in version "fluxcd.controlplane.io/v1"
  ```
  The OCIRepository and HelmRelease were **never created** — the operator never
  installed, so the Web UI never came up.
- **Investigation:**
  ```bash
  devpod ssh k8s-homelab-kvm --command 'flux get kustomizations -A'
  # infrastructure: FluxInstance/flux-system/flux dry-run failed: no matches for kind "FluxInstance" ...
  devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get ocirepository,helmrelease'
  # NotFound  ← nothing applied, not even the operator HelmRelease
  ```
- **Root cause:** `kustomize-controller` performs a **server-side dry run of the
  entire resource set before applying any of it**. The `FluxInstance` CRD is
  installed by the Flux Operator (which the HelmRelease installs), so at apply
  time the kind does not exist → the dry run fails → **the whole batch is
  skipped**, including the very HelmRelease that would have created the CRD. A
  chicken-and-egg deadlock.
- **Fix:** Split the `FluxInstance` into its own Kustomization
  (`clusters/k8s-homelab/flux-instance.yaml`) with `dependsOn: [infrastructure]`,
  so the operator (and its CRDs) exist before the FluxInstance is applied.
  Commits `0b94a97` (split) + `4271ca6` (retire old bootstrap).
- **Verify:**
  ```bash
  devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get fluxinstance'
  # flux   True   Reconciliation finished ...   v2.9.6@sha256:...
  devpod ssh k8s-homelab-kvm --command 'flux get kustomizations -A'   # all Ready
  ```
- **Lesson:** A Flux Kustomization applies **atomically at dry-run**: one
  un-creatable resource (a CR whose CRD is installed by another resource in the
  same batch) blocks **everything**. Install CRD-providing controllers in one
  Kustomization and the CRs they enable in a separate Kustomization that
  `dependsOn` it.

## 2026-10-15 — Deleting the repo-managed Flux did *not* prune the Flux CRDs (prune disabled)

- **Context:** Migrating Flux to the operator meant deleting the bootstrap dir
  `clusters/k8s-homelab/flux-system/` (which held `gotk-components.yaml` — the Flux
  CRDs + controllers) from git. The `flux-system` Kustomization's **inventory**
  still listed all those objects, so removing them looked like it would **prune
  the Flux CRDs → cascade-delete every Flux CR**.
- **Investigation:**
  ```bash
  devpod ssh k8s-homelab-kvm --command 'kubectl -n flux-system get kustomization flux-system \
    -o jsonpath="{.status.inventory.entries[*].id}"'
  # ... includes _gitrepositories.source.toolkit.fluxcd.io_apiextensions.k8s.io_CustomResourceDefinition
  devpod ssh k8s-homelab-kvm --command 'kubectl get crd gitrepositories.source.toolkit.fluxcd.io \
    -o jsonpath="{.metadata.annotations}"'
  # kustomize.toolkit.fluxcd.io/prune: Disabled ; kustomize.toolkit.fluxcd.io/ssa: Ignore
  ```
- **Root cause / resolution:** Once the operator adopts Flux, it annotates
  **every** object it manages with `kustomize.toolkit.fluxcd.io/prune: Disabled`
  (and `ssa: Ignore`). kustomize-controller **skips pruning** any object carrying
  that annotation, so deleting the bootstrap dir is safe — the CRDs and
  controllers survive. Confirmed: after removal + reconcile the controllers kept
  their original `AGE` (no restarts) and `kubectl get crd | grep -c fluxcd`
  stayed 15.
- **Lesson:** Flux prune honours `kustomize.toolkit.fluxcd.io/prune: Disabled`.
  Before deleting objects out of a pruned Kustomization, check the inventory
  **and** the objects' annotations — a manager that marks its objects
  `prune: Disabled` will not lose them.

