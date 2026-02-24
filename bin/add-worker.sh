#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

WORKER_NAME="${1:-}"
if [ -z "$WORKER_NAME" ]; then
  echo "Usage: $0 <worker-name>"
  echo ""
  echo "Example: $0 delta"
  echo ""
  echo "This will:"
  echo "  1. Generate TLS certificates for the new worker"
  echo "  2. Generate a kubeconfig"
  echo "  3. Create NixOS configuration"
  echo "  4. Install NixOS on a new QEMU VM"
  echo "  5. Boot the VM and wait for it to join the cluster"
  exit 1
fi

if [ "$WORKER_NAME" = "$CONTROL_PLANE_NAME" ]; then
  echo "Error: '$WORKER_NAME' is the control plane name. Choose a different name."
  exit 1
fi

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

EXISTING_WORKERS=($WORKER_NAMES)
WORKER_INDEX=${#EXISTING_WORKERS[@]}

SSH_PORT_VAR="SSH_PORTS_${WORKER_NAME}"
SSH_PORT=${!SSH_PORT_VAR:-$((2223 + WORKER_INDEX))}

KUBELET_PORT_VAR="KUBELET_PORT_${WORKER_NAME}"
KUBELET_PORT=${!KUBELET_PORT_VAR:-$((10250 + WORKER_INDEX))}

MAC_VAR="MAC_${WORKER_NAME}"
LAST_OCTET=$((87 + WORKER_INDEX))
MAC_ADDRESS=${!MAC_VAR:-"52:54:00:12:34:$(printf '%02x' $LAST_OCTET)"}

echo "======================================================================="
echo " Adding Worker Node: $WORKER_NAME"
echo "======================================================================="
echo ""
echo "  SSH Port:      $SSH_PORT"
echo "  Kubelet Port:  $KUBELET_PORT"
echo "  MAC Address:   $MAC_ADDRESS"
echo "  Memory:        ${WORKER_MEM}MB"
echo ""

step() {
  local step_num=$1; shift
  echo -e "\n\e[36m[$step_num]\e[0m $*"
  echo "-----------------------------------------------------------------------"
}

TLS_DIR="$PROJECT_DIR/tls"
cd "$TLS_DIR"

if [ ! -f "ca.pem" ]; then
  echo "Error: CA certificate not found. Run 'make pki' first."
  exit 1
fi

export PATH=$PATH:$(pwd)

step "1/6" "Generating TLS certificate for $WORKER_NAME..."
if [ -f "${WORKER_NAME}.pem" ]; then
  echo "  Certificate already exists — skipping"
else
  cat > "${WORKER_NAME}-csr.json" <<CERTEOF
{
  "CN": "system:node:${WORKER_NAME}",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{
    "C": "US", "L": "Portland",
    "O": "system:nodes",
    "OU": "Kubernetes The Hardest Way",
    "ST": "Oregon"
  }]
}
CERTEOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname="${WORKER_NAME}" \
    -profile=kubernetes \
    "${WORKER_NAME}-csr.json" | cfssljson -bare "$WORKER_NAME"

  echo "  ✔ Certificate generated"
fi

step "2/6" "Generating kubeconfig for $WORKER_NAME..."
CONFIGS_DIR="$PROJECT_DIR/configs"
if [ -f "$CONFIGS_DIR/${WORKER_NAME}.kubeconfig" ]; then
  echo "  Kubeconfig already exists — skipping"
else
  kubectl config set-cluster kubernetes-the-hardest-way \
    --certificate-authority="$TLS_DIR/ca.pem" \
    --embed-certs=true \
    --server=https://10.0.2.2:6443 \
    --kubeconfig="$CONFIGS_DIR/${WORKER_NAME}.kubeconfig"

  kubectl config set-credentials "system:node:${WORKER_NAME}" \
    --client-certificate="$TLS_DIR/${WORKER_NAME}.pem" \
    --client-key="$TLS_DIR/${WORKER_NAME}-key.pem" \
    --embed-certs=true \
    --kubeconfig="$CONFIGS_DIR/${WORKER_NAME}.kubeconfig"

  kubectl config set-context default \
    --cluster=kubernetes-the-hardest-way \
    --user="system:node:${WORKER_NAME}" \
    --kubeconfig="$CONFIGS_DIR/${WORKER_NAME}.kubeconfig"

  kubectl config use-context default \
    --kubeconfig="$CONFIGS_DIR/${WORKER_NAME}.kubeconfig"

  echo "  ✔ Kubeconfig generated"
fi

step "3/6" "Generating NixOS configuration..."
export KUBELET_PORT_${WORKER_NAME}=$KUBELET_PORT
"$SCRIPT_DIR/generate-nocloud-iso.sh" "$WORKER_NAME"

step "4/6" "Installing NixOS on $WORKER_NAME..."
"$SCRIPT_DIR/provision.sh" --iso "$WORKER_NAME" worker "$WORKER_MEM" "$MAC_ADDRESS" "$SSH_PORT"

step "5/6" "Booting $WORKER_NAME..."
"$SCRIPT_DIR/provision.sh" "$WORKER_NAME" worker "$WORKER_MEM" "$MAC_ADDRESS" "$SSH_PORT" &
BOOT_PID=$!

step "6/6" "Waiting for $WORKER_NAME to join the cluster..."
echo "  Waiting for node to appear in kubectl..."
for i in $(seq 1 60); do
  if kubectl get node "$WORKER_NAME" &>/dev/null; then
    echo -e "\n  \e[32m✔ Worker '$WORKER_NAME' has joined the cluster!\e[0m"
    echo ""
    kubectl get nodes
    echo ""
    echo "  Add to cluster.env for persistence:"
    echo "    WORKER_NAMES=\"$WORKER_NAMES $WORKER_NAME\""
    echo "    ALL_NODES=\"$CONTROL_PLANE_NAME $WORKER_NAMES $WORKER_NAME\""
    echo "    SSH_PORTS_${WORKER_NAME}=$SSH_PORT"
    echo "    KUBELET_PORT_${WORKER_NAME}=$KUBELET_PORT"
    echo "    MAC_${WORKER_NAME}=$MAC_ADDRESS"
    exit 0
  fi
  sleep 5
done

echo "  ⚠ Node did not appear within 5 minutes. Check SSH:"
echo "    ssh -p $SSH_PORT root@127.0.0.1"
exit 1
