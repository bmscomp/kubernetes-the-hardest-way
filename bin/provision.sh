#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OS=$(uname -s)
ARCH=$(uname -m)

ISO_FILE=""
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  ISO_FILE="$PROJECT_DIR/images/nixos-minimal-aarch64-linux.iso"
else
  ISO_FILE="$PROJECT_DIR/images/nixos-minimal-x86_64-linux.iso"
fi

QEMU_BOOT_ARGS=""
if [ "$1" = "--iso" ]; then
  QEMU_BOOT_ARGS="-cdrom $ISO_FILE -boot d"
  shift
fi

NODE_NAME=$1
NODE_TYPE=$2
MEM=${3:-2048}
MAC_ADDRESS=${4:-"52:54:00:12:34:56"}
SSH_PORT=${5:-"2222"}

if [ -z "$NODE_NAME" ] || [ -z "$NODE_TYPE" ]; then
  echo "Usage: $0 [--iso] <node-name> <node-type> [memory_mb] [mac_address] [ssh_port]"
  exit 1
fi

QEMU_CMD="qemu-system-x86_64"
ACCEL="kvm"
IMAGE_DIR="$PROJECT_DIR/images"
mkdir -p "$IMAGE_DIR"
DISK_IMAGE="$IMAGE_DIR/$NODE_NAME.qcow2"

if [ "$OS" = "Darwin" ]; then
  ACCEL="hvf"
  if [ "$ARCH" = "arm64" ]; then
    QEMU_CMD="qemu-system-aarch64"
    QEMU_MACHINE="-machine virt,accel=$ACCEL,highmem=on"
    QEMU_CPU="-cpu host"
    UEFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    UEFI_VARS_TEMPLATE="/opt/homebrew/share/qemu/edk2-arm-vars.fd"
    UEFI_VARS="$IMAGE_DIR/${NODE_NAME}-efivars.fd"
    if [ ! -f "$UEFI_CODE" ]; then
      echo "Error: UEFI firmware not found at $UEFI_CODE"
      exit 1
    fi
    if [ ! -f "$UEFI_VARS" ]; then
      cp "$UEFI_VARS_TEMPLATE" "$UEFI_VARS"
    fi
    QEMU_PFLASH="-drive if=pflash,format=raw,unit=0,file=$UEFI_CODE,readonly=on -drive if=pflash,format=raw,unit=1,file=$UEFI_VARS"
    QEMU_BIOS="-bios $UEFI_CODE"
  else
    QEMU_MACHINE="-machine q35,accel=$ACCEL"
    QEMU_CPU="-cpu host"
  fi
elif [ "$OS" = "Linux" ]; then
  QEMU_MACHINE="-machine q35,accel=kvm"
  QEMU_CPU="-cpu host"
else
  echo "Unsupported OS: $OS"; exit 1
fi

echo "OS: $OS, ARCH: $ARCH"
echo "Using accelerator: $ACCEL"

if [ ! -f "$DISK_IMAGE" ]; then
  echo "Creating disk image for $NODE_NAME..."
  qemu-img create -f qcow2 "$DISK_IMAGE" 20G
fi

echo "Generating configs for $NODE_NAME..."
"$SCRIPT_DIR/generate-nocloud-iso.sh" "$NODE_NAME"

HOSTFWD_ARGS="hostfwd=tcp::$SSH_PORT-:22"
if [ "$NODE_TYPE" = "control-plane" ] || [ "$NODE_TYPE" = "master" ]; then
  HOSTFWD_ARGS="$HOSTFWD_ARGS,hostfwd=tcp::6443-:6443"
fi

KUBELET_PORT_VAR="KUBELET_PORT_${NODE_NAME}"
KUBELET_PORT=${!KUBELET_PORT_VAR:-""}
if [ -n "$KUBELET_PORT" ]; then
  HOSTFWD_ARGS="$HOSTFWD_ARGS,hostfwd=tcp::$KUBELET_PORT-:$KUBELET_PORT"
fi

if [ -n "$QEMU_BOOT_ARGS" ]; then
  echo "Installing NixOS on $NODE_NAME via Live CD + Expect..."

  CLOUD_INIT_DIR="$PROJECT_DIR/cloud-init/$NODE_NAME"
  
  if [ ! -d "$CLOUD_INIT_DIR/nixos" ]; then
    echo "Error: cloud-init configs not found at $CLOUD_INIT_DIR/nixos"
    exit 1
  fi

  CONFIG_TARBALL="$SCRIPT_DIR/${NODE_NAME}-configs.tar.gz"
  tar -czf "$CONFIG_TARBALL" -C "$CLOUD_INIT_DIR" nixos
  CONFIG_B64=$(base64 < "$CONFIG_TARBALL")
  rm -f "$CONFIG_TARBALL"

  # Architecture-aware partitioning
  if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    # UEFI: GPT + EFI System Partition
    PARTITION_COMMANDS='
