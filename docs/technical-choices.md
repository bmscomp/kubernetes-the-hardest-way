# Technical Choices

Every tool in this project was chosen for a specific reason. This document explains those choices — the trade-offs considered, the alternatives rejected, and the constraints that shaped the final design.

## NixOS Over Ubuntu/Debian

The obvious choice for a disposable VM is Ubuntu Server. It is well-documented, widely supported, and has the fastest path to a working system. We chose NixOS instead, for one reason: **declarative configuration**.

A NixOS system is defined entirely by its configuration files. Two machines with the same `configuration.nix` produce bit-identical systems. This means we can generate a node's complete configuration on the host, inject it via a tarball, and let `nixos-install` build the entire operating system around it. There is no imperative setup step — no `apt install`, no `systemctl enable`, no editing config files after the OS is installed.

The downside is real. NixOS has a steep learning curve, Nix expression syntax is unusual, and debugging build failures requires understanding the Nix store. For a project whose purpose is education, this adds complexity that has nothing to do with Kubernetes.

We accepted this trade-off because the alternative — a long sequence of `apt-get install && systemctl enable && cat > /etc/...` commands inside an expect script — is both fragile and hard to modify. NixOS lets us change the kubelet configuration in one place and have it take effect everywhere, reliably.

## QEMU User-Mode Networking Over Bridged/Tap

QEMU offers several networking modes:

| Mode | Root Required | VMs Can Talk | Internet Access |
|------|:---:|:---:|:---:|
| User-mode (`-netdev user`) | No | No | Yes |
| Tap/Bridge | Yes | Yes | Yes |
| vmnet-shared (macOS) | Entitlements | Yes | Yes |
| Socket multicast | No | In theory | No |

We chose **user-mode networking** because it requires zero host configuration. No bridges, no tap devices, no elevated privileges. You download QEMU, run the script, and it works. This matters because the project targets developers on their laptops, often running macOS where networking configuration is particularly restrictive.

The cost is significant: VMs cannot communicate directly. Each VM lives in an isolated `10.0.2.x` network. The API server cannot reach kubelet endpoints to proxy requests like `kubectl logs` or `kubectl exec`.

We work around this using **per-node port forwarding through the host**:
- sigma's kubelet listens on port 10250, forwarded via QEMU as `host:10250 → sigma:10250`
- gamma's kubelet listens on port 10251, forwarded via QEMU as `host:10251 → gamma:10251`
- Alpha's `/etc/hosts` maps sigma and gamma to `10.0.2.2` (the QEMU gateway, which is the host)

This is a hack. It works, but it would not scale beyond a handful of nodes. For a production setup, you would use bridged networking.

We attempted QEMU socket multicast networking during development. It should create a virtual L2 switch between VMs using UDP multicast on the host. On macOS, it does not work — ARP requests go unanswered and no L2 connectivity is established. We spent considerable time debugging this (adding `localaddr=127.0.0.1`, verifying NIC names, checking firewall rules) before concluding it is unreliable on macOS and reverting to user-mode.

## Cilium Over Flannel or Calico

Cilium was chosen because it is eBPF-based and replaces kube-proxy entirely, simplifying the networking stack. It also has an excellent CLI (`cilium status`, `cilium connectivity test`) that makes troubleshooting straightforward.

Flannel would have been a simpler choice — it is a pure overlay network with minimal configuration. But Cilium's ability to handle service proxying without iptables rules was attractive for a project that already has enough moving parts.

Calico would also work well but requires more configuration for the BGP peering that gives it its performance advantages. In a QEMU user-mode environment where there is no real L3 fabric, those advantages are irrelevant.

## cfssl Over OpenSSL or cert-manager

The PKI is generated using CloudFlare's `cfssl` toolchain. The alternative is raw `openssl` commands, which most "Kubernetes The Hard Way" guides use.

cfssl was chosen because it allows you to define certificate properties in JSON files and generate them in a single command. The equivalent OpenSSL workflow involves multiple commands per certificate (generate key, create CSR, sign CSR), each with its own set of flags. cfssl collapses this into:

```bash
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json \
  -profile=kubernetes node-csr.json | cfssljson -bare node
```

