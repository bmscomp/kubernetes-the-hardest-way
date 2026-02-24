# Proxy Configuration

How to run the cluster behind a corporate HTTP proxy. This guide covers every layer that needs proxy awareness — from the NixOS installation to individual pods.

## The Proxy Problem, Layer by Layer

When your host machine sits behind a corporate proxy, outbound HTTP/HTTPS traffic must go through a proxy server. This affects six distinct layers in the cluster:

```
Layer 6: Pods (application containers)          → curl, wget, API calls
Layer 5: Kubernetes system pods (Cilium, DNS)   → image pulls, API access
Layer 4: containerd                             → container image pulls
Layer 3: kubelet                                → API server communication (internal, no proxy needed)
Layer 2: NixOS system services                  → package downloads, DNS
Layer 1: NixOS installation                     → nixos-install fetches packages from cache.nixos.org
Layer 0: QEMU networking                        → inherits host TCP stack automatically
```

The good news: **Layer 0 is free.** QEMU user-mode networking works by proxying the VM's TCP connections through the host's network stack. If the host can reach the internet through a proxy, the VM's TCP connections will too — but only if the applications inside the VM know to use the proxy. Raw TCP connections work; HTTP applications need explicit configuration.

## Configuration

### 1. Add Proxy Variables to cluster.env

Add these lines to `cluster.env`. Every script sources this file, so the values propagate everywhere:

```bash
PROXY_HTTP="http://proxy.corp.example.com:8080"
PROXY_HTTPS="http://proxy.corp.example.com:8080"
PROXY_NO="localhost,127.0.0.1,10.0.2.0/24,10.32.0.0/24,10.200.0.0/16,.svc,.cluster.local"
```

The `NO_PROXY` list is critical. Without it, internal cluster traffic (pod-to-pod, pod-to-API-server, kubelet-to-API-server) would be sent to the proxy, which cannot route it. The entries:

| Entry | Purpose |
|-------|---------|
| `localhost`, `127.0.0.1` | Loopback |
| `10.0.2.0/24` | QEMU user-mode network |
| `10.32.0.0/24` | Kubernetes service CIDR |
| `10.200.0.0/16` | Kubernetes pod CIDR |
| `.svc`, `.cluster.local` | Kubernetes DNS suffixes |

### 2. NixOS Installation (nixos-install)

The `nixos-install` command downloads packages from `cache.nixos.org`. Behind a proxy, it needs `HTTP_PROXY` and `HTTPS_PROXY` set in the Live CD session.

In `bin/provision.sh`, add the proxy export before the `nixos-install` command in the expect script:

```bash
send "export HTTP_PROXY=$PROXY_HTTP HTTPS_PROXY=$PROXY_HTTPS NO_PROXY=$PROXY_NO\r"
expect "root@nixos"

send "nixos-install --no-root-passwd\r"
```

This ensures the Nix daemon (which runs as a subprocess of nixos-install) inherits the proxy environment.

### 3. NixOS System-Wide Proxy

Once the VM is installed and running, system services need proxy configuration. Add this to `configs/nixos-base.nix` (or to the node-specific config in `generate-nocloud-iso.sh`):

```nix
networking.proxy = {
  httpProxy  = "http://proxy.corp.example.com:8080";
  httpsProxy = "http://proxy.corp.example.com:8080";
  noProxy    = "localhost,127.0.0.1,10.0.2.0/24,10.32.0.0/24,10.200.0.0/16,.svc,.cluster.local";
};
```

NixOS's `networking.proxy` module sets `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` globally for all systemd services and interactive sessions. This is the single most effective configuration — it covers wget, curl, git, and any service that respects standard proxy environment variables.

### 4. containerd Image Pulls

containerd pulls container images (e.g., `registry.k8s.io/pause`, Cilium images). It has its own proxy configuration separate from the system environment.

Add to the NixOS configuration:

```nix
systemd.services.containerd.environment = {
  HTTP_PROXY  = "http://proxy.corp.example.com:8080";
  HTTPS_PROXY = "http://proxy.corp.example.com:8080";
  NO_PROXY    = "localhost,127.0.0.1,10.0.2.0/24,10.32.0.0/24,10.200.0.0/16,.svc,.cluster.local";
};
```

Alternatively, create a systemd override that NixOS will merge:

```nix
systemd.services.containerd.serviceConfig.EnvironmentFile = "/etc/systemd/system/containerd.service.d/proxy.conf";
```

The `systemd.services.containerd.environment` approach is cleaner because it stays within the NixOS configuration model.

### 5. Kubelet

Kubelet does not pull images directly — containerd handles that. However, if kubelet needs to download anything over HTTP (unlikely but possible with custom admission webhooks), it should also have proxy variables:

```nix
systemd.services.kubelet.environment = {
  HTTP_PROXY  = "http://proxy.corp.example.com:8080";
  HTTPS_PROXY = "http://proxy.corp.example.com:8080";
  NO_PROXY    = "localhost,127.0.0.1,10.0.2.0/24,10.32.0.0/24,10.200.0.0/16,.svc,.cluster.local";
};
```

Importantly, kubelet → API server communication must NOT go through the proxy. This is why `10.0.2.0/24` (the QEMU gateway subnet) is in `NO_PROXY`.

