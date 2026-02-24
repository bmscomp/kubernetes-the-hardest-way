#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

WORKER_NAME="${1:-}"
if [ -z "$WORKER_NAME" ]; then
  echo "Usage: $0 <worker-name>"
  echo ""
  echo "Example: $0 sigma"
  echo ""
  echo "This will:"
  echo "  1. Drain the node (evict all pods)"
  echo "  2. Delete the node from Kubernetes"
  echo "  3. Stop the QEMU VM"
  echo "  4. Remove disk image and certificates"
  exit 1
fi

if [ "$WORKER_NAME" = "$CONTROL_PLANE_NAME" ]; then
  echo "Error: cannot remove the control plane node."
  exit 1
fi

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

SSH_PORT_VAR="SSH_PORTS_${WORKER_NAME}"
SSH_PORT=${!SSH_PORT_VAR:-""}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -q"

echo "======================================================================="
echo " Removing Worker Node: $WORKER_NAME"
echo "======================================================================="
echo ""

step() {
  local step_num=$1; shift
  echo -e "\n\e[36m[$step_num]\e[0m $*"
  echo "-----------------------------------------------------------------------"
}

step "1/4" "Draining node..."
if kubectl get node "$WORKER_NAME" &>/dev/null; then
  kubectl drain "$WORKER_NAME" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>/dev/null || true
  echo "  ✔ Node drained"
else
  echo "  Node not found in cluster — skipping drain"
fi

step "2/4" "Deleting node from Kubernetes..."
kubectl delete node "$WORKER_NAME" --ignore-not-found
echo "  ✔ Node deleted"

step "3/4" "Stopping VM..."
if [ -n "$SSH_PORT" ]; then
  ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "poweroff" 2>/dev/null || true
  sleep 3
fi
echo "  ✔ VM stopped"

step "4/4" "Cleaning up artifacts..."
rm -f "$PROJECT_DIR/images/${WORKER_NAME}.qcow2"
rm -f "$PROJECT_DIR/images/${WORKER_NAME}-efivars.fd"
rm -f "$PROJECT_DIR/images/${WORKER_NAME}-console.log"
rm -f "$PROJECT_DIR/images/${WORKER_NAME}-install.log"
rm -f "$PROJECT_DIR/tls/${WORKER_NAME}.pem"
rm -f "$PROJECT_DIR/tls/${WORKER_NAME}-key.pem"
rm -f "$PROJECT_DIR/tls/${WORKER_NAME}-csr.json"
rm -f "$PROJECT_DIR/configs/${WORKER_NAME}.kubeconfig"
rm -rf "$PROJECT_DIR/cloud-init/${WORKER_NAME}"
echo "  ✔ Disk image, certificates, and configs removed"

echo ""
echo -e "\e[32m✔ Worker '$WORKER_NAME' has been removed.\e[0m"
echo ""
echo "  Update cluster.env to remove this worker from WORKER_NAMES and ALL_NODES."
kubectl get nodes 2>/dev/null || true
