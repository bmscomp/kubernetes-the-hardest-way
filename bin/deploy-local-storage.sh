#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/cluster.env"
source "$PROJECT_DIR/lib/log.sh"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

log_step "💾" "Applying local-path-provisioner manifests"

NODE_PATH_ENTRIES=""
for node in $ALL_NODES; do
  NODE_PATH_ENTRIES="${NODE_PATH_ENTRIES}{\"node\":\"${node}\",\"paths\":[\"/opt/local-path-provisioner\"]},"
done

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-service-account
  namespace: local-path-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
- apiGroups: [""]
  resources: ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "watch", "create", "patch", "update", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
- kind: ServiceAccount
  name: local-path-provisioner-service-account
  namespace: local-path-storage
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |-
    {
      "nodePathMap":[
        ${NODE_PATH_ENTRIES}
        {"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/opt/local-path-provisioner"]}
      ]
    }
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
      - name: helper-pod
        image: busybox:1.36
        imagePullPolicy: IfNotPresent
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-path-provisioner
  template:
    metadata:
      labels:
        app: local-path-provisioner
    spec:
      serviceAccountName: local-path-provisioner-service-account
      containers:
      - name: local-path-provisioner
        image: rancher/local-path-provisioner:v${LOCAL_PATH_VERSION:-0.0.34}
        command:
        - local-path-provisioner
        - --debug
        - start
        - --config
        - /etc/config/config.json
        volumeMounts:
        - name: config-volume
          mountPath: /etc/config/
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: KUBERNETES_SERVICE_HOST
          value: "10.0.2.2"
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
      volumes:
      - name: config-volume
        configMap:
          name: local-path-config
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF
log_ok

log_step "💾" "Creating per-node StorageClasses"
for node in $ALL_NODES; do
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-${node}
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowedTopologies:
- matchLabelExpressions:
  - key: kubernetes.io/hostname
    values:
    - ${node}
EOF
done
log_ok

log_step "⏳" "Waiting for provisioner rollout"
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=120s >> "$_LOG_FILE" 2>&1 && log_ok || { log_fail; exit 1; }

log_summary
log_info "StorageClasses available:"
log_info "  local-path          (default, any node)"
for node in $ALL_NODES; do
  log_info "  local-path-${node}    (pinned to ${node})"
done
