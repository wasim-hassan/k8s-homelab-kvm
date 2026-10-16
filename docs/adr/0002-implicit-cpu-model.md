# ADR-0002: VM CPU model comes implicitly from `--osinfo`

- **Status:** Accepted
- **Date:** 2026-10-02
- **Deciders:** wasim (with AI assistant review)

## Context

This cluster's VMs are created by an **external** tool,
`~/Sync/Repos/kvm-vm-provisioner`, through the host's `vm` Bash function. That
repo is not modified by this project.

Its `scripts/vm-creator.sh` invokes `virt-install` and **never sets a CPU
model**. A naive reading concludes that libvirt therefore applies its default,
`qemu64` — a minimal, roughly 2006-era Nehalem baseline. That would be a problem
for two reasons:

1. **Talos Linux** (considered for a later phase) refuses to boot below
   x86-64-v2, halting at:

   ```text
   [talos] [initramfs] microarchitecture level 2 or higher is required, halting
   ```

2. **Lost crypto acceleration.** containerd, etcd, kube-apiserver, and
   FluxCD are TLS-heavy. Without hardware AES-NI the host burns CPU on software
   AES for every connection.

## Investigation

An initial assessment concluded the VMs *were* on `qemu64`. That was **wrong**.
Empirical testing corrected it:

```bash
virt-install --dry-run --print-xml ... --osinfo ubuntu24.04 | grep '<cpu'
# <cpu mode="host-passthrough"/>
```

Tested across every OS type the provisioner supports — `ubuntu24.04`,
`almalinux9`, `almalinux8` — all emit `host-passthrough`. The control case, with
`--osinfo` omitted entirely, emits **no** `<cpu>` element at all.

Live confirmation on a created node:

```text
$ virsh dumpxml k8s-cp-01 | grep '<cpu'
  <cpu mode='host-passthrough' check='none' migratable='on'/>
```

Host CPU capability (relevant, since passthrough exposes the host's real set):

| Level | Required features | Ryzen 5 5600H (Zen 3) |
|---|---|---|
| x86-64-v2 | SSE3, SSSE3, SSE4.1/4.2, POPCNT, CX16 | ✅ present |
| x86-64-v3 | + AVX, AVX2, BMI1/2, FMA, MOVBE | ✅ present |
| crypto | AES-NI, PCLMULQDQ, SHA-NI, ERMS, RDPID | ✅ present |

The host supports **x86-64-v3**, comfortably above the v2 floor.

## Decision

**Do not modify `vm-creator.sh`.** No explicit `--cpu` flag is added.

Instead, record the mechanism and a verification step, because the correct
behaviour is **implicit and therefore fragile**.

## Rationale

1. The provisioner already produces the correct result. Adding `--cpu
   host-passthrough` would be a redundant edit to an external repo, for no gain.
2. Explicitly stating what is already correct obscures *why* it is correct. The
   dependency on `--osinfo` is the thing that must not be lost.
3. A documented verification command catches the regression in seconds, whereas
   an uncommented flag in someone else's repo would go unnoticed.

## Consequences

**Positive**

- Zero changes to external tooling.
- VMs get the host's real instruction set, including hardware AES-NI.
- Talos remains viable for a future phase.

**Negative — accepted risk**

- **Hidden dependency.** The correct CPU model exists only as a side effect of
  `--osinfo ubuntu24.04`. If that flag is ever removed from `vm-creator.sh`, VMs
  silently regress to `qemu64` and lose AES-NI, AVX2, and BMI2. This will not
  raise any error.
- **No host portability.** `host-passthrough` ties VM definition to this CPU. A
  VM disk moved to a machine with a different CPU may not boot. Irrelevant for a
  single-host homelab; would matter if these disks were ever restored elsewhere.

## Verification

Run after any change to the provisioner, or when creating new nodes:

```bash
virsh dumpxml k8s-cp-01 | grep '<cpu'
```

- ✅ `<cpu mode='host-passthrough' .../>` — correct
- ❌ `<model fallback='allow'>qemu64</model>` — **regressed**; set the flag
  explicitly via `--cpu host-passthrough` or restore `--osinfo`

## Revisit when

- The provisioner drops `--osinfo` (then set `--cpu host-passthrough` explicitly).
- Talos or any other OS with a hard microarchitecture floor is introduced.
- These disks ever need to be portable to a different host CPU.
