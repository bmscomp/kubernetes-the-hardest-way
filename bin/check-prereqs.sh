#!/usr/bin/env bash
set -eo pipefail

FAILED=0

check() {
  local name=$1
  local cmd=$2
  if command -v "$cmd" &>/dev/null; then
    local version
    version=$("$cmd" --version 2>&1 | head -1 || echo "unknown")
    printf "  ✔ %-12s %s\n" "$name" "$version"
  else
    printf "  ✘ %-12s NOT FOUND\n" "$name"
    FAILED=1
  fi
}

echo "Checking prerequisites..."
echo ""

check "QEMU" "qemu-system-$(uname -m | sed 's/arm64/aarch64/')"
check "kubectl" "kubectl"
check "expect" "expect"
check "curl" "curl"
check "base64" "base64"
check "tar" "tar"

echo ""

if [ -f "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" ] || \
   [ -f "/usr/share/OVMF/OVMF_CODE.fd" ] || \
   [ -f "/usr/share/qemu/edk2-aarch64-code.fd" ]; then
  echo "  ✔ UEFI firmware found"
else
  echo "  ✘ UEFI firmware NOT FOUND (install qemu with UEFI support)"
  FAILED=1
fi

TOTAL_RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "?")
echo ""
echo "  Host RAM: ${TOTAL_RAM_GB} GB (cluster needs ~24 GB)"

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "Some prerequisites are missing. Install them and try again."
  exit 1
fi

echo ""
echo "All prerequisites satisfied."
