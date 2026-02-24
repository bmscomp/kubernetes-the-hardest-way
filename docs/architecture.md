# Architecture

This document walks through how the cluster is assembled — from a blank disk to a running pod — and explains the decisions at each layer.

## The Big Picture

The cluster is three QEMU virtual machines running NixOS. One VM (alpha) runs the Kubernetes control plane as systemd services. Two VMs (sigma, gamma) run kubelet and containerd as workers. There is no kubelet on the control plane. The control plane and data plane are completely separate processes on separate machines.

This is unusual. In production, the control plane components usually run as static pods managed by kubelet. Here, they are plain systemd units — just binaries with flags. This makes the architecture easier to reason about because there is no circular dependency: the control plane does not need a container runtime to start itself.

## Boot Sequence

When you run `make all`, here is what happens in order:

```
1. Download NixOS ISO          (download-iso.sh)
2. Generate PKI assets         (generate-certs.sh, generate-kubeconfigs.sh)
3. Stage NixOS configs         (generate-nocloud-iso.sh × 3 nodes)
4. Install NixOS in parallel   (provision.sh --iso × 3 nodes)
   ├─ Create QCOW2 disk image
   ├─ Boot from the NixOS Live CD inside QEMU
   ├─ Partition disk (GPT + ESP for UEFI)
   ├─ Format filesystems
   ├─ Write NixOS configuration to /mnt/etc/nixos
   ├─ Run nixos-install
   ├─ Write startup.nsh for UEFI boot
   └─ Power off
5. Boot all nodes              (provision.sh × 3 nodes, background)
   ├─ QEMU loads UEFI firmware
   ├─ startup.nsh → GRUB → NixOS
   ├─ systemd starts etcd, apiserver, scheduler, controller-manager (alpha)
   └─ systemd starts containerd, kubelet (sigma, gamma)
```

The expect-automated installation is the most fragile part. It drives a live NixOS session by sending keystrokes and waiting for shell prompts. This is intentional — it simulates exactly what a human would do with a physical machine, which is the educational point of the project.

## How Nodes Talk to Each Other

Each VM runs with QEMU user-mode networking. This gives every VM a private `10.0.2.x` subnet with:

- `10.0.2.2` — the host machine (gateway)
- `10.0.2.3` — DNS resolver
- `10.0.2.15` — the VM itself

VMs cannot talk to each other directly. They share no network. This is a deliberate constraint of QEMU user-mode networking — it requires no root privileges, no tap devices, and no bridge configuration.

So how does the cluster work?

**Workers → API server:** QEMU port-forwards `host:6443` to `alpha:6443`. Workers connect to `10.0.2.2:6443` (the gateway), which the host forwards to alpha's API server.

**API server → kubelet (for kubectl logs/exec):** Each worker has a unique kubelet port (sigma=10250, gamma=10251) forwarded through QEMU. Alpha's `/etc/hosts` maps `sigma` and `gamma` to `10.0.2.2`. When the API server needs to reach a kubelet, it resolves the hostname to the gateway, which forwards the request to the correct VM.

**Host → API server (kubectl):** The host connects directly to `localhost:6443`, which QEMU forwards to alpha.

```
kubectl (host)
    │
    ▼ localhost:6443
┌─────────── QEMU port-forwarding ───────────┐
│                                            │
▼                                            │
alpha:6443 (API server)                      │
    │                                        │
    │ sigma:10250 → resolves to 10.0.2.2     │
    │              → host forwards to sigma  │
    ▼                                        │
sigma:10250 (kubelet) ◄──────────────────────┘
```

## PKI Trust Chain

Every component in the cluster authenticates using mutual TLS. There is a single Certificate Authority, and every connection presents a client certificate signed by that CA.

