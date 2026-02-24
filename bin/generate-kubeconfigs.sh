#!/usr/bin/env bash
set -eo pipefail

TLS_DIR="../tls"
KUBECONFIG_DIR="../configs"

if [ -f "$KUBECONFIG_DIR/admin.kubeconfig" ] && [ "$1" != "--force" ]; then
  echo "Kubeconfigs already exist — skipping. Use --force to regenerate."
  exit 0
fi

if [ ! -d "$TLS_DIR" ]; then
  echo "TLS directory not found. Please run generate-certs.sh first."
  exit 1
fi

mkdir -p "$KUBECONFIG_DIR"
cd "$KUBECONFIG_DIR"

# For control-plane components (admin, controller-manager, scheduler): use localhost
# For worker components (kubelet, kube-proxy): use 10.0.2.2 (QEMU host gateway)
CP_API_ADDRESS="127.0.0.1:6443"
WORKER_API_ADDRESS="10.0.2.2:6443"

echo "Generating kubelet kubeconfigs..."
for instance in sigma gamma; do
  kubectl config set-cluster kubernetes-the-hardest-way \
    --certificate-authority=$TLS_DIR/ca.pem \
    --embed-certs=true \
    --server=https://${WORKER_API_ADDRESS} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=$TLS_DIR/${instance}.pem \
    --client-key=$TLS_DIR/${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hardest-way \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
done

echo "Generating kube-proxy kubeconfig..."
kubectl config set-cluster kubernetes-the-hardest-way \
  --certificate-authority=$TLS_DIR/ca.pem \
  --embed-certs=true \
  --server=https://${WORKER_API_ADDRESS} \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=$TLS_DIR/kube-proxy.pem \
  --client-key=$TLS_DIR/kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hardest-way \
  --user=system:kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

echo "Generating kube-controller-manager kubeconfig..."
kubectl config set-cluster kubernetes-the-hardest-way \
  --certificate-authority=$TLS_DIR/ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=$TLS_DIR/kube-controller-manager.pem \
  --client-key=$TLS_DIR/kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hardest-way \
  --user=system:kube-controller-manager \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig

echo "Generating kube-scheduler kubeconfig..."
kubectl config set-cluster kubernetes-the-hardest-way \
  --certificate-authority=$TLS_DIR/ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
  --client-certificate=$TLS_DIR/kube-scheduler.pem \
  --client-key=$TLS_DIR/kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hardest-way \
  --user=system:kube-scheduler \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig

echo "Generating admin kubeconfig..."
kubectl config set-cluster kubernetes-the-hardest-way \
  --certificate-authority=$TLS_DIR/ca.pem \
  --embed-certs=true \
  --server=https://${CP_API_ADDRESS} \
  --kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=$TLS_DIR/admin.pem \
  --client-key=$TLS_DIR/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=admin.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hardest-way \
  --user=admin \
  --kubeconfig=admin.kubeconfig

kubectl config use-context default --kubeconfig=admin.kubeconfig

echo "Kubeconfig files generated successfully in $(pwd)"