The JSON config also serves as documentation. You can look at `kubernetes-csr.json` and immediately see the SANs, key algorithm, and organization. With OpenSSL, this information is scattered across command flags and config files.

cert-manager was not considered — it runs inside Kubernetes and cannot bootstrap a cluster that does not exist yet.

## Expect-Automated Installation Over Cloud-Init or Pre-built Images

The installation is driven by `expect`, a tool that automates interactive terminal sessions. This is unusual. Most VM-based projects use cloud-init, Packer, or pre-built images.

We use expect because **it simulates exactly what a human operator would do**. The script boots the NixOS Live CD, logs in, runs `parted`, formats filesystems, copies configuration, and runs `nixos-install`. If you SSH into the VM yourself, you would type the same commands.

This is fragile by design. The expect script relies on specific shell prompts appearing at specific times. A NixOS update that changes the default shell prompt would break the automation. This is acceptable because:

1. The fragility is educational — it shows how thin the automation layer is.
2. NixOS's prompt has been stable for years.
3. The alternative (cloud-init) would hide the installation mechanics, which defeats the project's purpose.

Cloud-init was partially implemented (the project retains `generate-nocloud-iso.sh` naming) but we do not use the cloud-init protocol. Instead, the configuration is injected as a base64-encoded tarball piped through the expect session.

## UEFI Over BIOS Boot

On Apple Silicon (aarch64), UEFI is the only option — there is no legacy BIOS. The project uses UEFI across all architectures for consistency.

This introduces a complication: QEMU's UEFI firmware (OVMF/AAVMF) uses NVRAM variables stored in a separate file (`-efivars.fd`). NixOS installs GRUB as the EFI bootloader at `/EFI/BOOT/BOOTAA64.EFI`. A `startup.nsh` script in the ESP tells the UEFI shell to find and run this bootloader in case the boot order is not configured.

The UEFI boot chain is: firmware → startup.nsh → GRUB → Linux kernel → systemd → Kubernetes services.

## systemd Services Over Static Pods

Every Kubernetes control plane component runs as a systemd service, not as a static pod. This is the primary architectural divergence from production clusters.

The rationale is pedagogical. When the API server is a systemd unit, you can:

```bash
systemctl status kube-apiserver
journalctl -u kube-apiserver -f
```

The full command line with all flags is visible in `systemctl cat kube-apiserver`. There is no abstraction layer between you and the process. You see the binary, its arguments, and its logs.

In production, running control plane components as static pods has real advantages: kubelet handles restarts, health checks, and resource limits. But those advantages come with a chicken-and-egg problem (kubelet must run before the API server exists) that tools like kubeadm solve with careful orchestration. We avoid this complexity entirely by keeping kubelet off the control plane node.

## Snapshot/Restore Over Immutable Infrastructure

The project includes a snapshot/restore mechanism using QCOW2's internal snapshot feature. This is an explicitly stateful approach — the opposite of the immutable infrastructure pattern where you destroy and recreate VMs rather than mutating them.

We chose this because the bottleneck in development is build time. A full installation takes 10-15 minutes. A snapshot restore takes 30 seconds. When you are iterating on kubelet configuration or debugging Cilium initialization, the ability to reset to a known-good state in seconds is transformative.

The trade-off is that snapshots capture all state, including expired leases, stale caches, and accumulated log data. A snapshot from three days ago might have etcd data that conflicts with newly generated certificates. For this project, where the cluster is ephemeral and the goal is learning, this is acceptable.

## 8 GB RAM Per Node

Each VM is allocated 8 GB of RAM (24 GB total for the cluster). This is generous. A minimal Kubernetes node needs about 2 GB. We allocate more for three reasons:

1. **Cilium's memory footprint**: The eBPF maps and the cilium-agent pod consume 300-500 MB.
2. **NixOS build overhead**: `nixos-install` and `nixos-rebuild` need significant memory for Nix evaluations.
3. **Workload headroom**: The cluster should be able to run real workloads (Kafka, databases) without immediately hitting OOM.

If you are constrained on host memory, reducing `WORKER_MEM` to 4096 in `cluster.env` is safe for basic testing. The control plane should keep at least 4 GB for etcd stability.
