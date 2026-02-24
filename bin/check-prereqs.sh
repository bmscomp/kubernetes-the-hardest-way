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

STATUS_W=3
NAME_W=14
SEP_OVERHEAD=13  # 2 indent + 3 pipes + 4 spaces + 4 padding
VER_W=$((COLS - STATUS_W - NAME_W - SEP_OVERHEAD))
[ "$VER_W" -lt 20 ] && VER_W=20
LINE_W=$((STATUS_W + NAME_W + VER_W + 8))  # inner width

hline() {
  local left=$1 t1=$2 t2=$3 right=$4
  local seg1="" seg2="" seg3=""
  seg1=$(printf '%*s' $((STATUS_W + 2)) '' | tr ' ' '─')
  seg2=$(printf '%*s' $((NAME_W + 2)) '' | tr ' ' '─')
  seg3=$(printf '%*s' $((VER_W + 2)) '' | tr ' ' '─')
  echo -e "  ${D}${left}${seg1}${t1}${seg2}${t2}${seg3}${right}${N}"
}

row() {
  local color=$1 icon=$2 name=$3 value=$4
  printf "  ${D}│${N} ${color}${icon}${N}%-*s${D}│${N} ${B}%-*s${N}${D}│${N} %s\n" \
    $((STATUS_W - 1)) "" \
    "$NAME_W" "$name" \
    "$value"
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
    row "$G" "✔" "$name" "$ver"
  else
    row "$R" "✘" "$name" "$(echo -e "${R}NOT FOUND${N}")"
    FAILED=1
  fi
}

echo ""
echo -e "  ${C}${B}☸ Checking prerequisites${N}"
echo ""
hline "┌" "┬" "┬" "┐"

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

hline "├" "┼" "┼" "┤"

if [ -f "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" ] || \
   [ -f "/usr/share/OVMF/OVMF_CODE.fd" ] || \
   [ -f "/usr/share/qemu/edk2-aarch64-code.fd" ]; then
  row "$G" "✔" "UEFI" "firmware found"
else
  row "$R" "✘" "UEFI" "$(echo -e "${R}NOT FOUND — install qemu with UEFI${N}")"
  FAILED=1
fi

TOTAL_RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "?")

if [ "$TOTAL_RAM_GB" -ge 24 ] 2>/dev/null; then
  row "$G" "✔" "RAM" "${TOTAL_RAM_GB} GB (needs ~24 GB)"
else
  row "$Y" "⚠" "RAM" "$(echo -e "${Y}${TOTAL_RAM_GB} GB — may be tight (needs ~24 GB)${N}")"
fi

hline "└" "┴" "┴" "┘"
echo ""

if [ "$FAILED" -ne 0 ]; then
  echo -e "  ${R}✘ Some prerequisites are missing. Install them and try again.${N}"
  echo ""
  exit 1
fi

echo -e "  ${G}✔ All prerequisites satisfied.${N}"
echo ""
