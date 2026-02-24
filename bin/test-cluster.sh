#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

PASS=0
FAIL=0

test_case() {
  local name=$1
  shift
  printf "  %-40s " "$name"
  if eval "$@" &>/dev/null; then
    echo -e "\e[32mPASS\e[0m"
    ((PASS++))
  else
    echo -e "\e[31mFAIL\e[0m"
    ((FAIL++))
  fi
}

echo "Kubernetes The Hardest Way — Cluster Test Suite"
echo ""

echo "Nodes:"
test_case "All nodes are Ready" \
  "kubectl get nodes | grep -c 'Ready' | grep -q '3'"
test_case "Alpha is control plane" \
  "kubectl get node alpha"
test_case "Sigma has worker role" \
  "kubectl get node sigma -o jsonpath='{.metadata.labels}' | grep -q worker"
test_case "Gamma has worker role" \
  "kubectl get node gamma -o jsonpath='{.metadata.labels}' | grep -q worker"

echo ""
echo "Control Plane:"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -q"
test_case "etcd is active" \
  "ssh $SSH_OPTS -p ${SSH_PORTS_alpha} root@127.0.0.1 'systemctl is-active etcd'"
test_case "kube-apiserver is active" \
  "ssh $SSH_OPTS -p ${SSH_PORTS_alpha} root@127.0.0.1 'systemctl is-active kube-apiserver'"
test_case "kube-scheduler is active" \
  "ssh $SSH_OPTS -p ${SSH_PORTS_alpha} root@127.0.0.1 'systemctl is-active kube-scheduler'"
test_case "kube-controller-manager is active" \
  "ssh $SSH_OPTS -p ${SSH_PORTS_alpha} root@127.0.0.1 'systemctl is-active kube-controller-manager'"

echo ""
echo "Networking:"
test_case "Cilium agents running" \
  "kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[*].status.phase}' | grep -q Running"
test_case "Kubernetes service has endpoints" \
  "kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q '10.0.2.2'"

echo ""
echo "DNS:"
test_case "CoreDNS pods running" \
  "kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.phase}' | grep -q Running"
test_case "DNS resolves kubernetes.default" \
  "kubectl run dns-test-$RANDOM --rm -i --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -q '10.32.0.1'"

echo ""
echo "Pod Lifecycle:"
NGINX_NAME="test-nginx-$$"
kubectl create deployment "$NGINX_NAME" --image=nginx --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
test_case "Pod scheduling" \
  "kubectl rollout status deployment/$NGINX_NAME --timeout=60s"

POD_NAME=$(kubectl get pods -l app="$NGINX_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
test_case "kubectl logs works" \
  "kubectl logs $POD_NAME 2>&1"
test_case "kubectl exec works" \
  "kubectl exec $POD_NAME -- echo 'exec works' 2>&1"

kubectl delete deployment "$NGINX_NAME" --wait=false &>/dev/null || true

echo ""
echo "======================================="
echo -e "  Results: \e[32m$PASS passed\e[0m, \e[31m$FAIL failed\e[0m"
echo "======================================="

[ "$FAIL" -eq 0 ] || exit 1
