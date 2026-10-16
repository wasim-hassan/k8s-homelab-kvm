# ADR-0001: Use TLP exclusively for power management

- **Status:** Accepted
- **Date:** 2026-10-02
- **Deciders:** wasim (with AI assistant review)

## Context

The host is a Fedora 44 laptop (AMD Ryzen 5 5600H) that must also run two KVM
virtual machines. Power management was a live question during initial setup:
`vm-creator.sh`'s own install path suggested enabling `tuned`, but the operator
already uses **TLP** and does not want `tuned` in the stack at all.

Verified host state:

| Item | Value |
|---|---|
| `tlp` / `tlp-rdw` | 1.10.2 installed, `tlp.service` active |
| `tuned` | **not installed** |
| scaling driver | `amd-pstate` (passive mode) |
| governor | `schedutil` |
| `/etc/tlp.conf` | entirely defaults |

## Decision

Use **TLP only**. Do not install `tuned`.

## Rationale

1. **They conflict.** `tuned-adm` and TLP both manage the CPU scaling governor,
   frequency policy, and disk/power settings. Running both produces
   nondeterministic behaviour where whichever ran last wins — the worst outcome,
   because the effective policy becomes unclear.

2. **TLP is the better fit for this hardware.** TLP's default configuration for
   *passive* `amd-pstate` is exactly the pairing already active here. `tuned`'s
   `throughput-performance`/`balanced-performance` profiles were designed for
   servers, not a laptop that also has to be power-efficient when idle.

3. **Zero drift.** No `tuned-adm` calls to undo, no profiles to reconcile, no
   second tool to reason about when something misbehaves.

## Consequences

**Positive**

- One power-management tool. Behaviour is explainable from `/etc/tlp.conf` alone.
- Nothing to uninstall or reconcile later.
- Current defaults are already correct — no configuration work required.

**Negative**

- `tuned-adm` will not be available for per-profile tuning. If a future phase
  needs something TLP does not expose, the choice must be revisited explicitly
  rather than just installing `tuned`.

**Neutral**

- TLP's `RUNTIME_PM` aggressive power management can occasionally stall vCPU
  threads under nested virtualization. This has **not** been observed. The
  setting should be left at its default unless a real performance problem
  appears — do not pre-emptively change it.

## Verification

```bash
rpm -q tlp tlp-rdw
systemctl is-active tlp.service
rpm -q tuned          # must report "package tuned is not installed"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver   # amd-pstate
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor # schedutil
```

## Revisit when

- A VM workload demonstrates vCPU stalls traceable to runtime PM.
- A future phase requires a power profile TLP cannot express.
