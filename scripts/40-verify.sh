#!/usr/bin/env bash
#
# 40-verify.sh — confirm the cluster is healthy end to end.
#
# Read-only. Safe to run any time. Answers "is this a working cluster?"
# rather than "did the install commands return 0?".
#
# Usage:  ./scripts/40-verify.sh
#
# Exit:   0 = all checks passed, 1 = something is wrong.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd ssh
require_cmd kubectl

expected_nodes=$(inv_all | grep -c '|')
cp_ip=$(inv_role_one control-plane | awk -F'|' '{print $2}')

section "Local tooling"
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl present ($(kubectl version --client 2>/dev/null | awk '/Client Version/{print $3}'))"
else
  bad "kubectl not found on PATH"
fi

if [[ -f "$HOME/.kube/config" ]]; then
  perms=$(stat -c '%a' "$HOME/.kube/config")
  if [[ "$perms" == "600" ]]; then
    ok "$HOME/.kube/config exists, mode 600"
  else
    bad "$HOME/.kube/config mode is $perms — should be 600 (it is a cluster-admin credential)"
  fi
else
  bad "$HOME/.kube/config missing — run ./scripts/20-install-k3s-server.sh"
fi

section "API reachability"
if kubectl --request-timeout=10s cluster-info >/dev/null 2>&1; then
  ok "kubectl can talk to the cluster"
else
  bad "kubectl cannot reach the API"
  summary; exit 1
fi

if timeout 5 bash -c "echo > /dev/tcp/$cp_ip/6443" 2>/dev/null; then
  ok "host can reach https://$cp_ip:6443 directly"
else
  bad "host cannot reach $cp_ip:6443"
fi

section "Nodes"
node_total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [[ "$node_total" -eq "$expected_nodes" ]]; then
  ok "$node_total node(s) registered (inventory expects $expected_nodes)"
else
  bad "$node_total node(s) registered, inventory expects $expected_nodes"
fi

kubectl get nodes -o wide 2>/dev/null | sed 's/^/      /'

notready=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc ' Ready ')
if [[ "$notready" -eq 0 ]]; then
  ok "all nodes Ready"
else
  bad "$notready node(s) not Ready"
fi

# ── Control-plane services on each node ──────────────────────────────────
section "k3s services"
while IFS='|' read -r node _ _ role _ _; do
  [[ -z "$node" ]] && continue
  svc="k3s"
  [[ "$role" == "worker" ]] && svc="k3s-agent"
  if ssh_node "$node" "sudo -n systemctl is-active --quiet $svc" 2>/dev/null; then
    ok "$node $svc active"
  else
    bad "$node $svc not active"
  fi
done < <(inv_all)

# ── Core add-ons ─────────────────────────────────────────────────────────
section "Core add-ons"
kubectl get pods -n kube-system --no-headers 2>/dev/null | sed 's/^/      /'

for want in coredns local-path-provisioner metrics-server; do
  if kubectl get deployment -n kube-system "$want" >/dev/null 2>&1; then
    ready_replicas=$(kubectl get deployment -n kube-system "$want" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [[ "${ready_replicas:-0}" -ge 1 ]]; then
      ok "$want ready (${ready_replicas} replica)"
    else
      bad "$want has no ready replicas"
    fi
  else
    warn "$want not found (may not be part of this k3s build)"
  fi
done

if kubectl get deployment -n kube-system traefik >/dev/null 2>&1; then
  warn "traefik is deployed — expected it to be disabled (reclaimable ~180 MiB)"
else
  ok "traefik disabled (as designed)"
fi

# ── Pending / failing pods anywhere ──────────────────────────────────────
section "Workload health"
bad_pods=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$4 !~ /Running|Completed/ {print $0}' | wc -l)
if [[ "$bad_pods" -eq 0 ]]; then
  ok "no pods stuck in Pending/Error/CrashLoop"
else
  warn "$bad_pods pod(s) not Running/Completed:"
  kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 !~ /Running|Completed/ {print "      " $0}'
fi

section "Result"
summary
