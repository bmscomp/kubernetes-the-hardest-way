#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_DIR/cluster.env"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -q"
SSH_PORT=${SSH_PORTS_alpha}

ACTION="${1:-snapshot}"
SNAPSHOT_NAME="${2:-etcd-backup}"
BACKUP_DIR="$PROJECT_DIR/backups"
mkdir -p "$BACKUP_DIR"

case "$ACTION" in
  snapshot)
    echo "Creating etcd snapshot on alpha..."
    ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 \
      "ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-snapshot.db \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/var/lib/kubernetes/pki/ca.pem \
        --cert=/var/lib/kubernetes/pki/kubernetes.pem \
        --key=/var/lib/kubernetes/pki/kubernetes-key.pem"

    scp $SSH_OPTS -P "$SSH_PORT" \
      "root@127.0.0.1:/tmp/etcd-snapshot.db" \
      "$BACKUP_DIR/$SNAPSHOT_NAME-$(date +%Y%m%d-%H%M%S).db"

    echo "  ✔ Snapshot saved to $BACKUP_DIR/"
    ls -lh "$BACKUP_DIR"/*.db | tail -3
    ;;

  restore)
    LATEST=$(ls -t "$BACKUP_DIR"/*.db 2>/dev/null | head -1)
    if [ -z "$LATEST" ]; then
      echo "No etcd backups found in $BACKUP_DIR/"
      exit 1
    fi

    echo "Restoring etcd from: $LATEST"
    echo "WARNING: This will stop etcd, restore the snapshot, and restart."
    echo ""

    scp $SSH_OPTS -P "$SSH_PORT" \
      "$LATEST" "root@127.0.0.1:/tmp/etcd-restore.db"

    ssh $SSH_OPTS -p "$SSH_PORT" root@127.0.0.1 "
      systemctl stop kube-apiserver kube-controller-manager kube-scheduler etcd
      rm -rf /var/lib/etcd/member
      ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-restore.db \
        --data-dir=/var/lib/etcd \
        --name=alpha \
        --initial-cluster=alpha=https://127.0.0.1:2380 \
        --initial-advertise-peer-urls=https://127.0.0.1:2380
      systemctl start etcd
      sleep 3
      systemctl start kube-apiserver kube-controller-manager kube-scheduler
    "

    echo "  ✔ etcd restored and control plane restarted"
    ;;

  *)
    echo "Usage: $0 [snapshot|restore] [name]"
    exit 1
    ;;
esac
