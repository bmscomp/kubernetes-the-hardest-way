#!/usr/bin/env bash
set -eo pipefail

TLS_DIR="../tls"
mkdir -p "$TLS_DIR"

if [ -f "$TLS_DIR/ca.pem" ] && [ "$1" != "--force" ]; then
  echo "PKI certs already exist in $TLS_DIR — skipping. Use --force to regenerate."
  exit 0
fi

cd "$TLS_DIR"

echo "Downloading cfssl tools if missing..."
if ! command -v cfssl &> /dev/null; then
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then ARCH="arm64"; fi
  
  CFSSL_VERSION="1.6.5"
  CFSSL_URL="https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}"
  
  echo "Downloading cfssl v${CFSSL_VERSION} for ${OS}/${ARCH}..."
  curl -sL "${CFSSL_URL}/cfssl_${CFSSL_VERSION}_${OS}_${ARCH}" -o cfssl
  curl -sL "${CFSSL_URL}/cfssljson_${CFSSL_VERSION}_${OS}_${ARCH}" -o cfssljson
  
  chmod +x cfssl cfssljson
  export PATH=$PATH:$(pwd)
fi

echo "Generating Certificate Authority..."
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

echo "Generating Admin Client Certificate..."
cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hardest Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

echo "Generating Kubelet Certificates (simulated for node sigma gamma)..."
for instance in sigma gamma; do
cat > ${instance}-csr.json <<EOF
{
  "CN": "system:node:${instance}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hardest Way",
      "ST": "Oregon"
    }
  ]
}
EOF

# Note: In a real environment, you'd add the node's external IP to -hostname
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${instance} \
  -profile=kubernetes \
  ${instance}-csr.json | cfssljson -bare ${instance}
done

echo "Generating kube-controller-manager Certificate..."
cat > kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hardest Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

echo "Generating kube-proxy Certificate..."
cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxies",
      "OU": "Kubernetes The Hardest Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy

echo "Generating kube-scheduler Certificate..."
cat > kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hardest Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler


echo "Generating Kubernetes API Server Certificate..."
cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hardest Way",
      "ST": "Oregon"
    }
  ]
}
EOF

# KUBERNETES_PUBLIC_ADDRESS should ideally be the IP of the master node
# 10.32.0.1 is the default cluster IP for the kubernetes service
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=10.32.0.1,192.168.100.10,10.0.2.2,127.0.0.1,kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

echo "Generating Service Account Key Pair..."
cat > service-account-csr.json <<EOF
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hardest Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  service-account-csr.json | cfssljson -bare service-account

echo "Certificates generated successfully in $(pwd)"
