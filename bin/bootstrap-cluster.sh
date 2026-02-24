#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

echo "======================================================================="
echo " Kubernetes The Hardest Way — Full Cluster Bootstrap"
echo "======================================================================="
echo ""

step() {
  local step_num=$1; shift
  echo -e "\n\e[36m[$step_num]\e[0m $*"
  echo "-----------------------------------------------------------------------"
}

step "1/7" "Killing any existing QEMU processes..."
killall qemu-system-aarch64 qemu-system-x86_64 2>/dev/null || true
sleep 1

DISKS_EXIST=true
for node in $ALL_NODES; do
  [ -f "$PROJECT_DIR/images/$node.qcow2" ] || DISKS_EXIST=false
done

if [ "$DISKS_EXIST" = true ]; then
  echo -e "\e[33m  Disk images found — skipping install, will reboot existing VMs.\e[0m"
  echo "  (Use 'make clobber && make all' for a full reinstall)"
else
  step "2/7" "Cleaning generated artifacts (preserving downloaded ISOs)..."
  rm -rf "$PROJECT_DIR/tls" "$PROJECT_DIR/cloud-init"
  find "$PROJECT_DIR/configs" -type f ! -name "nixos-base.nix" -delete 2>/dev/null || true
  rm -f "$PROJECT_DIR/images"/*-seed.iso "$PROJECT_DIR/images"/*.qcow2
fi

step "3/7" "Generating PKI certificates, kubeconfigs, and encryption config..."
"$SCRIPT_DIR/generate-certs.sh"
"$SCRIPT_DIR/generate-kubeconfigs.sh"
"$SCRIPT_DIR/generate-encryption-config.sh"

step "4/7" "Generating seed ISOs for all nodes..."
"$SCRIPT_DIR/generate-nocloud-iso.sh" alpha
"$SCRIPT_DIR/generate-nocloud-iso.sh" sigma
"$SCRIPT_DIR/generate-nocloud-iso.sh" gamma

if [ "$DISKS_EXIST" = false ]; then
  step "5/7" "Installing NixOS on all nodes (parallel, ~10 min)..."
  "$SCRIPT_DIR/provision.sh" --iso alpha control-plane "$CONTROL_PLANE_MEM" "$MAC_alpha" "$SSH_PORTS_alpha" &
  PID_ALPHA=$!
  sleep 2
  "$SCRIPT_DIR/provision.sh" --iso sigma worker "$WORKER_MEM" "$MAC_sigma" "$SSH_PORTS_sigma" &
  PID_SIGMA=$!
  sleep 2
  "$SCRIPT_DIR/provision.sh" --iso gamma worker "$WORKER_MEM" "$MAC_gamma" "$SSH_PORTS_gamma" &
  PID_GAMMA=$!

  echo "  Waiting for all three installations..."
  echo "  alpha=$PID_ALPHA  sigma=$PID_SIGMA  gamma=$PID_GAMMA"

  FAILED=0
  wait $PID_ALPHA || { echo "  alpha installation failed!"; FAILED=1; }
  wait $PID_SIGMA || { echo "  sigma installation failed!"; FAILED=1; }
  wait $PID_GAMMA || { echo "  gamma installation failed!"; FAILED=1; }

  if [ "$FAILED" -ne 0 ]; then
    echo -e "\e[31m  One or more installations failed. Aborting.\e[0m"
    exit 1
  fi
  echo -e "\e[32m  All nodes installed successfully.\e[0m"
fi

step "6/6" "Booting all installed nodes..."
"$SCRIPT_DIR/provision.sh" alpha control-plane "$CONTROL_PLANE_MEM" "$MAC_alpha" "$SSH_PORTS_alpha" &
PID_ALPHA=$!
sleep 1
"$SCRIPT_DIR/provision.sh" sigma worker "$WORKER_MEM" "$MAC_sigma" "$SSH_PORTS_sigma" &
PID_SIGMA=$!
sleep 1
"$SCRIPT_DIR/provision.sh" gamma worker "$WORKER_MEM" "$MAC_gamma" "$SSH_PORTS_gamma" &
PID_GAMMA=$!

echo "  Nodes booting in background ($PID_ALPHA, $PID_SIGMA, $PID_GAMMA)"

echo ""
echo "======================================================================="
echo -e " \e[32m✔ All nodes installed and booting!\e[0m"
echo "======================================================================="
echo ""
echo "  Next steps:"
echo "    make wait       # Live dashboard to monitor cluster readiness"
echo "    make network    # Install Cilium CNI"
echo "    make smoke      # Verify with nginx deployment"
echo ""
echo "  export KUBECONFIG=$PROJECT_DIR/configs/admin.kubeconfig"
echo ""

