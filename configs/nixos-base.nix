{ config, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";

  networking.firewall.enable = false;

  # Enable IP forwarding (required for Kubernetes)
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Required packages
  environment.systemPackages = with pkgs; [
    wget
    curl
    vim
    git
    socat
    iptables
    conntrack-tools
    ethtool
  ];

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  users.mutableUsers = false;
  users.users.root.hashedPassword = "$6$ilw2ckmtv58wLVQn$N2YXxLGYB.QFETlbmOWS6LnV41zBkgUGeKFc5P9Kpq18ZhNgyw88C51WJKUZEBtLBiCeEWYfjyo7qBMf21eBn/";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2VReptdKUwYtCMkL7WG1kZwmIZeIU7KuB+v+NbrndL bmscomp@Saids-MacBook-Pro.local"
  ];

  # Ensure the activation script directory exists
  system.activationScripts.kubernetes-certs-setup = ''
    mkdir -p /var/lib/kubernetes/pki
  '';
}
