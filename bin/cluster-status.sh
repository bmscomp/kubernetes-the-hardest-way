#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -q"

echo "Kubernetes The Hardest Way — Cluster Status"
echo ""

echo "Nodes:"
if kubectl get nodes -o wide 2>/dev/null; then
  echo ""
else
  echo "  API server not reachable"
  echo ""
fi

echo "Component Status:"
for svc in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  SSH_PORT=${SSH_PORTS_alpha}
  if ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "systemctl is-active $svc" 2>/dev/null | grep -q "active"; then
    printf "  ✔ %s\n" "$svc"
  else
    printf "  ✘ %s\n" "$svc"
  fi
done

for node in $WORKER_NAMES; do
  SSH_PORT_VAR="SSH_PORTS_${node}"
  SSH_PORT=${!SSH_PORT_VAR}
  for svc in containerd kubelet; do
    if ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "systemctl is-active $svc" 2>/dev/null | grep -q "active"; then
      printf "  ✔ %s (%s)\n" "$svc" "$node"
    else
      printf "  ✘ %s (%s)\n" "$svc" "$node"
    fi
  done
done
echo ""

echo "Pods:"
kubectl get pods -A -o wide 2>/dev/null || echo "  Cannot reach API server"
echo ""

if command -v cilium &>/dev/null; then
  echo "Cilium:"
  cilium status --brief 2>/dev/null || echo "  Cilium not available"
  echo ""
fi

echo "Resource Usage:"
kubectl top nodes 2>/dev/null || echo "  Metrics server not installed (run 'make metrics')"
