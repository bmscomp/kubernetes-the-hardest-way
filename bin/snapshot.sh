#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

SNAPSHOT_NAME="${1:-working}"
IMAGE_DIR="$PROJECT_DIR/images"

echo "Snapshotting all QCOW2 images as '$SNAPSHOT_NAME'..."

for node in $ALL_NODES; do
  DISK="$IMAGE_DIR/$node.qcow2"
  if [ -f "$DISK" ]; then
    qemu-img snapshot -c "$SNAPSHOT_NAME" "$DISK"
    echo "  ✔ $node"
  else
    echo "  ✘ $node — disk not found"
  fi
done

EFIVARS_BACKUP="$IMAGE_DIR/efivars-snapshot-$SNAPSHOT_NAME"
mkdir -p "$EFIVARS_BACKUP"
for node in $ALL_NODES; do
  if [ -f "$IMAGE_DIR/${node}-efivars.fd" ]; then
    cp "$IMAGE_DIR/${node}-efivars.fd" "$EFIVARS_BACKUP/"
  fi
done

echo ""
echo "Snapshot '$SNAPSHOT_NAME' created. Restore with: make restore"