### 6. Cilium Installation

The `cilium install` CLI runs on the host and creates Kubernetes resources that reference container images. The Cilium agent pods then pull those images via containerd (which we configured in step 4).

However, the `cilium` CLI itself may need proxy settings if it downloads anything:

```bash
export HTTP_PROXY="$PROXY_HTTP"
export HTTPS_PROXY="$PROXY_HTTPS"
export NO_PROXY="$PROXY_NO"
cilium install --version 1.16.5 ...
```

### 7. Pods (Application Workloads)

Individual pods that need internet access require proxy environment variables. There are three approaches:

**Per-deployment** (most explicit):
```yaml
env:
- name: HTTP_PROXY
  value: "http://proxy.corp.example.com:8080"
- name: HTTPS_PROXY
  value: "http://proxy.corp.example.com:8080"
- name: NO_PROXY
  value: "localhost,127.0.0.1,10.32.0.0/24,10.200.0.0/16,.svc,.cluster.local"
```

**Cluster-wide via a MutatingAdmissionWebhook** (automatic):

Deploy a webhook that injects proxy env vars into every pod. This is the cleanest approach for large teams but adds operational complexity.

**Cluster-wide via a PodPreset or RuntimeClass** (deprecated in newer K8s):

Not recommended for new clusters.

## Proxy with TLS Interception

Many corporate proxies perform TLS interception (MITM) using a custom CA certificate. This breaks HTTPS connections unless the custom CA is trusted by the client.

### Adding a Custom CA

If your proxy uses a custom CA, you need to inject the CA certificate at multiple levels:

**NixOS system trust store:**
```nix
security.pki.certificateFiles = [
  /etc/nixos/certs/corporate-ca.pem
];
```

This adds the corporate CA to the system-wide trust store. curl, wget, git, and most applications will trust it.

**containerd:**

containerd uses the system trust store by default on NixOS, so the `security.pki.certificateFiles` line above should be sufficient.

**Node.js, Java, and other runtimes:**

Some runtimes maintain their own trust stores. For Java:
```bash
keytool -import -trustcacerts -file corporate-ca.pem -alias corp-proxy -keystore $JAVA_HOME/lib/security/cacerts
```

For Node.js:
```bash
export NODE_EXTRA_CA_CERTS=/etc/nixos/certs/corporate-ca.pem
```

## Implementation Guide

To implement proxy support in this project, you would modify three files:

### cluster.env
```diff
+PROXY_HTTP="http://proxy.corp.example.com:8080"
+PROXY_HTTPS="http://proxy.corp.example.com:8080"
+PROXY_NO="localhost,127.0.0.1,10.0.2.0/24,10.32.0.0/24,10.200.0.0/16,.svc,.cluster.local"
```

### generate-nocloud-iso.sh (inside the configuration.nix heredoc)
```diff
+  networking.proxy = {
+    httpProxy  = "$PROXY_HTTP";
+    httpsProxy = "$PROXY_HTTPS";
+    noProxy    = "$PROXY_NO";
+  };
+
+  systemd.services.containerd.environment = {
+    HTTP_PROXY  = "$PROXY_HTTP";
+    HTTPS_PROXY = "$PROXY_HTTPS";
+    NO_PROXY    = "$PROXY_NO";
+  };
```

### provision.sh (before nixos-install in the expect script)
```diff
+send "export HTTP_PROXY=$PROXY_HTTP HTTPS_PROXY=$PROXY_HTTPS NO_PROXY=$PROXY_NO\r"
+expect "root@nixos"
+
 send "nixos-install --no-root-passwd\r"
```

The changes are conditional — if `PROXY_HTTP` is empty in `cluster.env`, the proxy blocks simply do not render, and the cluster works as before.

## Testing Proxy Configuration

After building the cluster behind a proxy, verify each layer:

```bash
# Layer 2: NixOS system
ssh -p 2223 root@127.0.0.1 "curl -s https://cache.nixos.org"

# Layer 4: containerd image pull
ssh -p 2223 root@127.0.0.1 "crictl pull nginx:latest"

# Layer 6: Pod internet access
kubectl run test-proxy --rm -it --image=busybox -- wget -qO- https://httpbin.org/ip
```

## Common Pitfalls

**Missing NO_PROXY entries.** The most common mistake is forgetting to exclude internal cluster CIDRs from the proxy. Symptoms: kubelet cannot register, pods cannot reach the API server, Cilium fails to initialize. The fix is always to add the offending CIDR to `NO_PROXY`.

**Proxy requires authentication.** If your proxy requires credentials, use the URL format: `http://user:password@proxy.corp.example.com:8080`. Be aware that this embeds credentials in configuration files and environment variables.

**QEMU DNS resolution.** QEMU's user-mode DNS resolver (`10.0.2.3`) forwards queries to the host's DNS. If the host uses a proxy-aware DNS that returns different results for internal vs. external domains, this should work transparently. If not, you may need to set `networking.nameservers` in NixOS to point at your corporate DNS servers explicitly.

**nixos-install hangs.** If `nixos-install` appears to hang, it may be waiting for a proxy connection to `cache.nixos.org`. Check that `HTTP_PROXY` and `HTTPS_PROXY` are set correctly in the Live CD session before running the install.
