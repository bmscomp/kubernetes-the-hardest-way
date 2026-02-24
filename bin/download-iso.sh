#!/usr/bin/env bash
set -eo pipefail

IMAGE_DIR="../images"
OS=$(uname -s)
ARCH=$(uname -m)
NIXOS_VERSION="25.11"
ISO_URL=""
ISO_FILE=""

mkdir -p "$IMAGE_DIR"

if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
  # Use aarch64 minimal ISO
  ISO_URL="https://channels.nixos.org/nixos-$NIXOS_VERSION/latest-nixos-minimal-aarch64-linux.iso"
  ISO_FILE="$IMAGE_DIR/nixos-minimal-aarch64-linux.iso"
else
  # Default to x86_64
  ISO_URL="https://channels.nixos.org/nixos-$NIXOS_VERSION/latest-nixos-minimal-x86_64-linux.iso"
  ISO_FILE="$IMAGE_DIR/nixos-minimal-x86_64-linux.iso"
fi

if [ -f "$ISO_FILE" ]; then
  echo "ISO already exists at $ISO_FILE"
else
  echo "Downloading NixOS ISO for $ARCH from $ISO_URL..."
  curl -L "$ISO_URL" -o "$ISO_FILE"
  echo "Downloaded $ISO_FILE"
fi
