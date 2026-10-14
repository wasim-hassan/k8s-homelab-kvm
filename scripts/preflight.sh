#!/usr/bin/env bash
# ==================================== #
#   k8s-homelab-kvm                    #
#   scripts/preflight.sh               #
#   wasim hassan                       #
# ==================================== #
#
# preflight.sh — verify the virtualization substrate before touching it.
#
# Every check here corresponds to a failure that actually occurred while
# building this cluster. See docs/troubleshooting-log.md.
#
# Usage:  ./scripts/preflight.sh          # report everything
#         ./scripts/preflight.sh --quiet  # only print problems
#
# Exit:   0 = all good, 1 = one or more problems found.

set -uo pipefail

APP_NAME="Preflight"

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

PASS=0
FAIL=0

success()   { ((PASS++)); [[ $QUIET -eq 1 ]] || printf '  \033[32m✓\033[0m %s\n' "$1"; }
error()     { ((FAIL++)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn()      { printf '  \033[33m!\033[0m %s\n' "$1"; }

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
heading() { printf '\n\033[1m==== %s ====\033[0m\n' "$1"; }
complete_msg() { printf '\n\033[32m%s\033[0m\n' "$1"; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET_NAME="k8s"
NET_XML="$REPO_DIR/terraform/libvirt-k8s-net.xml"
NODES=(k8s-cp-01 k8s-worker-01)

# IP assignments must mirror terraform/libvirt-k8s-net.xml
declare -A EXPECTED_IP=(
  [k8s-cp-01]="192.168.123.11"
  [k8s-worker-01]="192.168.123.12"
)

heading "$APP_NAME"

# ═══════════════════════════════════════════════════════════════
# STEP 1: HOST PREREQUISITES
# ═══════════════════════════════════════════════════════════════

section "Host prerequisites"
if [[ -e /dev/kvm ]]; then
  success "/dev/kvm present (hardware virtualization)"
else
  error "/dev/kvm missing — hardware virtualization unavailable"
fi

if systemctl is-active --quiet tlp.service; then
  success "tlp.service active"
else
  warn "tlp.service not active"
fi

if rpm -q tuned >/dev/null 2>&1; then
  warn "tuned is installed — it conflicts with TLP. See docs/adr/0001-tlp-over-tuned.md"
else
  success "tuned absent (TLP-only, as decided in ADR-0001)"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 2: LIBVIRT
# ═══════════════════════════════════════════════════════════════

section "libvirt"
if virsh version >/dev/null 2>&1; then
  success "libvirt reachable ($(virsh version 2>/dev/null | awk '/Using library/{print $4}'))"
else
  error "libvirt not reachable — run 'kvm on' first"
  printf '\nCannot continue without libvirt.\n'
  exit 1
fi

if [[ -L /etc/systemd/system/virtqemud.service ]]; then
  error "virtqemud.service is masked (/dev/null symlink) — run 'kvm on'"
else
  success "virtqemud.service not masked"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: NETWORK
# ═══════════════════════════════════════════════════════════════

section "Network: $NET_NAME"
if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
  success "network '$NET_NAME' exists"

  state=$(virsh net-list --all | awk -v n="$NET_NAME" '$1==n{print $2}')
  if [[ "$state" == "active" ]]; then
    success "network '$NET_NAME' active"
  else
    error "network '$NET_NAME' is '$state' — start with: virsh net-start $NET_NAME"
  fi

  # Reservations must carry a MAC. A macaddr-less <host> silently matches nothing.
  hosts_total=$(virsh net-dumpxml "$NET_NAME" | grep -c "<host " || true)
  hosts_mac=$(virsh net-dumpxml "$NET_NAME" | grep -c "<host mac=" || true)
  if [[ "$hosts_total" -gt 0 && "$hosts_total" -eq "$hosts_mac" ]]; then
    success "all $hosts_total DHCP reservation(s) have a MAC attribute"
  elif [[ "$hosts_total" -gt 0 ]]; then
    error "$((hosts_total - hosts_mac)) of $hosts_total DHCP reservation(s) missing mac=
     → libvirt silently drops a 'macaddr=' attribute. Must be 'mac='.
       Fix terraform/$NET_NAME-net.xml, then:
         virsh net-define terraform/$NET_NAME-net.xml
         virsh net-destroy $NET_NAME && virsh net-start $NET_NAME"
  else
    warn "no DHCP reservations found — node IPs will change on reboot"
  fi

  # The repo XML must stay in sync with what libvirt is actually serving.
  if [[ -f "$NET_XML" ]]; then
    if grep -q "macaddr=" "$NET_XML"; then
      error "$NET_XML uses 'macaddr=' — libvirt will silently ignore it. Use 'mac='."
    else
      success "repo XML uses the correct 'mac=' attribute"
    fi
  fi
else
  error "network '$NET_NAME' does not exist — define it first:
       virsh net-define $NET_XML
       virsh net-start $NET_NAME
       virsh net-autostart $NET_NAME"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 4: VMs
# ═══════════════════════════════════════════════════════════════

section "VMs"
for node in "${NODES[@]}"; do
  if ! virsh dominfo "$node" >/dev/null 2>&1; then
    error "$node does not exist — create with: vm run ubuntu"
    continue
  fi

  dom_state=$(virsh dominfo "$node" | awk '/^State:/{print $2}')
  if [[ "$dom_state" == "running" ]]; then
    success "$node running"
  else
    error "$node is '$dom_state' — start with: virsh start $node"
  fi

  # CPU model must stay host-passthrough. It is set implicitly by --osinfo in
  # the external provisioner; nothing here enforces it. See ADR-0002.
  cpu=$(virsh dumpxml "$node" | grep -o "<cpu mode='[^']*'" | head -1 | cut -d"'" -f2)
  if [[ "$cpu" == "host-passthrough" ]]; then
    success "$node CPU = host-passthrough"
  else
    error "$node CPU = '${cpu:-qemu64 (implicit)}' — expected host-passthrough
     → --osinfo was likely dropped in vm-creator.sh. See docs/adr/0002-implicit-cpu-model.md"
  fi

  want="${EXPECTED_IP[$node]}"
  if [[ -n "$want" ]]; then
    got=$(virsh domifaddr "$node" --source lease 2>/dev/null | awk 'NR>2{print $4}' | cut -d/ -f1)
    if [[ -z "$got" ]]; then
      got=$(virsh domifaddr "$node" 2>/dev/null | awk 'NR>2{print $4}' | cut -d/ -f1)
    fi
    if [[ "$got" == "$want" ]]; then
      success "$node has reserved IP $got"
    elif [[ -z "$got" ]]; then
      warn "$node has no DHCP lease yet (may still be booting)"
    else
      error "$node has IP $got, expected reserved $want — DHCP reservation not applied"
    fi

    if ping -c1 -W1 "$want" >/dev/null 2>&1; then
      success "$want reachable"
    else
      error "$want not reachable"
    fi
  fi
done

# ═══════════════════════════════════════════════════════════════
# STEP 5: SSH ACCESS
# ═══════════════════════════════════════════════════════════════

section "SSH access"
if [[ -f "$HOME/.ssh/k8s-homelab-kvm" ]]; then
  success "cluster SSH key present"
  fp=$(ssh-keygen -lf "$HOME/.ssh/k8s-homelab-kvm.pub" 2>/dev/null | awk '{print $2}')
  echo "      fingerprint: $fp"
else
  error "cluster SSH key missing: ~/.ssh/k8s-homelab-kvm"
fi

if grep -q "k8s-cp-01" "$HOME/.ssh/config" 2>/dev/null; then
  success "$HOME/.ssh/config has the k8s-homelab-kvm block"
else
  warn "$HOME/.ssh/config missing the host block — 'ssh k8s-cp-01' will not work"
fi

for node in "${NODES[@]}"; do
  if [[ -f "$HOME/.ssh/config" ]] && grep -q "$node" "$HOME/.ssh/config"; then
    if timeout 8 ssh -o ConnectTimeout=5 -o BatchMode=yes "$node" true 2>/dev/null; then
      success "ssh $node works"
    else
      error "ssh $node failed"
    fi
  fi
done

# ═══════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════

printf '\n\033[1m%s\033[0m\n' "──────────────────────────────"
if [[ $FAIL -gt 0 ]]; then
  printf '\033[31m%d failed\033[0m, %d passed\n\n' "$FAIL" "$PASS"
  _exit_status=1
else
  printf '\033[32mall %d checks passed\033[0m\n\n' "$PASS"
  _exit_status=0
fi
complete_msg "$APP_NAME completed"
exit "$_exit_status"