```
CA (ca.pem, ca-key.pem)
├── kubernetes.pem         API server's serving cert + kubelet client cert
├── admin.pem              Human operator (CN=admin, O=system:masters)
├── sigma.pem              Sigma's kubelet cert (CN=system:node:sigma)
├── gamma.pem              Gamma's kubelet cert (CN=system:node:gamma)
├── kube-controller-manager.pem
├── kube-scheduler.pem
├── kube-proxy.pem
├── service-account.pem    Used to sign service account tokens
└── encryption-config.yaml Symmetric key for etcd encryption at rest
```

The API server's certificate (`kubernetes.pem`) includes all the SANs it needs to be reachable:
- `10.32.0.1` — the Kubernetes service VIP
- `192.168.100.10` — reserved for future cluster networking
- `10.0.2.2` — the QEMU gateway (how workers reach it)
- `127.0.0.1` — loopback
- `kubernetes`, `kubernetes.default`, etc. — DNS names

Each kubelet registers with a certificate whose CN is `system:node:<hostname>` and Organization is `system:nodes`. This is what the Node authorizer expects — it will only permit kubelets to operate on their own node objects.

## RBAC Model

The cluster uses `--authorization-mode=Node,RBAC`. Two key bindings exist:

1. **system:masters group** — The admin kubeconfig's cert has `O=system:masters`. This is a built-in Kubernetes supergroup with full cluster access.

2. **kubelet-api-full** — A custom ClusterRole + ClusterRoleBinding that grants the `kubernetes` user and `Kubernetes` group permission to proxy to nodes. Without this, `kubectl logs` and `kubectl exec` fail because the API server can't proxy through to kubelet.

The second binding is subtle. The API server uses `--kubelet-client-certificate=kubernetes.pem` to authenticate to kubelets. That cert has `CN=kubernetes` and `O=Kubernetes`. When the API server proxies a request (like `kubectl logs`), Kubernetes checks whether that identity has permission to `create nodes/proxy`. The `kubelet-api-full` binding grants exactly that.

## NixOS Configuration Structure

Each node gets two NixOS configuration files:

**`configuration.nix`** — Shared base configuration:
- GRUB bootloader with UEFI support
- Filesystem mounts (root, boot, swap)
- Firewall disabled
- IP forwarding enabled
- SSH with root login
- Activation script that copies certs from `/etc/nixos/certs/` to `/var/lib/kubernetes/pki/`

**`node-config.nix`** — Node-specific configuration:
- For alpha: etcd, kube-apiserver, kube-controller-manager, kube-scheduler as systemd services, plus `/etc/hosts` entries mapping worker hostnames to the QEMU gateway
- For workers: containerd, kubelet, CNI plugin symlinks, containerd CNI path override

These files are generated by `generate-nocloud-iso.sh` using heredocs with bash variable expansion. The NixOS expressions (`${pkgs.kubernetes}`) are escaped so bash doesn't expand them — only NixOS evaluates them during `nixos-install`.

## Cilium Integration

Cilium replaces kube-proxy and implements pod networking. It is installed after the cluster is running using the `cilium` CLI.

Key configuration:
- `k8sServiceHost=10.0.2.2` — Cilium pods run on workers, which reach the API server via the QEMU gateway.
- `k8sServicePort=6443`

Cilium installs its CNI plugin (`cilium-cni`) to `/opt/cni/bin/`. The base NixOS CNI plugins live in the Nix store (an immutable path like `/nix/store/.../bin/`). An activation script symlinks them to `/opt/cni/bin/` so both stock plugins and Cilium's plugin are discoverable at the same path.

Containerd is configured to look for CNI plugins at `/opt/cni/bin/` to match.

## Snapshot Architecture

Snapshots use QCOW2's built-in snapshot feature. When you run `make snapshot`, it calls `qemu-img snapshot -c <name>` on each disk image. This is a copy-on-write operation — it marks the current block state as a frozen point without duplicating data. Restoring is equally fast: `qemu-img snapshot -a <name>` reverts the disk to that state.

UEFI variable files (`-efivars.fd`) are backed up separately since they are raw binary files outside the QCOW2 image.

This makes iterating incredibly fast. A full rebuild takes 10-15 minutes. A snapshot restore takes 30 seconds.
