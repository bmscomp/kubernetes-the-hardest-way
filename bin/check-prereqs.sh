#!/usr/bin/env bash
set -eo pipefail

FAILED=0
COLS=$(tput cols 2>/dev/null || echo 80)

G="\e[32m"
R="\e[31m"
D="\e[90m"
Y="\e[33m"
B="\e[1m"
C="\e[36m"
N="\e[0m"

NAME_W=14
VER_W=$((COLS - NAME_W - 12))  # 12 = status(4) + separators(8)

hline() {
  local left=$1 mid=$2 right=$3
  printf "  ${D}%s" "$left"
  printf '%.0s─' $(seq 1 5)
  printf "%s" "$mid"
  printf '%.0s─' $(seq 1 $((NAME_W + 2)))
  printf "%s" "$mid"
  printf '%.0s─' $(seq 1 $((VER_W + 2)))
  printf "%s${N}\n" "$right"
}

row() {
  local icon=$1 name=$2 value=$3
  printf "  ${D}│${N} %b ${D}│${N} ${B}%-${NAME_W}s${N} ${D}│${N} %-${VER_W}s ${D}│${N}\n" "$icon" "$name" "$value"
}

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
    row "${G}✔${N}" "$name" "$ver"
  else
    row "${R}✘${N}" "$name" "$(echo -e "${R}NOT FOUND${N}")"
    FAILED=1
  fi
}

echo ""
printf "  ${C}${B}☸ Checking prerequisites${N}\n"
echo ""
hline "┌" "┬" "┐"

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

hline "├" "┼" "┤"

if [ -f "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" ] || \
   [ -f "/usr/share/OVMF/OVMF_CODE.fd" ] || \
   [ -f "/usr/share/qemu/edk2-aarch64-code.fd" ]; then
  row "${G}✔${N}" "UEFI" "firmware found"
else
  row "${R}✘${N}" "UEFI" "$(echo -e "${R}NOT FOUND — install qemu with UEFI${N}")"
  FAILED=1
fi

TOTAL_RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "?")

if [ "$TOTAL_RAM_GB" -ge 24 ] 2>/dev/null; then
  row "${G}✔${N}" "RAM" "${TOTAL_RAM_GB} GB (needs ~24 GB)"
else
  row "${Y}⚠${N}" "RAM" "$(echo -e "${Y}${TOTAL_RAM_GB} GB — may be tight (needs ~24 GB)${N}")"
fi

hline "└" "┴" "┘"
echo ""

if [ "$FAILED" -ne 0 ]; then
  echo -e "  ${R}✘ Some prerequisites are missing. Install them and try again.${N}"
  echo ""
  exit 1
fi

echo -e "  ${G}✔ All prerequisites satisfied.${N}"
echo ""
