#!/usr/bin/env bash
set -eo pipefail

echo "Installing Cilium CLI..."
if ! command -v cilium &> /dev/null; then
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi
  if [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi
  
  CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-${OS}-${ARCH}.tar.gz"
  tar xzvfC cilium-${OS}-${ARCH}.tar.gz .
  rm cilium-${OS}-${ARCH}.tar.gz
  chmod +x cilium
  export PATH=$PATH:$(pwd)
fi

export KUBECONFIG="../configs/admin.kubeconfig"

echo "Waiting for Kubernetes API Server to be ready..."
until kubectl get nodes; do
  sleep 5
done

echo "Creating RBAC for API server kubelet access..."
cat <<'RBACEOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubelet-api-full
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/proxy", "nodes/stats", "nodes/log", "nodes/spec", "nodes/metrics"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubelet-api-full
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubelet-api-full
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: kubernetes
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: Kubernetes
RBACEOF

echo "Installing Cilium..."
cilium install --version 1.16.5 --set k8sServiceHost=10.0.2.2 --set k8sServicePort=6443

echo "Cilium installation initiated. Run 'cilium status' to monitor."