send "parted /dev/vda -- mklabel gpt\r"
expect "root@nixos"
send "parted /dev/vda -- mkpart ESP fat32 1MB 512MB\r"
expect "root@nixos"
send "parted /dev/vda -- set 1 esp on\r"
expect "root@nixos"
send "parted /dev/vda -- mkpart primary 512MB -1GB\r"
expect "root@nixos"
send "parted /dev/vda -- mkpart primary linux-swap -1GB 100%\r"
expect "root@nixos"
send "mkfs.fat -F 32 -n boot /dev/vda1\r"
expect "root@nixos"
send "mkfs.ext4 -F -L nixos /dev/vda2\r"
expect "root@nixos"
send "mkswap -L swap /dev/vda3\r"
expect "root@nixos"
send "sleep 2\r"
expect "root@nixos"'
    MOUNT_BOOT_CMD='send "mkdir -p /mnt/boot && mount /dev/vda1 /mnt/boot\r"
expect "root@nixos"'
  else
    # BIOS: MBR
    PARTITION_COMMANDS='
send "parted /dev/vda -- mklabel msdos\r"
expect "root@nixos"
send "parted /dev/vda -- mkpart primary 1MB -1GB\r"
expect "root@nixos"
send "parted /dev/vda -- mkpart primary linux-swap -1GB 100%\r"
expect "root@nixos"
send "mkfs.ext4 -F -L nixos /dev/vda1\r"
expect "root@nixos"
send "mkswap -L swap /dev/vda2\r"
expect "root@nixos"'
    MOUNT_BOOT_CMD=""
  fi

  EXPECT_SCRIPT="$SCRIPT_DIR/wait-install-${NODE_NAME}.exp"
  cat > "$EXPECT_SCRIPT" << EXPECTEOF
#!/usr/bin/expect -f
set timeout 600
spawn $QEMU_CMD $QEMU_MACHINE $QEMU_PFLASH $QEMU_CPU -m $MEM -smp 2 -drive file=$DISK_IMAGE,format=qcow2,if=virtio $QEMU_BOOT_ARGS -netdev user,id=net0,$HOSTFWD_ARGS -device virtio-net-pci,netdev=net0,mac=$MAC_ADDRESS -nographic

expect {
  "nixos@nixos" {}
  timeout { puts "TIMEOUT: NixOS did not boot"; exit 1 }
}
sleep 2
send "\r"
expect "nixos@nixos"

send "sudo -i\r"
expect "root@nixos"

send "echo '=== Starting unattended NixOS installation ==='\r"
expect "root@nixos"

$PARTITION_COMMANDS

send "mount /dev/vda2 /mnt\r"
expect "root@nixos"
$MOUNT_BOOT_CMD
send "swapon /dev/vda3\r"
expect "root@nixos"

send "mkdir -p /mnt/etc/nixos\r"
expect "root@nixos"

send "echo '$CONFIG_B64' | base64 -d | tar xzf - -C /mnt/etc/nixos/ --strip-components=1\r"
expect "root@nixos"

send "echo '=== Config files ===' && ls -la /mnt/etc/nixos/\r"
expect "root@nixos"

send "head -15 /mnt/etc/nixos/configuration.nix\r"
expect "root@nixos"

set timeout 1800
send "nixos-install --no-root-passwd\r"
expect "root@nixos"
set timeout 600

send "echo '=== ESP contents ===' && find /mnt/boot -type f 2>/dev/null\r"
expect "root@nixos"

send "echo FS0:/EFI/BOOT/BOOTAA64.EFI > /mnt/boot/startup.nsh\r"
expect "root@nixos"
send "cat /mnt/boot/startup.nsh\r"
expect "root@nixos"

send "echo 'root:kubernetes' | nixos-enter --root /mnt -c chpasswd 2>/dev/null || true\r"
expect "root@nixos"

send "echo '=== Installation complete! Shutting down... ===' && poweroff\r"
expect eof
EXPECTEOF
  chmod +x "$EXPECT_SCRIPT"

  "$EXPECT_SCRIPT"
  rm -f "$EXPECT_SCRIPT"

  echo ""
  echo "Installation complete for $NODE_NAME!"
  echo "Boot with: $0 $NODE_NAME $NODE_TYPE $MEM $MAC_ADDRESS $SSH_PORT"
  exit 0
else
  LOG_FILE="$IMAGE_DIR/${NODE_NAME}-console.log"
  echo "Booting $NODE_NAME from installed disk (log: $LOG_FILE)..."
  $QEMU_CMD \
    $QEMU_MACHINE \
    $QEMU_PFLASH \
    $QEMU_CPU \
    -m $MEM \
    -smp 2 \
    -drive file="$DISK_IMAGE",format=qcow2,if=virtio \
    -netdev user,id=net0,$HOSTFWD_ARGS \
    -device virtio-net-pci,netdev=net0,mac=$MAC_ADDRESS \
    -nographic < /dev/null > "$LOG_FILE" 2>&1
fi
