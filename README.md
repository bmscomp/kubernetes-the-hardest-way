# Kubernetes The Hardest Way

Deploy a Kubernetes cluster from scratch using QEMU virtual machines and NixOS — the educational "Hard Way" approach, taken to its logical extreme.

**Cluster Topology:**
| Node | Role | SSH Port | API Port |
|------|------|----------|----------|
| alpha | Control Plane | 2222 | 6443 |
| sigma | Worker | 2223 | — |
| gamma | Worker | 2224 | — |

## Prerequisites

- `qemu` (with UEFI firmware for Apple Silicon)
- `kubectl`
- `expect`
- `curl`

## Quick Start

### 1. Download the NixOS Base Image
```bash
make download
```

### 2. Generate All PKI Assets and Seed ISOs
```bash
make prepare
```

### 3. Install NixOS on Each Node
Open three separate terminals:

```bash
make install-alpha    # Terminal 1
make install-sigma    # Terminal 2
make install-gamma    # Terminal 3
```

The `expect` automation will partition the disk, install NixOS, inject the cluster configuration, and shut down each VM automatically.

### 4. Boot the Installed Cluster
After installation completes, boot the nodes:

```bash
make boot-alpha    # Terminal 1
make boot-sigma    # Terminal 2
make boot-gamma    # Terminal 3
```

### 5. Monitor Boot Progress
In a fourth terminal, watch the live dashboard:

```bash
make wait
```

### 6. Install Pod Networking
Once all components show **Active/Registered** on the dashboard:

```bash
make network
```

### 7. Verify the Cluster
```bash
export KUBECONFIG=configs/admin.kubeconfig
kubectl get nodes
```

### 8. Run the Smoke Test
```bash
make smoke
```

## SSH Access

```bash
make ssh-alpha   # Control plane
make ssh-sigma   # Worker 1
make ssh-gamma   # Worker 2
```

## Configuration

All cluster parameters are centralized in `cluster.env`. Edit this file to change node names, memory, IPs, or versions.

## Cleanup

```bash
make clean     # Remove generated certs, configs, ISOs
make clobber   # Also remove disk images (full reset)
```

Run `make help` to see all available targets.
