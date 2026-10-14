#!/usr/bin/env bash
# ==================================== #
#   k8s-homelab-kvm                    #
#   scripts/10-prepare-nodes.sh        #
#   wasim hassan                       #
# ==================================== #
#
# 10-prepare-nodes.sh — bring every k3s node to a known, uniform baseline.
#
# Responsibilities:
#   1. Update packages so kernels converge (nodes shipped on .137 / .142)
#   2. Persist the kernel modules k3s needs (overlay, br_netfilter, nf_conntrack)
#   3. Persist the sysctl values the kubelet / CNI require
#
# Idempotent: safe to re-run. Steps that are already correct are skipped.
#
# Usage:  ./scripts/10-prepare-nodes.sh
#         ./scripts/10-prepare-nodes.sh --no-upgrade   # skip apt, just modules/sysctl
#
# Exit:   0 = every node prepared, 1 = at least one failure.
#
# NOTE: this does NOT reboot. An upgraded kernel only takes effect after a
# reboot, so the script prints a reminder and exits. Rebooting mid-run would
# make the already-converged state untestable.

set -uo pipefail

APP_NAME="Prepare k3s nodes"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DO_UPGRADE=1
[[ "${1:-}" == "--no-upgrade" ]] && DO_UPGRADE=0

require_cmd ssh
require_cmd python3

MODULES=(overlay br_netfilter nf_conntrack)
MODULES_FILE=/etc/modules-load.d/k8s.conf
SYSCTL_FILE=/etc/sysctl.d/99-kubernetes.conf

heading "$APP_NAME"

# ═══════════════════════════════════════════════════════════════
# STEP 1: PREPARE NODES
# ═══════════════════════════════════════════════════════════════

section "Preparing k3s nodes (upgrade=${DO_UPGRADE})"

while IFS='|' read -r node ip _ role _ _; do
  [[ -z "$node" ]] && continue
  section "$node ($ip) — role=$role"
  assert_passwordless_sudo "$node"

  if ! ssh_node "$node" true 2>/dev/null; then
    error "$node unreachable over SSH"
    continue
  fi
  success "$node reachable"

  # ---- 1. Package + kernel convergence ----
  if [[ $DO_UPGRADE -eq 1 ]]; then
    before=$(ssh_node "$node" 'uname -r')
    info "package upgrade in progress (running kernel: $before)"
    if ssh_root_node "$node" <<'REMOTE'
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || exit 1
apt-get -y -o Dpkg::Options::=--force-confold \
        -o Dpkg::Options::=--force-confdef dist-upgrade -qq || exit 1
exit 0
REMOTE
    then
      success "$node packages upgraded"
    else
      error "$node package upgrade failed — see output above"
    fi
  fi

  # ---- 2. Kernel module persistence ----
  # Write the file only if its contents differ, so re-runs are quiet.
  desired_modules=$(printf '%s\n' "${MODULES[@]}")
  current_modules=$(ssh_node "$node" "cat $MODULES_FILE 2>/dev/null" || true)
  if [[ "$(printf '%s\n' "$current_modules" | sort)" == "$(printf '%s\n' "$desired_modules" | sort)" ]]; then
    success "$node $MODULES_FILE already correct"
  elif write_remote_file "$node" "$MODULES_FILE" "$desired_modules" 2>/dev/null; then
    success "$node wrote $MODULES_FILE"
  else
    error "$node could not write $MODULES_FILE"
  fi

  # Load them now so we don't need a reboot for the modules themselves.
  for mod in "${MODULES[@]}"; do
    ssh_sudo "$node" modprobe "$mod" >/dev/null 2>&1
    if module_present "$node" "$mod"; then
      state=$(ssh_node "$node" "cat /sys/module/$mod/initstate 2>/dev/null || echo builtin")
      success "$node module $mod present ($state)"
    else
      error "$node module $mod not present — is it available? (modinfo $mod)"
    fi
  done

  # ---- 3. sysctl persistence ----
  # These bridge keys only exist once br_netfilter is loaded, which is why
  # the module step above must run first.
  read -r -d '' desired_sysctl <<'EOF'
# Kubernetes networking requirements.
# br_netfilter must be loaded first (handled in /etc/modules-load.d/k8s.conf).
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF

  current_sysctl=$(ssh_node "$node" "cat $SYSCTL_FILE 2>/dev/null" || true)
  if [[ "$current_sysctl" == "$desired_sysctl" ]]; then
    success "$node $SYSCTL_FILE already correct"
  elif write_remote_file "$node" "$SYSCTL_FILE" "$desired_sysctl" 2>/dev/null; then
    success "$node wrote $SYSCTL_FILE"
  else
    error "$node could not write $SYSCTL_FILE"
  fi

  if ssh_sudo "$node" sysctl --system >/dev/null 2>&1; then
    ipf=$(ssh_node "$node" 'sysctl -n net.ipv4.ip_forward')
    bnf=$(ssh_node "$node" 'sysctl -n net.bridge.bridge-nf-call-iptables')
    if [[ "$ipf" == "1" && "$bnf" == "1" ]]; then
      success "$node sysctl applied (ip_forward=$ipf, bridge-nf-call-iptables=$bnf)"
    else
      error "$node sysctl not applied (ip_forward=$ipf, bridge-nf-call-iptables=${bnf:-unset})"
    fi
  else
    error "$node 'sysctl --system' failed"
  fi

  # ---- Pre-report ----
  running=$(ssh_node "$node" 'uname -r')
  newest=$(ssh_node "$node" 'ls /boot/vmlinuz-* 2>/dev/null | sed "s|.*/vmlinuz-||" | sort -V | tail -1')
  if [[ -n "$newest" && "$running" != "$newest" ]]; then
    warn "$node REBOOT REQUIRED — running $running, installed $newest"
  else
    success "$node running kernel is current ($running)"
  fi
done < <(inv_all)

# ═══════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════

section "Result"
summary
_exit_status=$?
complete_msg "$APP_NAME completed"
exit "$_exit_status"
