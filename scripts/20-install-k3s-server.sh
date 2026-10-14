#!/usr/bin/env bash
# ==================================== #
#   k8s-homelab-kvm                    #
#   scripts/20-install-k3s-server.sh   #
#   wasim hassan                       #
# ==================================== #
#
# 20-install-k3s-server.sh — install k3s server on the control-plane node
#                           and pull a working kubeconfig onto this host.
#
# Design notes:
#   - Version is PINNED (K3S_VERSION). An unpinned install follows the
#     stable channel and can silently move the control plane away from a
#     kubectl that was installed at a fixed version.
#   - --disable traefik: Traefik costs ~180 MiB and ~40 CRDs on a 2 GiB
#     control plane. Ingress can be added later with one HelmRelease.
#     See docs/runbooks/01-install-k3s.md for how to reverse this.
#   - --write-kubeconfig-mode 644 lets the operator read the server's own
#     kubeconfig without sudo. The copy we place at ~/.kube/config is
#     still chmod 600 because it is a cluster-admin credential.
#
# Idempotent: if k3s is already at K3S_VERSION on the node, the installer
# step is skipped and only the kubeconfig is refreshed.
#
# Usage:  ./scripts/20-install-k3s-server.sh
#         K3S_VERSION=v1.37.1+k3s1 ./scripts/20-install-k3s-server.sh
#
# Exit:   0 = server installed and kubeconfig written, 1 = failure.

set -uo pipefail

APP_NAME="Install k3s server"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

K3S_VERSION="${K3S_VERSION:-v1.37.1+k3s1}"
DISABLE_TRAEFIK=1

require_cmd ssh
require_cmd kubectl

node=$(inv_role_one control-plane | awk -F'|' '{print $1}')
ip=$(inv_role_one control-plane | awk -F'|' '{print $2}')
[[ -n "$node" ]] || die "no control-plane node found in $INVENTORY"

heading "$APP_NAME"

section "k3s server install — $node ($ip)"
info "target version: $K3S_VERSION"
assert_passwordless_sudo "$node"

# ═══════════════════════════════════════════════════════════════
# STEP 1: PREFLIGHT
# ═══════════════════════════════════════════════════════════════
for chk in overlay br_netfilter nf_conntrack; do
  if ssh_node "$node" "cat /sys/module/$chk/initstate 2>/dev/null | grep -q live"; then
    success "module $chk loaded"
  else
    error "module $chk not loaded — run ./scripts/10-prepare-nodes.sh first"
  fi
done

if [[ "$(ssh_node "$node" 'sysctl -n net.ipv4.ip_forward')" == "1" ]]; then
  success "net.ipv4.ip_forward=1"
else
  error "net.ipv4.ip_forward != 1 — run ./scripts/10-prepare-nodes.sh first"
fi

if ! ssh_node "$node" true 2>/dev/null; then
  die "$node unreachable — cannot continue"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 2: INSTALL K3S SERVER
# ═══════════════════════════════════════════════════════════════
installed=$(ssh_node "$node" 'command -v k3s >/dev/null 2>&1 && k3s --version 2>/dev/null | awk "{print \$3}"' || true)
if [[ "$installed" == "$K3S_VERSION" ]]; then
  success "k3s $K3S_VERSION already installed on $node (skipping installer)"
else
  [[ -n "$installed" ]] && info "found existing k3s $installed — upgrading to $K3S_VERSION"

  # Stage a verified binary from the host cache rather than letting the
  # node download it — GitHub release speed from the VMs is unreliable.
  bin=$(k3s_binary_ensure "$K3S_VERSION") || exit 1
  if k3s_binary_push "$node" "$bin"; then
    success "staged k3s binary at $node:/usr/local/bin/k3s"
  else
    error "could not push k3s binary to $node"
    summary; exit 1
  fi

  install_args=(server --node-name "$node" --node-ip "$ip" --write-kubeconfig-mode 644)
  [[ $DISABLE_TRAEFIK -eq 1 ]] && install_args+=(--disable traefik)

  if ssh_root_node "$node" "$K3S_VERSION" "${install_args[@]}" <<'REMOTE'
set -uo pipefail
version="$1"; shift
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$version" \
  INSTALL_K3S_SKIP_DOWNLOAD=true \
  sh -s - "$@"
REMOTE
  then
    success "k3s server installed"
  else
    error "k3s installer failed — see output above"
    summary; exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: WAIT FOR API SERVER
# ═══════════════════════════════════════════════════════════════
info "waiting for the API server (up to 90s)"
ready=0
for _ in $(seq 1 45); do
  if ssh_node "$node" 'sudo -n k3s kubectl get --raw /readyz' >/dev/null 2>&1 \
     || ssh_node "$node" 'test -s /etc/rancher/k3s/k3s.yaml' 2>/dev/null; then
    if ssh_node "$node" 'sudo -n systemctl is-active --quiet k3s'; then
      ready=1; break
    fi
  fi
  sleep 2
done

if [[ $ready -eq 1 ]]; then
  success "k3s.service active on $node"
else
  error "k3s.service did not become active — check: ssh $node 'sudo journalctl -u k3s -n 50'"
  summary; exit 1
fi

# ═══════════════════════════════════════════════════════════════
# STEP 4: KUBECONFIG
# ═══════════════════════════════════════════════════════════════
section "kubeconfig"
mkdir -p "$HOME/.kube"
chmod 700 "$HOME/.kube"

KUBECONFIG_PATH="$HOME/.kube/config"

if [[ -f "$KUBECONFIG_PATH" ]]; then
  backup="$KUBECONFIG_PATH.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$KUBECONFIG_PATH" "$backup"
  info "backed up existing kubeconfig to $backup"
fi

if ssh_node "$node" 'cat /etc/rancher/k3s/k3s.yaml' >"$KUBECONFIG_PATH.tmp" 2>/dev/null; then
  # The server writes 127.0.0.1. Point it at the node's actual address so
  # the host's kubectl can reach it over the libvirt bridge.
  sed -i "s|server: https://127.0.0.1:6443|server: https://$ip:6443|" "$KUBECONFIG_PATH.tmp"
  mv "$KUBECONFIG_PATH.tmp" "$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"   # cluster-admin credential
  success "kubeconfig written to $KUBECONFIG_PATH (server https://$ip:6443, mode 600)"
else
  rm -f "$KUBECONFIG_PATH.tmp"
  error "could not read /etc/rancher/k3s/k3s.yaml from $node"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 5: VERIFY
# ═══════════════════════════════════════════════════════════════
section "Verification"
if kubectl --request-timeout=10s get nodes >/dev/null 2>&1; then
  success "host kubectl can reach the cluster API"
  kubectl get nodes -o wide 2>/dev/null | sed 's/^/      /'
  if kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    success "$node is Ready"
  else
    warn "$node not Ready yet — add-ons may still be starting"
  fi
else
  error "host kubectl cannot reach the API — check https://$ip:6443 reachability"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 6: NEXT STEPS
# ═══════════════════════════════════════════════════════════════
info "worker join reads the token from $node:/var/lib/rancher/k3s/server/node-token"

# ═══════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════

section "Result"
summary
_exit_status=$?
complete_msg "$APP_NAME completed"
exit "$_exit_status"
