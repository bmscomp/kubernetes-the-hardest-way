#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

echo "Deploying Prometheus + Grafana monitoring stack..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/proxy", "nodes/metrics", "services", "endpoints", "pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
- kind: ServiceAccount
  name: prometheus
  namespace: monitoring
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    scrape_configs:
    - job_name: 'kubernetes-apiservers'
      kubernetes_sd_configs:
      - role: endpoints
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: default;kubernetes;https

    - job_name: 'kubernetes-nodes'
      kubernetes_sd_configs:
      - role: node
      scheme: https
      tls_config:
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)

    - job_name: 'kubernetes-cadvisor'
      kubernetes_sd_configs:
      - role: node
      scheme: https
      tls_config:
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      metrics_path: /metrics/cadvisor
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)

    - job_name: 'kubernetes-pods'
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: \\\$1:\\\$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name

    - job_name: 'coredns'
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_pod_label_k8s_app]
        action: keep
        regex: kube-system;kube-dns
      - source_labels: [__address__]
        action: replace
        regex: ([^:]+)(?::\d+)?
        replacement: \\\$1:9153
        target_label: __address__
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
  labels:
    app: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
      - name: prometheus
        image: prom/prometheus:v2.51.2
        args:
        - --config.file=/etc/prometheus/prometheus.yml
        - --storage.tsdb.path=/prometheus
        - --storage.tsdb.retention.time=7d
        - --web.enable-lifecycle
        ports:
        - containerPort: 9090
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "10.0.2.2"
        - name: KUBERNETES_SERVICE_PORT
          value: "6443"
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        - name: data
          mountPath: /prometheus
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            memory: 1Gi
      volumes:
      - name: config
        configMap:
          name: prometheus-config
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
spec:
  ports:
  - port: 9090
    targetPort: 9090
  selector:
    app: prometheus
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      access: proxy
      url: http://prometheus:9090
      isDefault: true
  dashboards.yaml: |
    apiVersion: 1
    providers:
    - name: 'default'
      folder: ''
      type: file
      options:
        path: /var/lib/grafana/dashboards
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: monitoring
data:
  kubernetes-cluster.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "links": [],
      "panels": [
        {
          "title": "CPU Usage by Node",
          "type": "timeseries",
          "datasource": "Prometheus",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
          "targets": [{
            "expr": "sum(rate(container_cpu_usage_seconds_total{image!=\"\"}[5m])) by (node)",
            "legendFormat": "{{ node }}"
          }]
        },
        {
          "title": "Memory Usage by Node",
          "type": "timeseries",
          "datasource": "Prometheus",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
          "targets": [{
            "expr": "sum(container_memory_working_set_bytes{image!=\"\"}) by (node) / 1024 / 1024 / 1024",
            "legendFormat": "{{ node }} (GB)"
          }]
        },
        {
          "title": "Pods by Namespace",
          "type": "bargauge",
          "datasource": "Prometheus",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
          "targets": [{
            "expr": "count(kube_pod_info) by (namespace)",
            "legendFormat": "{{ namespace }}"
          }]
        },
        {
          "title": "Network Traffic by Pod",
          "type": "timeseries",
          "datasource": "Prometheus",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
          "targets": [{
            "expr": "sum(rate(container_network_receive_bytes_total[5m])) by (pod) / 1024",
            "legendFormat": "{{ pod }} (KB/s)"
          }]
        }
      ],
      "schemaVersion": 39,
      "time": { "from": "now-1h", "to": "now" },
      "title": "Kubernetes Cluster Overview",
      "uid": "k8s-cluster-overview"
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
  labels:
    app: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:11.4.0
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "kubernetes"
        - name: GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH
          value: "/var/lib/grafana/dashboards/kubernetes-cluster.json"
        volumeMounts:
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
          subPath: datasources.yaml
        - name: datasources
          mountPath: /etc/grafana/provisioning/dashboards
          subPath: dashboards.yaml
        - name: dashboards
          mountPath: /var/lib/grafana/dashboards
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
      volumes:
      - name: datasources
        configMap:
          name: grafana-datasources
      - name: dashboards
        configMap:
          name: grafana-dashboards
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: monitoring
spec:
  ports:
  - port: 3000
    targetPort: 3000
  selector:
    app: grafana
EOF

echo "Waiting for Prometheus rollout..."
kubectl -n monitoring rollout status deployment/prometheus --timeout=120s

echo "Waiting for Grafana rollout..."
kubectl -n monitoring rollout status deployment/grafana --timeout=120s

echo ""
echo "======================================================================="
echo -e " \e[32m✔ Monitoring stack deployed!\e[0m"
echo "======================================================================="
echo ""
echo "  Prometheus:"
echo "    kubectl -n monitoring port-forward svc/prometheus 9090:9090"
echo "    Then open: http://localhost:9090"
echo ""
echo "  Grafana:"
echo "    kubectl -n monitoring port-forward svc/grafana 3000:3000"
echo "    Then open: http://localhost:3000"
echo "    Login: admin / kubernetes"
echo ""
echo "  Pre-installed dashboard: Kubernetes Cluster Overview"
