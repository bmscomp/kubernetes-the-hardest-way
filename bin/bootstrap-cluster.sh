#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"
source "$PROJECT_DIR/lib/log.sh"

log_header "☸  Kubernetes The Hardest Way"

log_step_run "🧹" "Stopping existing QEMU processes" \
  bash -c "killall qemu-system-aarch64 qemu-system-x86_64 2>/dev/null; sleep 1; true"

DISKS_EXIST=true
for node in $ALL_NODES; do
  [ -f "$PROJECT_DIR/images/$node.qcow2" ] || DISKS_EXIST=false
done

if [ "$DISKS_EXIST" = true ]; then
  log_info "Disk images found — will reboot existing VMs"
else
  log_step_run "🗑️ " "Cleaning generated artifacts" \
    bash -c "rm -rf '$PROJECT_DIR/tls' '$PROJECT_DIR/cloud-init'; find '$PROJECT_DIR/configs' -type f ! -name 'nixos-base.nix' -delete 2>/dev/null; rm -f '$PROJECT_DIR/images'/*-seed.iso '$PROJECT_DIR/images'/*.qcow2; true"
fi

log_step_run "🔧" "Generating PKI certificates" \
  "$SCRIPT_DIR/generate-certs.sh"

log_step_run "📦" "Generating kubeconfigs" \
  "$SCRIPT_DIR/generate-kubeconfigs.sh"

log_step_run "🔐" "Generating encryption config" \
  "$SCRIPT_DIR/generate-encryption-config.sh"

log_step "💿" "Staging NixOS configurations"
"$SCRIPT_DIR/generate-nocloud-iso.sh" alpha >> "$_LOG_FILE" 2>&1
for worker in $WORKER_NAMES; do
  "$SCRIPT_DIR/generate-nocloud-iso.sh" "$worker" >> "$_LOG_FILE" 2>&1
done
log_ok

if [ "$DISKS_EXIST" = false ]; then
  log_step "🖥️ " "Installing NixOS on all nodes (parallel)"
  "$SCRIPT_DIR/provision.sh" --iso alpha control-plane "$CONTROL_PLANE_MEM" "$MAC_alpha" "$SSH_PORTS_alpha" >> "$_LOG_FILE" 2>&1 &
  PID_ALPHA=$!
  sleep 2

  PIDS=()
  for worker in $WORKER_NAMES; do
    SSH_PORT_VAR="SSH_PORTS_${worker}"
    MAC_VAR="MAC_${worker}"
    "$SCRIPT_DIR/provision.sh" --iso "$worker" worker "$WORKER_MEM" "${!MAC_VAR}" "${!SSH_PORT_VAR}" >> "$_LOG_FILE" 2>&1 &
    PIDS+=($!)
    sleep 2
  done

  FAILED=0
  wait $PID_ALPHA || FAILED=1
  for pid in "${PIDS[@]}"; do
    wait "$pid" || FAILED=1
  done

  if [ "$FAILED" -ne 0 ]; then
    log_fail
    log_summary
    exit 1
  fi
  log_ok
fi

log_step "🚀" "Booting all nodes"
"$SCRIPT_DIR/provision.sh" alpha control-plane "$CONTROL_PLANE_MEM" "$MAC_alpha" "$SSH_PORTS_alpha" >> "$_LOG_FILE" 2>&1 &
sleep 1
for worker in $WORKER_NAMES; do
  SSH_PORT_VAR="SSH_PORTS_${worker}"
  MAC_VAR="MAC_${worker}"
  "$SCRIPT_DIR/provision.sh" "$worker" worker "$WORKER_MEM" "${!MAC_VAR}" "${!SSH_PORT_VAR}" >> "$_LOG_FILE" 2>&1 &
  sleep 1
done
log_ok

log_step "⏳" "Waiting for cluster readiness"
"$SCRIPT_DIR/wait-for-cluster.sh" >> "$_LOG_FILE" 2>&1 && log_ok || { log_fail; log_summary; exit 1; }

export KUBECONFIG="$PROJECT_DIR/configs/admin.kubeconfig"

log_step_run "🌐" "Installing Cilium CNI + RBAC + node labels" \
  "$SCRIPT_DIR/install-cilium.sh"

log_step "⏳" "Waiting for nodes to become Ready"
for i in $(seq 1 60); do
  kubectl get nodes 2>/dev/null | grep -q "Ready" && break
  sleep 5
done
kubectl get nodes 2>/dev/null | grep -q "Ready" && log_ok || { log_fail; log_summary; exit 1; }

log_step_run "📡" "Deploying CoreDNS" \
  "$SCRIPT_DIR/deploy-coredns.sh"

log_summary

log_info "export KUBECONFIG=$PROJECT_DIR/configs/admin.kubeconfig"
echo "" >&2
