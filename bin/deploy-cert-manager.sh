#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"
source "$PROJECT_DIR/lib/log.sh"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.17.1}"

log_step "🔐" "Applying cert-manager CRDs"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.crds.yaml" >> "$_LOG_FILE" 2>&1
log_ok

log_step "📦" "Applying cert-manager manifests"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-manager
  namespace: cert-manager
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-manager-webhook
  namespace: cert-manager
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-manager-cainjector
  namespace: cert-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-controller-issuers
rules:
- apiGroups: ["cert-manager.io"]
  resources: ["issuers", "issuers/status"]
  verbs: ["update", "patch"]
- apiGroups: ["cert-manager.io"]
  resources: ["issuers"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-controller-clusterissuers
rules:
- apiGroups: ["cert-manager.io"]
  resources: ["clusterissuers", "clusterissuers/status"]
  verbs: ["update", "patch"]
- apiGroups: ["cert-manager.io"]
  resources: ["clusterissuers"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-controller-certificates
rules:
- apiGroups: ["cert-manager.io"]
  resources: ["certificates", "certificates/status", "certificaterequests", "certificaterequests/status"]
  verbs: ["update", "patch"]
- apiGroups: ["cert-manager.io"]
  resources: ["certificates", "certificaterequests", "clusterissuers", "issuers"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["cert-manager.io"]
  resources: ["certificates/finalizers", "certificaterequests/finalizers"]
  verbs: ["update"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "delete", "patch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-controller-orders
rules:
- apiGroups: ["acme.cert-manager.io"]
  resources: ["orders", "orders/status", "challenges", "challenges/status"]
  verbs: ["update", "patch"]
- apiGroups: ["acme.cert-manager.io"]
  resources: ["orders", "challenges"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["cert-manager.io"]
  resources: ["clusterissuers", "issuers"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "ingresses/finalizers"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-cainjector
rules:
- apiGroups: ["cert-manager.io"]
  resources: ["certificates"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "create", "update", "patch"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["apiregistration.k8s.io"]
  resources: ["apiservices"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-controller-issuers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-controller-issuers
subjects:
- kind: ServiceAccount
  name: cert-manager
  namespace: cert-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-controller-clusterissuers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-controller-clusterissuers
subjects:
- kind: ServiceAccount
  name: cert-manager
  namespace: cert-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-controller-certificates
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-controller-certificates
subjects:
- kind: ServiceAccount
  name: cert-manager
  namespace: cert-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-controller-orders
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-controller-orders
subjects:
- kind: ServiceAccount
  name: cert-manager
  namespace: cert-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-cainjector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-cainjector
subjects:
- kind: ServiceAccount
  name: cert-manager-cainjector
  namespace: cert-manager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cert-manager
  namespace: cert-manager
  labels:
    app: cert-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cert-manager
  template:
    metadata:
      labels:
        app: cert-manager
    spec:
      serviceAccountName: cert-manager
      containers:
      - name: cert-manager
        image: quay.io/jetstack/cert-manager-controller:v${CERT_MANAGER_VERSION}
        args:
        - --v=2
        - --cluster-resource-namespace=cert-manager
        - --leader-election-namespace=cert-manager
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "10.0.2.2"
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 128Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cert-manager-cainjector
  namespace: cert-manager
  labels:
    app: cert-manager-cainjector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cert-manager-cainjector
  template:
    metadata:
      labels:
        app: cert-manager-cainjector
    spec:
      serviceAccountName: cert-manager-cainjector
      containers:
      - name: cainjector
        image: quay.io/jetstack/cert-manager-cainjector:v${CERT_MANAGER_VERSION}
        args:
        - --v=2
        - --leader-election-namespace=cert-manager
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "10.0.2.2"
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  ports:
  - port: 9402
    targetPort: 9402
    protocol: TCP
  selector:
    app: cert-manager
EOF
log_ok

log_step "⏳" "Waiting for cert-manager rollout"
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=120s >> "$_LOG_FILE" 2>&1
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=120s >> "$_LOG_FILE" 2>&1
log_ok

log_step "🔏" "Creating self-signed ClusterIssuer"
sleep 5
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cluster-ca
spec:
  ca:
    secretName: cluster-ca-keypair
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cluster-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: "Kubernetes The Hardest Way CA"
  secretName: cluster-ca-keypair
  duration: 87600h
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
    group: cert-manager.io
EOF
log_ok

log_summary
log_info "cert-manager is ready with two ClusterIssuers:"
log_info "  - selfsigned  (for quick testing)"
log_info "  - cluster-ca  (proper CA, auto-generated)"
log_info ""
log_info "Add to any Ingress for auto-TLS:"
log_info "  annotations:"
log_info "    cert-manager.io/cluster-issuer: cluster-ca"
