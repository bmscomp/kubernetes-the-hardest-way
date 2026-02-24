#!/usr/bin/env bash
set -eo pipefail

NODE_NAME=$1
if [ -z "$NODE_NAME" ]; then
  echo "Usage: $0 <node-name>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLOUD_INIT_DIR="$PROJECT_DIR/cloud-init/$NODE_NAME"
ISO_DIR="$PROJECT_DIR/images"

rm -rf "$CLOUD_INIT_DIR"
mkdir -p "$CLOUD_INIT_DIR/nixos/certs"

CLUSTER_IP_VAR="CLUSTER_NET_${NODE_NAME}"
CLUSTER_IP=${!CLUSTER_IP_VAR:-""}
KUBELET_PORT_VAR="KUBELET_PORT_${NODE_NAME}"
KUBELET_PORT=${!KUBELET_PORT_VAR:-"10250"}

echo "Staging configurations for $NODE_NAME..."

TLS_DIR="$PROJECT_DIR/tls"
CONFIGS_DIR="$PROJECT_DIR/configs"
CERT_DIR="$CLOUD_INIT_DIR/nixos/certs"

if [ ! -d "$TLS_DIR" ]; then
  echo "Error: TLS directory not found. Run 'make pki' first."
  exit 1
fi

cp "$TLS_DIR/ca.pem" "$CERT_DIR/"

if [[ "$NODE_NAME" == "alpha" ]]; then
  cp "$TLS_DIR/ca-key.pem" "$CERT_DIR/"
  cp "$TLS_DIR/kubernetes.pem" "$TLS_DIR/kubernetes-key.pem" "$CERT_DIR/"
  cp "$TLS_DIR/service-account.pem" "$TLS_DIR/service-account-key.pem" "$CERT_DIR/"
  cp "$CONFIGS_DIR/encryption-config.yaml" "$CERT_DIR/"
  cp "$CONFIGS_DIR/kube-controller-manager.kubeconfig" "$CERT_DIR/"
  cp "$CONFIGS_DIR/kube-scheduler.kubeconfig" "$CERT_DIR/"
fi

if [[ "$NODE_NAME" == "sigma" ]] || [[ "$NODE_NAME" == "gamma" ]]; then
  cp "$TLS_DIR/${NODE_NAME}.pem" "$CERT_DIR/"
  cp "$TLS_DIR/${NODE_NAME}-key.pem" "$CERT_DIR/"
  cp "$CONFIGS_DIR/${NODE_NAME}.kubeconfig" "$CERT_DIR/"
  cp "$CONFIGS_DIR/kube-proxy.kubeconfig" "$CERT_DIR/"
fi

# Detect architecture for boot loader and filesystem config
HOST_ARCH=$(uname -m)

if [ "$HOST_ARCH" = "arm64" ] || [ "$HOST_ARCH" = "aarch64" ]; then
  BOOT_LOADER_NIX='  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.loader.grub.device = "nodev";
  boot.loader.timeout = 0;'
  FILESYSTEMS_NIX='  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/boot"; fsType = "vfat"; };
  swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];'
else
  BOOT_LOADER_NIX='  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";'
  FILESYSTEMS_NIX='  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];'
fi

cat << NIXEOF > "$CLOUD_INIT_DIR/nixos/configuration.nix"
{ config, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./node-config.nix
  ];

$BOOT_LOADER_NIX

