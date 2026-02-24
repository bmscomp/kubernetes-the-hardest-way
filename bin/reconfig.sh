#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

push_to_node() {
  local node=$1
  local ssh_port_var="SSH_PORTS_${node}"
  local ssh_port=${!ssh_port_var}
  local cloud_init="$PROJECT_DIR/cloud-init/$node"

  echo "Reconfiguring $node (port $ssh_port)..."

  if ! ssh $SSH_OPTS -p "$ssh_port" root@127.0.0.1 "echo OK" &>/dev/null; then
    echo "  ✘ $node — not reachable on port $ssh_port"
    return 1
  fi

  scp $SSH_OPTS -P "$ssh_port" \
    "$cloud_init/nixos/kubelet-config.yaml" \
    "root@127.0.0.1:/etc/nixos/" 2>/dev/null

  local tls_files="$PROJECT_DIR/tls"
  scp $SSH_OPTS -P "$ssh_port" \
    "$tls_files/ca.pem" \
    "$tls_files/${node}.pem" \
    "$tls_files/${node}-key.pem" \
    "root@127.0.0.1:/var/lib/kubernetes/pki/" 2>/dev/null

  local configs="$PROJECT_DIR/configs"
  if [ -f "$configs/${node}.kubeconfig" ]; then
    scp $SSH_OPTS -P "$ssh_port" \
      "$configs/${node}.kubeconfig" \
      "root@127.0.0.1:/var/lib/kubernetes/pki/" 2>/dev/null
  fi

  ssh $SSH_OPTS -p "$ssh_port" root@127.0.0.1 "systemctl restart kubelet" 2>/dev/null
  echo "  ✔ $node — kubelet restarted"
}

echo "Regenerating configs..."
"$SCRIPT_DIR/generate-nocloud-iso.sh" alpha
"$SCRIPT_DIR/generate-nocloud-iso.sh" sigma
"$SCRIPT_DIR/generate-nocloud-iso.sh" gamma

echo ""
echo "Pushing configs to running nodes..."
for node in $ALL_NODES; do
  push_to_node "$node" || true
done

echo ""
echo "Reconfiguration complete."
