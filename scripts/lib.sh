#!/usr/bin/env bash
# ==================================== #
#   k8s-homelab-kvm                    #
#   scripts/lib.sh                     #
#   wasim hassan                       #
# ==================================== #
#
# lib.sh — shared helpers for the k8s-homelab-kvm scripts.
#
# Sourced, not executed. Provides:
#   - consistent console output (ok / bad / warn / info / section)
#   - REPO_DIR resolution
#   - inventory parsing (reads inventory/nodes.yml — no hardcoded hosts)
#   - SSH execution helpers against the cluster nodes
#
# The inventory is the single source of truth for node names, IPs, and roles.
# Nothing in the sibling scripts hardcodes a hostname or address.

# ---- Paths ----
# Resolve the repo root from this file's own location, so scripts work
# regardless of the caller's cwd.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"
INVENTORY="$REPO_DIR/inventory/nodes.yml"

# ---- Console output ----
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_OFF=''
fi

PASS=0
FAIL=0

ok()      { ((PASS++)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
bad()     { ((FAIL++)); printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"; }
warn()    {             printf '  %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
info()    {             printf '  %s→%s %s\n' "$C_BLUE" "$C_OFF" "$1"; }
section() {             printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

# ---- fedora-style aliases (house style) ----
# Cosmetic aliases so these scripts read in the same house style as the
# author's other repos. Behaviour is unchanged: success/error share the
# ok/bad PASS/FAIL counters.
heading()      { printf '\n%s==== %s ====%s\n' "$C_BOLD" "$1" "$C_OFF"; }
success()      { ok "$@"; }
error()        { bad "$@"; }
skip()         { printf '  %s-%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
verify_msg()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
complete_msg() { printf '\n%s%s%s\n' "$C_GREEN" "$1" "$C_OFF"; }
logged()       { [[ -n "${LOGFILE:-}" ]] && printf '  %s→%s Log: %s\n' "$C_BLUE" "$C_OFF" "$LOGFILE"; return 0; }

die() { printf '\n%serror:%s %s\n\n' "$C_RED" "$C_OFF" "$1" >&2; exit 1; }

summary() {
  printf '\n%s──────────────────────────────%s\n' "$C_BOLD" "$C_OFF"
  if [[ $FAIL -gt 0 ]]; then
    printf '%s%d failed%s, %d passed\n\n' "$C_RED" "$FAIL" "$C_OFF" "$PASS"
    return 1
  fi
  printf '%sall %d checks passed%s\n\n' "$C_GREEN" "$PASS" "$C_OFF"
  return 0
}

# ---- Inventory ----
# Emit one line per host, pipe-delimited, newest order from nodes.yml:
#   name|ip|user|role|memory_mib|key
# Consumed with `while IFS='|' read -r ...`.
inv_all() {
  [[ -f "$INVENTORY" ]] || die "inventory not found: $INVENTORY"
  python3 - "$INVENTORY" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
root = data.get('all', {})
children = root.get('children', {})
default_key = root.get('vars', {}).get('ansible_ssh_private_key_file', '')
rows = []
for group, body in children.items():
    for name, attrs in (body.get('hosts') or {}).items():
        attrs = attrs or {}
        rows.append('|'.join([
            name,
            str(attrs.get('ansible_host', '')),
            str(attrs.get('ansible_user', '')),
            str(attrs.get('node_role', '')),
            str(attrs.get('memory_mib', '')),
            default_key,
        ]))
for r in rows:
    print(r)
PY
}

# Same as inv_all, filtered to one role. Usage: inv_role control-plane
inv_role() {
  inv_all | awk -F'|' -v want="$1" '$4 == want'
}

# First host matching a role (convenience for single-node roles).
inv_role_one() {
  inv_role "$1" | head -1
}

# ---- SSH ----
# Run a command on a node as the login user. Non-interactive: fail rather
# than prompt for a password.
# -n is important: without it ssh reads the local stdin and will swallow
# input from any enclosing `while read < <(...)` loop.
ssh_node() {
  local name="$1"; shift
  ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
      "$name" "$@"
}

# Run a command on a node via sudo. The nodes are configured passwordless.
ssh_sudo() {
  local name="$1"; shift
  ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
      "$name" "sudo -n $*"
}

# Stream a multi-line root script into a node. Values are passed as
# positional args to `bash -s --` so the payload needs no local expansion.
# Usage:
#   ssh_root_node "$node" arg1 arg2 <<'REMOTE'
#   ... $1 $2 ...
#   REMOTE
ssh_root_node() {
  local name="$1"; shift
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
      "$name" sudo -n bash -s -- "$@"
}

# Write a file on a node as root, whatever its content.
#
# Note: ssh_root_node streams its *script* over stdin, so stdin is not
# available to carry data. The content is therefore base64-encoded and
# passed as a positional argument, which also makes it immune to quoting.
write_remote_file() {
  local name="$1" path="$2" content="$3"
  local b64
  b64=$(printf '%s' "$content" | base64 -w0)
  ssh_root_node "$name" "$path" "$b64" <<'REMOTE'
set -euo pipefail
path="$1"; b64="$2"
mkdir -p "$(dirname "$path")"
printf '%s' "$b64" | base64 -d > "$path"
REMOTE
}

# A kernel module is "present" if it is loaded or compiled into the kernel
# (built-ins have no lsmod entry but do have a /sys/module directory).
module_present() {
  local name="$1" mod="$2"
  ssh_node "$name" "lsmod | grep -qE '^$mod ' || [ -d /sys/module/$mod ]" 2>/dev/null
}

# ---- k3s binary staging ----
# GitHub release downloads of the k3s binary (~78 MiB) can be very slow or
# stall from inside the VMs. Downloading once on the host, verifying it, and
# pushing it over the local libvirt bridge is both faster and checked.

K3S_CACHE_DIR="${K3S_CACHE_DIR:-$HOME/.cache/k3s-homelab}"

k3s_release_base() {
  # The '+' in the version must be percent-encoded for the release URL.
  printf 'https://github.com/k3s-io/k3s/releases/download/%s' "${1//+/%2B}"
}

# Download the k3s binary for $1 into the host cache, verifying its SHA256
# against the release manifest. Prints the cached path on success.
k3s_binary_ensure() {
  local version="$1"
  local base; base=$(k3s_release_base "$version")
  local bin="$K3S_CACHE_DIR/k3s-$version"
  mkdir -p "$K3S_CACHE_DIR"

  local expected
  expected=$(curl -fsSL "$base/sha256sum-amd64.txt" 2>/dev/null | awk '$2=="k3s"{print $1}')
  if [[ -z "$expected" ]]; then
    die "could not fetch the sha256 manifest for k3s $version"
  fi

  if [[ -f "$bin" ]] && [[ "$(sha256sum "$bin" | awk '{print $1}')" == "$expected" ]]; then
    info "using cached k3s binary ($(du -h "$bin" | cut -f1))" >&2
    printf '%s\n' "$bin"
    return 0
  fi

  info "downloading k3s $version from GitHub (resumable; this can take a few minutes)" >&2
  if ! curl -fL --retry 5 --retry-delay 3 -C - -o "$bin" "$base/k3s" 2>/dev/null; then
    die "download of k3s binary failed"
  fi

  local actual; actual=$(sha256sum "$bin" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    command rm -f "$bin"
    die "k3s binary checksum mismatch (expected $expected, got $actual)"
  fi
  ok "k3s binary downloaded and checksum verified" >&2
  printf '%s\n' "$bin"
}

# Copy a verified local binary to a node at /usr/local/bin/k3s so the
# installer can run with INSTALL_K3S_SKIP_DOWNLOAD=true.
k3s_binary_push() {
  local node="$1" bin="$2"
  if ! scp -q -o BatchMode=yes -o ConnectTimeout=8 \
        "$bin" "$node:/tmp/k3s.download"; then
    return 1
  fi
  ssh_sudo "$node" install -m 0755 /tmp/k3s.download /usr/local/bin/k3s || return 1
  ssh_sudo "$node" rm -f /tmp/k3s.download || true
  return 0
}

# ---- Guards ----
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Confirm sudo works non-interactively before doing anything destructive.
assert_passwordless_sudo() {
  local name="$1"
  if ! ssh_node "$name" 'sudo -n true' 2>/dev/null; then
    die "passwordless sudo not available on $name — cannot proceed unattended"
  fi
}
