#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"
source "$PROJECT_DIR/lib/log.sh"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

NODE_NAME="${1:-}"
if [ -z "$NODE_NAME" ]; then
  echo "Usage: $0 <node-name|all>"
  echo ""
  echo "Examples:"
  echo "  $0 sigma       # Upgrade a single worker"
  echo "  $0 all         # Rolling upgrade of all workers"
  echo ""
  echo "This will:"
  echo "  1. Drain the node (move workloads away)"
  echo "  2. SSH in and run nixos-rebuild switch"
  echo "  3. Reboot the node"
  echo "  4. Wait for it to rejoin the cluster"
  echo "  5. Uncordon the node"
  exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -q"

upgrade_node() {
  local node=$1
  local SSH_PORT_VAR="SSH_PORTS_${node}"
  local SSH_PORT=${!SSH_PORT_VAR:-""}

  if [ -z "$SSH_PORT" ]; then
    log_warn "No SSH port found for $node — skipping"
    return 1
  fi

  if [ "$node" = "$CONTROL_PLANE_NAME" ]; then
    log_warn "Control plane upgrade not yet supported — skipping $node"
    return 0
  fi

  log_step "🔽" "Draining $node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s >> "$_LOG_FILE" 2>&1
  log_ok

  log_step "🔄" "Upgrading NixOS on $node"
  ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 \
    "nix-channel --update && nixos-rebuild switch" >> "$_LOG_FILE" 2>&1
  log_ok

  log_step "🔃" "Rebooting $node"
  ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "reboot" >> "$_LOG_FILE" 2>&1 || true
  sleep 10
  log_ok

  log_step "⏳" "Waiting for $node to rejoin"
  for i in $(seq 1 60); do
    NODE_STATUS=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $2}' || echo "")
    if echo "$NODE_STATUS" | grep -q "Ready"; then
      break
    fi
    sleep 5
  done
  NODE_STATUS=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $2}' || echo "")
  echo "$NODE_STATUS" | grep -q "Ready" && log_ok || { log_fail; return 1; }

  log_step "✅" "Uncordoning $node"
  kubectl uncordon "$node" >> "$_LOG_FILE" 2>&1
  log_ok
}

if [ "$NODE_NAME" = "all" ]; then
  log_header "☸  Rolling Upgrade — All Workers"
  for worker in $WORKER_NAMES; do
    upgrade_node "$worker"
  done
else
  log_header "☸  Upgrading Node: $NODE_NAME"
  upgrade_node "$NODE_NAME"
fi

log_summary
