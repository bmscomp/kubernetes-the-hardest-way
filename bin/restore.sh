#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

SNAPSHOT_NAME="${1:-working}"
IMAGE_DIR="$PROJECT_DIR/images"

echo "Killing any running QEMU instances..."
killall qemu-system-aarch64 qemu-system-x86_64 2>/dev/null || true
sleep 1

echo "Restoring all QCOW2 images from snapshot '$SNAPSHOT_NAME'..."

for node in $ALL_NODES; do
  DISK="$IMAGE_DIR/$node.qcow2"
  if [ -f "$DISK" ]; then
    qemu-img snapshot -a "$SNAPSHOT_NAME" "$DISK"
    echo "  ✔ $node"
  else
    echo "  ✘ $node — disk not found"
    exit 1
  fi
done

EFIVARS_BACKUP="$IMAGE_DIR/efivars-snapshot-$SNAPSHOT_NAME"
if [ -d "$EFIVARS_BACKUP" ]; then
  for node in $ALL_NODES; do
    if [ -f "$EFIVARS_BACKUP/${node}-efivars.fd" ]; then
      cp "$EFIVARS_BACKUP/${node}-efivars.fd" "$IMAGE_DIR/"
    fi
  done
fi

echo ""
echo "Snapshot '$SNAPSHOT_NAME' restored. Booting cluster..."
echo ""

"$SCRIPT_DIR/provision.sh" alpha control-plane "$CONTROL_PLANE_MEM" "$MAC_alpha" "$SSH_PORTS_alpha" &
sleep 1
"$SCRIPT_DIR/provision.sh" sigma worker "$WORKER_MEM" "$MAC_sigma" "$SSH_PORTS_sigma" &
sleep 1
"$SCRIPT_DIR/provision.sh" gamma worker "$WORKER_MEM" "$MAC_gamma" "$SSH_PORTS_gamma" &

echo "All nodes booting from snapshot. Run 'make wait' to monitor."
