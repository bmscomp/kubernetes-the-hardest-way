#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"
source "$PROJECT_DIR/lib/log.sh"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

DASHBOARD_VERSION="${DASHBOARD_VERSION:-7.12.0}"

log_step "📊" "Applying Dashboard manifests"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: kubernetes-dashboard
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: dashboard-admin
  namespace: kubernetes-dashboard
---
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-admin-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: dashboard-admin
type: kubernetes.io/service-account-token
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-settings
  namespace: kubernetes-dashboard
data:
  _global: '{"clusterName":"Kubernetes The Hardest Way","itemsPerPage":10}'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["dashboard-admin-token"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["dashboard-settings"]
  verbs: ["get", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubernetes-dashboard
rules:
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kubernetes-dashboard
subjects:
- kind: ServiceAccount
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-dashboard
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubernetes-dashboard
subjects:
- kind: ServiceAccount
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  labels:
    k8s-app: kubernetes-dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kubernetes-dashboard
  template:
    metadata:
      labels:
        k8s-app: kubernetes-dashboard
    spec:
      serviceAccountName: kubernetes-dashboard
      containers:
      - name: dashboard
        image: kubernetesui/dashboard:v2.7.0
        args:
        - --auto-generate-certificates
        - --namespace=kubernetes-dashboard
        ports:
        - containerPort: 8443
          protocol: TCP
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "10.0.2.2"
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
        volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
        livenessProbe:
          httpGet:
            scheme: HTTPS
            path: /
            port: 8443
          initialDelaySeconds: 30
          timeoutSeconds: 30
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            memory: 400Mi
      volumes:
      - name: tmp-volume
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dashboard-metrics-scraper
  namespace: kubernetes-dashboard
  labels:
    k8s-app: dashboard-metrics-scraper
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: dashboard-metrics-scraper
  template:
    metadata:
      labels:
        k8s-app: dashboard-metrics-scraper
    spec:
      serviceAccountName: kubernetes-dashboard
      containers:
      - name: dashboard-metrics-scraper
        image: kubernetesui/metrics-scraper:v1.0.9
        ports:
        - containerPort: 8000
          protocol: TCP
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "10.0.2.2"
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
        livenessProbe:
          httpGet:
            scheme: HTTP
            path: /
            port: 8000
          initialDelaySeconds: 30
          timeoutSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
spec:
  ports:
  - port: 443
    targetPort: 8443
  selector:
    k8s-app: kubernetes-dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: dashboard-metrics-scraper
  namespace: kubernetes-dashboard
spec:
  ports:
  - port: 8000
    targetPort: 8000
  selector:
    k8s-app: dashboard-metrics-scraper
EOF

log_ok

log_step "⏳" "Waiting for Dashboard rollout"
kubectl -n kubernetes-dashboard rollout status deployment/kubernetes-dashboard --timeout=120s >> "$_LOG_FILE" 2>&1
kubectl -n kubernetes-dashboard rollout status deployment/dashboard-metrics-scraper --timeout=60s >> "$_LOG_FILE" 2>&1
log_ok

log_step "🔑" "Generating access token"
TOKEN=$(kubectl -n kubernetes-dashboard get secret dashboard-admin-token -o jsonpath='{.data.token}' | base64 --decode)
log_ok

log_summary
log_info "kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443"
log_info "Then open: https://localhost:8443"
echo "" >&2
echo "  Token: $TOKEN" >&2
echo "" >&2
echo "$TOKEN" | pbcopy 2>/dev/null && log_info "Token copied to clipboard" || true
