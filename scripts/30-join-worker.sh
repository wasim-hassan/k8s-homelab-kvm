#!/usr/bin/env bash
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

K3S_VERSION="${K3S_VERSION:-v1.37.1+k3s1}"

require_cmd ssh
require_cmd kubectl

cp_node=$(inv_role_one control-plane | awk -F'|' '{print $1}')
cp_ip=$(inv_role_one control-plane | awk -F'|' '{print $2}')
[[ -n "$cp_node" ]] || die "no control-plane node found in $INVENTORY"

section "Joining workers to $cp_node ($cp_ip)"
assert_passwordless_sudo "$cp_node"

# ── Fetch join credentials from the server ───────────────────────────────
TOKEN=$(ssh_node "$cp_node" 'sudo -n cat /var/lib/rancher/k3s/server/node-token' 2>/dev/null)
if [[ -z "$TOKEN" ]]; then
  die "could not read node token from $cp_node — is the server installed? (run 20-install-k3s-server.sh)"
fi
ok "retrieved node token from $cp_node"

K3S_URL="https://$cp_ip:6443"

# ── Join each worker ─────────────────────────────────────────────────────
worker_count=0
while IFS='|' read -r node ip _ role _ _; do
  [[ -z "$node" ]] && continue
  worker_count=$((worker_count + 1))

  section "$node ($ip) — role=$role"
  assert_passwordless_sudo "$node"

  if ! ssh_node "$node" true 2>/dev/null; then
    bad "$node unreachable over SSH"
    continue
  fi
  ok "$node reachable"

  for chk in overlay br_netfilter nf_conntrack; do
    if ssh_node "$node" "cat /sys/module/$chk/initstate 2>/dev/null | grep -q live"; then
      ok "module $chk loaded"
    else
      bad "module $chk not loaded — run ./scripts/10-prepare-nodes.sh first"
    fi
  done

  installed=$(ssh_node "$node" 'command -v k3s >/dev/null 2>&1 && k3s --version 2>/dev/null | awk "{print \$3}"' || true)
  if [[ "$installed" == "$K3S_VERSION" ]]; then
    ok "k3s $K3S_VERSION already installed (skipping installer)"
  else
    [[ -n "$installed" ]] && info "found existing k3s $installed — reinstalling at $K3S_VERSION"

    bin=$(k3s_binary_ensure "$K3S_VERSION") || continue
    if k3s_binary_push "$node" "$bin"; then
      ok "staged k3s binary at $node:/usr/local/bin/k3s"
    else
      bad "could not push k3s binary to $node"
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
      ok "k3s agent installed"
    else
      bad "$node agent installer failed — see output above"
      continue
    fi
  fi

  # ── Wait for the agent service ─────────────────────────────────────────
  info "waiting for k3s-agent.service (up to 90s)"
  agent_up=0
  for _ in $(seq 1 45); do
    if ssh_node "$node" 'sudo -n systemctl is-active --quiet k3s-agent'; then
      agent_up=1; break
    fi
    sleep 2
  done

  if [[ $agent_up -eq 1 ]]; then
    ok "k3s-agent.service active on $node"
  else
    bad "$node k3s-agent.service not active — check: ssh $node 'sudo journalctl -u k3s-agent -n 50'"
  fi
done < <(inv_role worker)

if [[ $worker_count -eq 0 ]]; then
  die "no worker nodes found in $INVENTORY under k8s_workers"
fi

# ── Let the API settle, then report node states ──────────────────────────
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
    ok "all nodes Ready"
  else
    bad "$notready node(s) not Ready"
  fi
else
  bad "cannot reach the cluster API from this host"
fi

section "Result"
summary