$FILESYSTEMS_NIX

  system.stateVersion = "25.11";

  networking.firewall.enable = false;

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  environment.systemPackages = with pkgs; [
    wget curl vim git socat iptables conntrack-tools ethtool
  ];

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  users.mutableUsers = false;
  users.users.root.initialPassword = "kubernetes";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2VReptdKUwYtCMkL7WG1kZwmIZeIU7KuB+v+NbrndL bmscomp@Saids-MacBook-Pro.local"
  ];

  system.activationScripts.kubernetes-certs-setup = ''
    mkdir -p /var/lib/kubernetes/pki
    if [ -d /etc/nixos/certs ]; then
      cp -r /etc/nixos/certs/* /var/lib/kubernetes/pki/
      chmod -R 755 /var/lib/kubernetes
    fi
  '';
$(if [ -n "${PROXY_HTTP:-}" ]; then
cat << PROXYEOF

  networking.proxy = {
    httpProxy  = "$PROXY_HTTP";
    httpsProxy = "${PROXY_HTTPS:-$PROXY_HTTP}";
    noProxy    = "${PROXY_NO:-localhost,127.0.0.1}";
  };

  systemd.services.containerd.environment = {
    HTTP_PROXY  = "$PROXY_HTTP";
    HTTPS_PROXY = "${PROXY_HTTPS:-$PROXY_HTTP}";
    NO_PROXY    = "${PROXY_NO:-localhost,127.0.0.1}";
  };
PROXYEOF
fi)
}
NIXEOF

# Write the node-specific config
# This heredoc is NOT quoted, so $NODE_NAME will be expanded by bash.
# But Nix expressions like ${pkgs.kubernetes} must be escaped.
if [[ "$NODE_NAME" == "alpha" ]]; then
  cat > "$CLOUD_INIT_DIR/nixos/node-config.nix" << NODEEOF
{ config, pkgs, ... }:
{
  networking.hostName = "$NODE_NAME";

  networking.extraHosts = ''
    10.0.2.2 sigma
    10.0.2.2 gamma
  '';

  services.etcd = {
    enable = true;
    name = "$NODE_NAME";
    dataDir = "/var/lib/etcd";
    listenClientUrls = ["https://127.0.0.1:2379"];
    advertiseClientUrls = ["https://127.0.0.1:2379"];
    listenPeerUrls = ["https://127.0.0.1:2380"];
    initialAdvertisePeerUrls = ["https://127.0.0.1:2380"];
    initialCluster = ["$NODE_NAME=https://127.0.0.1:2380"];
    initialClusterState = "new";
    initialClusterToken = "etcd-cluster-0";
    clientCertAuth = true;
    trustedCaFile = "/var/lib/kubernetes/pki/ca.pem";
    certFile = "/var/lib/kubernetes/pki/kubernetes.pem";
    keyFile = "/var/lib/kubernetes/pki/kubernetes-key.pem";
    peerClientCertAuth = true;
    peerTrustedCaFile = "/var/lib/kubernetes/pki/ca.pem";
    peerCertFile = "/var/lib/kubernetes/pki/kubernetes.pem";
    peerKeyFile = "/var/lib/kubernetes/pki/kubernetes-key.pem";
  };

  systemd.services.kube-apiserver = {
    description = "Kubernetes API Server";
    wantedBy = [ "multi-user.target" ];
    after = [ "etcd.service" ];
    path = [ pkgs.kubernetes ];
    serviceConfig = {
      ExecStart = "\${pkgs.kubernetes}/bin/kube-apiserver --advertise-address=127.0.0.1 --allow-privileged=true --apiserver-count=1 --authorization-mode=Node,RBAC --bind-address=0.0.0.0 --client-ca-file=/var/lib/kubernetes/pki/ca.pem --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota --etcd-cafile=/var/lib/kubernetes/pki/ca.pem --etcd-certfile=/var/lib/kubernetes/pki/kubernetes.pem --etcd-keyfile=/var/lib/kubernetes/pki/kubernetes-key.pem --etcd-servers=https://127.0.0.1:2379 --event-ttl=1h --encryption-provider-config=/var/lib/kubernetes/pki/encryption-config.yaml --kubelet-certificate-authority=/var/lib/kubernetes/pki/ca.pem --kubelet-client-certificate=/var/lib/kubernetes/pki/kubernetes.pem --kubelet-client-key=/var/lib/kubernetes/pki/kubernetes-key.pem --runtime-config=api/all=true --service-account-key-file=/var/lib/kubernetes/pki/service-account.pem --service-account-signing-key-file=/var/lib/kubernetes/pki/service-account-key.pem --service-account-issuer=https://127.0.0.1:6443 --service-cluster-ip-range=10.32.0.0/24 --service-node-port-range=30000-32767 --tls-cert-file=/var/lib/kubernetes/pki/kubernetes.pem --tls-private-key-file=/var/lib/kubernetes/pki/kubernetes-key.pem --v=2";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.services.kube-controller-manager = {
    description = "Kubernetes Controller Manager";
    wantedBy = [ "multi-user.target" ];
    after = [ "kube-apiserver.service" ];
    path = [ pkgs.kubernetes ];
    serviceConfig = {
      ExecStart = "\${pkgs.kubernetes}/bin/kube-controller-manager --bind-address=0.0.0.0 --cluster-cidr=10.200.0.0/16 --cluster-name=kubernetes --cluster-signing-cert-file=/var/lib/kubernetes/pki/ca.pem --cluster-signing-key-file=/var/lib/kubernetes/pki/ca-key.pem --kubeconfig=/var/lib/kubernetes/pki/kube-controller-manager.kubeconfig --leader-elect=true --root-ca-file=/var/lib/kubernetes/pki/ca.pem --service-account-private-key-file=/var/lib/kubernetes/pki/service-account-key.pem --service-cluster-ip-range=10.32.0.0/24 --use-service-account-credentials=true --v=2";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.services.kube-scheduler = {
    description = "Kubernetes Scheduler";
    wantedBy = [ "multi-user.target" ];
    after = [ "kube-apiserver.service" ];
    path = [ pkgs.kubernetes ];
    serviceConfig = {
      ExecStart = "\${pkgs.kubernetes}/bin/kube-scheduler --kubeconfig=/var/lib/kubernetes/pki/kube-scheduler.kubeconfig --leader-elect=true --v=2";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
NODEEOF

elif [[ "$NODE_NAME" == "sigma" ]] || [[ "$NODE_NAME" == "gamma" ]]; then
  cat > "$CLOUD_INIT_DIR/nixos/node-config.nix" << NODEEOF
{ config, pkgs, ... }:
{
  networking.hostName = "$NODE_NAME";

  system.activationScripts.cni-plugins-setup = ''
    mkdir -p /opt/cni/bin /etc/cni/net.d
    for f in \${pkgs.cni-plugins}/bin/*; do
      ln -sf "\$f" /opt/cni/bin/
    done
  '';
  virtualisation.containerd.enable = true;
  virtualisation.containerd.settings = {
    plugins."io.containerd.grpc.v1.cri".cni = {
      bin_dir = "/opt/cni/bin";
      conf_dir = "/etc/cni/net.d";
    };
  };

  systemd.services.kubelet = {
    description = "Kubernetes Kubelet";
    wantedBy = [ "multi-user.target" ];
    after = [ "containerd.service" ];
    path = [ pkgs.kubernetes pkgs.runc pkgs.containerd pkgs.iptables pkgs.socat pkgs.cni-plugins pkgs.ethtool pkgs.util-linux ];
    serviceConfig = {
      ExecStart = "\${pkgs.kubernetes}/bin/kubelet --config=/etc/nixos/kubelet-config.yaml --container-runtime-endpoint=unix:///run/containerd/containerd.sock --kubeconfig=/var/lib/kubernetes/pki/${NODE_NAME}.kubeconfig --register-node=true --fail-swap-on=false --v=2";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.services.kube-proxy = {
    description = "Kubernetes Kube Proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ pkgs.kubernetes pkgs.iptables pkgs.conntrack-tools pkgs.ipset ];
    serviceConfig = {
      ExecStart = "\${pkgs.kubernetes}/bin/kube-proxy --config=/etc/nixos/kube-proxy-config.yaml --v=2";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
NODEEOF

  cat > "$CLOUD_INIT_DIR/nixos/kubelet-config.yaml" << YAMLEOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/pki/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
podCIDR: "10.200.1.0/24"
resolvConf: "/etc/resolv.conf"
cniBinDir: "/opt/cni/bin"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubernetes/pki/${NODE_NAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubernetes/pki/${NODE_NAME}-key.pem"
port: $KUBELET_PORT
YAMLEOF

  cat > "$CLOUD_INIT_DIR/nixos/kube-proxy-config.yaml" << YAMLEOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kubernetes/pki/kube-proxy.kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
YAMLEOF
fi

echo "Configs staged for $NODE_NAME in $CLOUD_INIT_DIR/nixos/"
ls -la "$CLOUD_INIT_DIR/nixos/"
