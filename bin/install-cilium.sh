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

CILIUM_PROXY_ARGS=""
if [ -n "${PROXY_HTTP:-}" ]; then
  CILIUM_PROXY_ARGS="--set httpProxy=$PROXY_HTTP --set httpsProxy=${PROXY_HTTPS:-$PROXY_HTTP} --set noProxy=${PROXY_NO:-localhost}"
fi

cilium install --version "${CILIUM_VERSION:-1.16.5}" --set k8sServiceHost=10.0.2.2 --set k8sServicePort=6443 $CILIUM_PROXY_ARGS

echo "Labeling worker nodes..."
for worker in ${WORKER_NAMES:-sigma gamma}; do
  kubectl label node "$worker" node-role.kubernetes.io/worker="" --overwrite 2>/dev/null || true
done

echo "Fixing kubernetes service endpoint..."
cat <<'EPEOF' | kubectl apply -f -
apiVersion: v1
kind: Endpoints
metadata:
  name: kubernetes
  namespace: default
subsets:
- addresses:
  - ip: 10.0.2.2
  ports:
  - name: https
    port: 6443
    protocol: TCP
EPEOF

echo ""
echo "Cilium installation initiated. Run 'cilium status' to monitor."
