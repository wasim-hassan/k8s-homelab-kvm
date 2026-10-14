#!/usr/bin/env bash
# ==================================== #
#   k8s-homelab-kvm                    #
#   scripts/30-join-worker.sh          #
#   wasim hassan                       #
# ==================================== #
#
# 30-join-worker.sh — join every worker node to the k3s cluster.
#
# Reads the join URL and node token from the control plane, then installs
# k3s in agent mode on each worker. Iterates inventory, so adding a node
# to inventory/nodes.yml under k8s_workers is all that's needed to grow.
#
# Idempotent: a worker already running k3s at the target version is skipped.
#
# Requires: 20-install-k3s-server.sh to have completed (server must be up).
#
# Usage:  ./scripts/30-join-worker.sh
#         K3S_VERSION=v1.37.1+k3s1 ./scripts/30-join-worker.sh
#
# Exit:   0 = all workers joined and Ready, 1 = failure.

set -uo pipefail

APP_NAME="Join k3s workers"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

K3S_VERSION="${K3S_VERSION:-v1.37.1+k3s1}"

require_cmd ssh
require_cmd kubectl

cp_node=$(inv_role_one control-plane | awk -F'|' '{print $1}')
cp_ip=$(inv_role_one control-plane | awk -F'|' '{print $2}')
[[ -n "$cp_node" ]] || die "no control-plane node found in $INVENTORY"

heading "$APP_NAME"

section "Joining workers to $cp_node ($cp_ip)"
assert_passwordless_sudo "$cp_node"

# ═══════════════════════════════════════════════════════════════
# STEP 1: JOIN CREDENTIALS
# ═══════════════════════════════════════════════════════════════
TOKEN=$(ssh_node "$cp_node" 'sudo -n cat /var/lib/rancher/k3s/server/node-token' 2>/dev/null)
if [[ -z "$TOKEN" ]]; then
  die "could not read node token from $cp_node — is the server installed? (run 20-install-k3s-server.sh)"
fi
success "retrieved node token from $cp_node"

K3S_URL="https://$cp_ip:6443"

# ═══════════════════════════════════════════════════════════════
# STEP 2: JOIN WORKERS
# ═══════════════════════════════════════════════════════════════
worker_count=0
while IFS='|' read -r node ip _ role _ _; do
  [[ -z "$node" ]] && continue
  worker_count=$((worker_count + 1))

  section "$node ($ip) — role=$role"
  assert_passwordless_sudo "$node"

  if ! ssh_node "$node" true 2>/dev/null; then
    error "$node unreachable over SSH"
    continue
  fi
  success "$node reachable"

  for chk in overlay br_netfilter nf_conntrack; do
    if ssh_node "$node" "cat /sys/module/$chk/initstate 2>/dev/null | grep -q live"; then
      success "module $chk loaded"
    else
      error "module $chk not loaded — run ./scripts/10-prepare-nodes.sh first"
    fi
  done

  installed=$(ssh_node "$node" 'command -v k3s >/dev/null 2>&1 && k3s --version 2>/dev/null | awk "{print \$3}"' || true)
  if [[ "$installed" == "$K3S_VERSION" ]]; then
    success "k3s $K3S_VERSION already installed (skipping installer)"
  else
    [[ -n "$installed" ]] && info "found existing k3s $installed — reinstalling at $K3S_VERSION"

    bin=$(k3s_binary_ensure "$K3S_VERSION") || continue
    if k3s_binary_push "$node" "$bin"; then
      success "staged k3s binary at $node:/usr/local/bin/k3s"
    else
      error "could not push k3s binary to $node"
      continue
    fi

    if ssh_root_node "$node" "$K3S_VERSION" "$K3S_URL" "$TOKEN" "$node" "$ip" <<'REMOTE'
set -uo pipefail
version="$1"; url="$2"; token="$3"; node_name="$4"; node_ip="$5"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$version" \
  INSTALL_K3S_SKIP_DOWNLOAD=true \
  K3S_URL="$url" \
  K3S_TOKEN="$token" \
  sh -s - agent --node-name "$node_name" --node-ip "$node_ip"
REMOTE
    then
      success "k3s agent installed"
    else
      error "$node agent installer failed — see output above"
      continue
    fi
  fi

  # ═══════════════════════════════════════════════════════════════
  # STEP 3: WAIT FOR AGENT
  # ═══════════════════════════════════════════════════════════════
  info "waiting for k3s-agent.service (up to 90s)"
  agent_up=0
  for _ in $(seq 1 45); do
    if ssh_node "$node" 'sudo -n systemctl is-active --quiet k3s-agent'; then
      agent_up=1; break
    fi
    sleep 2
  done

  if [[ $agent_up -eq 1 ]]; then
    success "k3s-agent.service active on $node"
  else
    error "$node k3s-agent.service not active — check: ssh $node 'sudo journalctl -u k3s-agent -n 50'"
  fi
done < <(inv_role worker)

if [[ $worker_count -eq 0 ]]; then
  die "no worker nodes found in $INVENTORY under k8s_workers"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 4: CLUSTER STATUS
# ═══════════════════════════════════════════════════════════════
section "Cluster nodes"
info "waiting for nodes to register (up to 90s)"
for _ in $(seq 1 45); do
  total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
  expected=$((worker_count + 1))
  [[ "$total" -ge "$expected" && "$ready" -eq "$total" ]] && break
  sleep 2
done

if kubectl get nodes >/dev/null 2>&1; then
  kubectl get nodes -o wide 2>/dev/null | sed 's/^/      /'
  notready=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc ' Ready ')
  if [[ "$notready" -eq 0 ]]; then
    success "all nodes Ready"
  else
    error "$notready node(s) not Ready"
  fi
else
  error "cannot reach the cluster API from this host"
fi

# ═══════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════

section "Result"
summary
_exit_status=$?
complete_msg "$APP_NAME completed"
exit "$_exit_status"
