#!/usr/bin/env bash
set -eo pipefail

CONFIG_FILE=$1

if [ -z "$CONFIG_FILE" ]; then
  echo "Usage: $0 <path-to-nixos-config.nix>"
  exit 1
fi

echo "Building NixOS QCOW2 image from $CONFIG_FILE..."

# We use nixos-generators via nix-shell to ensure it runs even if not installed globally
# This works on both Linux and macOS (provided Nix is installed on the host building the image).
# If the user doesn't have Nix on macOS, they'll need to run this script on a Linux box or Linux VM first
# to generate the image, then they can use provision.sh on macOS.

nix-shell -p nixos-generators --run "nixos-generate -c $CONFIG_FILE -f qcow2"

echo "Image built successfully. The path to the image is shown above."
