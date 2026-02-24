# Kubernetes The Hardest Way

A fully automated, from-scratch Kubernetes cluster running on QEMU virtual machines with NixOS. This project takes Kelsey Hightower's original "Kubernetes The Hard Way" and pushes it further — every certificate is hand-generated, every component configured as a bare systemd service, and the entire thing runs on your laptop without touching a cloud provider.

The twist? It's actually reproducible. One command rebuilds everything from zero.

## Why This Exists

Most Kubernetes tutorials either hand you a managed cluster or stop at `kubeadm init`. This project strips away every abstraction:

- No kubeadm. No Kubespray. No managed anything.
- The control plane runs as raw systemd services — not pods.
- PKI is generated with cfssl. Every certificate and kubeconfig is explicit.
- Networking uses Cilium, deployed after the cluster is already running.
- NixOS makes the entire system configuration declarative and reproducible.

If you want to understand how Kubernetes actually works at the syscall level, this is the project.

## Cluster Topology

```
┌─────────────────────────────────────────────────────────┐
│                    Host Machine (macOS)                 │
│                                                         │
│   ┌────────────┐   ┌───────────┐   ┌───────────┐        │
│   │   alpha    │   │   sigma   │   │   gamma   │        │
│   │  Control   │   │  Worker   │   │  Worker   │        │
│   │   Plane    │   │           │   │           │        │
│   │            │   │           │   │           │        │
│   │ etcd       │   │ kubelet   │   │ kubelet   │        │
│   │ apiserver  │   │ containerd│   │ containerd│        │
│   │ scheduler  │   │ cilium    │   │ cilium    │        │
│   │ ctrl-mgr   │   │           │   │           │        │
│   │            │   │           │   │           │        │
│   │ SSH: 2222  │   │ SSH: 2223 │   │ SSH: 2224 │        │
│   │ API: 6443  │   │           │   │           │        │
│   └────────────┘   └───────────┘   └───────────┘        │
│       NixOS            NixOS            NixOS           │
│       QEMU             QEMU             QEMU            │
└─────────────────────────────────────────────────────────┘
```

| Node | Role | RAM | SSH | Notes |
|------|------|-----|-----|-------|
| alpha | Control Plane | 8 GB | `localhost:2222` | etcd, API server, scheduler, controller-manager |
| sigma | Worker | 8 GB | `localhost:2223` | kubelet, containerd, Cilium agent |
| gamma | Worker | 8 GB | `localhost:2224` | kubelet, containerd, Cilium agent |

## Prerequisites

You need four tools installed on the host:

```bash
brew install qemu kubectl expect curl
```

QEMU must include UEFI firmware (included automatically with Homebrew on Apple Silicon).

## Quick Start

The entire cluster — from downloading NixOS to running pods — is one command:

```bash
make all
```

This runs `bootstrap-cluster.sh`, which:
1. Downloads the NixOS minimal ISO (if not cached)
2. Generates all PKI assets (CA, node certs, kubeconfigs, encryption config)
3. Stages NixOS configurations per node
4. Installs NixOS on three VMs **in parallel** via expect-automated Live CD
5. Boots all three nodes in the background

Once it finishes, follow the remaining steps:

```bash
make wait       # Live dashboard — watch until all components show Active
make network    # Install Cilium CNI + RBAC for kubelet API access
make smoke      # Deploy nginx, verify pods are running
```

Then interact with the cluster:

```bash
export KUBECONFIG=configs/admin.kubeconfig
kubectl get nodes
kubectl get pods -A
```

## Day-Two Operations

### Snapshot & Restore

After you have a working cluster, save it:

```bash
make snapshot    # Takes ~2 seconds
```

Later, reset the cluster to that saved state instantly:

```bash
make restore     # ~30 seconds (vs ~15 minutes for full rebuild)
```

This is the fastest way to iterate — break something, restore, try again.

### Push Config Changes Without Reinstalling

Changed a kubelet flag or updated a certificate? Don't rebuild:

```bash
make reconfig    # SSH into each node, push new configs, restart services
```

### SSH Access

