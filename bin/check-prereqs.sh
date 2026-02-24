#!/usr/bin/env bash
set -eo pipefail

FAILED=0

G="\e[32m"  # green
R="\e[31m"  # red
D="\e[90m"  # dim
Y="\e[33m"  # yellow
B="\e[1m"   # bold
N="\e[0m"   # reset

check() {
  local name=$1
  local cmd=$2
  local version_cmd="${3:-}"

  if command -v "$cmd" &>/dev/null; then
    local ver=""
    if [ -n "$version_cmd" ]; then
      ver=$(eval "$version_cmd" 2>/dev/null || echo "installed")
    else
      ver="installed"
    fi
    printf "  ${G}✔${N}  │ ${B}%-10s${N} │ ${D}%s${N}\n" "$name" "$ver"
  else
    printf "  ${R}✘${N}  │ ${B}%-10s${N} │ ${R}NOT FOUND${N}\n" "$name"
    FAILED=1
  fi
}

echo ""
echo -e "  ${B}Checking prerequisites${N}"
echo -e "  ${D}─────┼────────────┼──────────────────────────────────────${N}"

check "qemu" "qemu-system-$(uname -m | sed 's/arm64/aarch64/')" \
  "qemu-system-$(uname -m | sed 's/arm64/aarch64/') --version | head -1 | sed 's/QEMU emulator version //'"

check "kubectl" "kubectl" \
  "kubectl version --client -o yaml 2>/dev/null | grep gitVersion | awk '{print \$2}'"

check "expect" "expect" \
  "expect -v 2>/dev/null | head -1 | sed 's/expect version //'"

check "cfssl" "cfssl" \
  "cfssl version 2>/dev/null | head -1 | awk '{print \$2}' | tr -d ','"

check "curl" "curl" \
  "curl --version | head -1 | awk '{print \$2}'"

check "base64" "base64" \
  "echo 'ok' | base64 >/dev/null && echo 'available'"

check "tar" "tar" \
  "tar --version 2>&1 | head -1 | sed 's/bsdtar //' | awk '{print \$1}'"

echo -e "  ${D}─────┼────────────┼──────────────────────────────────────${N}"

if [ -f "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" ] || \
   [ -f "/usr/share/OVMF/OVMF_CODE.fd" ] || \
   [ -f "/usr/share/qemu/edk2-aarch64-code.fd" ]; then
  printf "  ${G}✔${N}  │ ${B}%-10s${N} │ ${D}%s${N}\n" "UEFI" "firmware found"
else
  printf "  ${R}✘${N}  │ ${B}%-10s${N} │ ${R}%s${N}\n" "UEFI" "NOT FOUND (install qemu with UEFI)"
  FAILED=1
fi

TOTAL_RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "?")

if [ "$TOTAL_RAM_GB" -ge 24 ] 2>/dev/null; then
  printf "  ${G}✔${N}  │ ${B}%-10s${N} │ ${D}%s GB (needs ~24 GB)${N}\n" "RAM" "$TOTAL_RAM_GB"
else
  printf "  ${Y}⚠${N}  │ ${B}%-10s${N} │ ${Y}%s GB — may be tight (needs ~24 GB)${N}\n" "RAM" "$TOTAL_RAM_GB"
fi

echo -e "  ${D}─────┴────────────┴──────────────────────────────────────${N}"
echo ""

if [ "$FAILED" -ne 0 ]; then
  echo -e "  ${R}Some prerequisites are missing. Install them and try again.${N}"
  echo ""
  exit 1
fi

echo -e "  ${G}All prerequisites satisfied.${N}"
echo ""
