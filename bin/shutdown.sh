#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

echo "Gracefully shutting down all nodes..."

for node in $ALL_NODES; do
  SSH_PORT_VAR="SSH_PORTS_${node}"
  SSH_PORT=${!SSH_PORT_VAR}

  if ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "echo OK" &>/dev/null; then
    echo "  Shutting down $node..."
    ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "poweroff" &>/dev/null || true
  else
    echo "  $node — not reachable, skipping"
  fi
done

echo "  Waiting for VMs to exit..."
sleep 5

REMAINING=$(pgrep -f "qemu-system" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING" -gt 0 ]; then
  echo "  $REMAINING QEMU process(es) still running — force killing..."
  killall qemu-system-aarch64 qemu-system-x86_64 2>/dev/null || true
fi

echo "All nodes stopped."