```bash
make ssh-alpha   # Control plane
make ssh-sigma   # Worker 1
make ssh-gamma   # Worker 2
```

### Full Reset

```bash
make clean       # Remove generated certs, configs, ISOs
make clobber     # Also delete disk images — true clean slate
```

## Smart Defaults & Optimizations

The build system is designed to avoid unnecessary work:

- **Idempotent PKI**: `make pki` skips regeneration if certs already exist. Pass `--force` to override.
- **Smart bootstrap**: `make all` detects existing disk images and skips the install phase — just reboots.
- **Parallel installation**: All three nodes install simultaneously, cutting build time by ~3x.

## Configuration

All cluster parameters live in `cluster.env`:

```bash
CONTROL_PLANE_MEM=8192     # RAM per node (MB)
WORKER_MEM=8192
K8S_SERVICE_CIDR=10.32.0.0/24
K8S_POD_CIDR=10.200.0.0/16
CILIUM_VERSION=1.16.5
```

Edit this file and rebuild. The scripts read everything from here — no values are hardcoded in the shell scripts.

## Project Layout

```
├── Makefile                    Orchestration layer
├── cluster.env                 All tunable parameters
├── configs/
│   └── nixos-base.nix          Shared NixOS configuration
├── bin/
│   ├── bootstrap-cluster.sh    Full lifecycle: clean → install → boot
│   ├── provision.sh            QEMU VM management (install + boot + retry)
│   ├── generate-certs.sh       PKI certificate generation (cfssl)
│   ├── generate-kubeconfigs.sh Kubeconfig generation for all components
│   ├── generate-nocloud-iso.sh NixOS configuration staging per node
│   ├── install-cilium.sh       Cilium CNI + RBAC + node labels
│   ├── deploy-coredns.sh       CoreDNS for cluster DNS (10.32.0.10)
│   ├── deploy-metrics-server.sh Metrics Server for kubectl top
│   ├── wait-for-cluster.sh     Live boot dashboard
│   ├── cluster-status.sh       Health status overview
│   ├── check-prereqs.sh        Dependency validation
│   ├── shutdown.sh             Graceful node shutdown
│   ├── snapshot.sh             Save QCOW2 snapshots
│   ├── restore.sh              Restore and reboot from snapshots
│   ├── reconfig.sh             Push config changes via SSH
│   └── etcd-backup.sh          etcd snapshot and restore
└── docs/
    ├── architecture.md         System architecture deep dive
    ├── technical-choices.md    Why NixOS, QEMU, Cilium, and everything else
    └── proxy-configuration.md  Corporate proxy setup guide
```

## Documentation

For deeper reading on how this all fits together:

- **[Architecture](docs/architecture.md)** — How the cluster is assembled, the boot sequence, networking model, and PKI trust chain.
- **[Technical Choices](docs/technical-choices.md)** — The reasoning behind NixOS, QEMU user-mode networking, Cilium, cfssl, and the rest of the stack.
- **[Proxy Configuration](docs/proxy-configuration.md)** — Running the cluster behind a corporate HTTP proxy, including TLS interception.

## Targets Reference

Run `make help` for the full list:

```
  check             Verify prerequisites (QEMU, kubectl, expect, firmware)
  all               Full build: prereqs + PKI + install + boot
  up                Boot all installed nodes
  down              Gracefully shut down all nodes
  wait              Live dashboard — monitor cluster readiness
  status            Comprehensive cluster health status
  network           Install Cilium CNI + RBAC + node labels
  dns               Deploy CoreDNS for cluster DNS (10.32.0.10)
  metrics           Deploy Metrics Server (kubectl top)
  smoke             Deploy nginx and verify pod networking
  snapshot          Save cluster state for instant restore
  restore           Restore from snapshot (~30s vs ~15min rebuild)
  reconfig          Push config changes to running nodes
  etcd-snapshot     Create etcd data backup (saved to backups/)
  etcd-restore      Restore etcd from latest backup
  ssh-alpha/sigma/gamma  SSH into nodes
  clean             Remove generated artifacts
  clobber           Destroy everything including disks
```

## License

Educational project. Use it to learn. Break it. Rebuild it. That's the point.
