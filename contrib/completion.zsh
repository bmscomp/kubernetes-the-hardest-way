#compdef make

_kthw_targets() {
  local targets=(
    'help:Show this help message'
    'check:Verify prerequisites (QEMU, kubectl, expect, firmware)'
    'all:Full build - prereqs + PKI + install + boot + network + DNS'
    'download:Download the minimal NixOS base image'
    'pki:Generate all PKI assets'
    'prepare:Generate all PKI assets and stage all node configs'
    'install:Install NixOS on all nodes sequentially'
    'install-alpha:Install NixOS on alpha via Live CD'
    'install-sigma:Install NixOS on sigma via Live CD'
    'install-gamma:Install NixOS on gamma via Live CD'
    'up:Boot all installed nodes'
    'down:Gracefully shut down all nodes'
    'wait:Live dashboard - monitor cluster readiness'
    'status:Comprehensive cluster health status'
    'network:Install Cilium CNI + RBAC + node labels + endpoint fix'
    'dns:Deploy CoreDNS for cluster DNS'
    'metrics:Deploy Metrics Server'
    'storage:Deploy local-path-provisioner for PVCs'
    'smoke:Deploy nginx and verify pod networking'
    'test:Run the full cluster test suite'
    'snapshot:Save cluster state for instant restore'
    'restore:Restore from snapshot'
    'reconfig:Push config changes to running nodes'
    'etcd-snapshot:Create etcd data backup'
    'etcd-restore:Restore etcd from latest backup'
    'ssh-alpha:SSH into the Alpha control plane'
    'ssh-sigma:SSH into the Sigma worker'
    'ssh-gamma:SSH into the Gamma worker'
    'clean:Remove generated artifacts'
    'clobber:Destroy everything including disks'
  )
  _describe 'target' targets
}

# Only activate in the kubernetes-the-hardest-way directory
if [[ -f "cluster.env" && -f "Makefile" ]]; then
  compdef _kthw_targets make
fi
