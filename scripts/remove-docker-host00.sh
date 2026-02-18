#!/usr/bin/env bash
# remove-docker-host00.sh — Removes Docker from host00 (Arch Linux)
#
# Usage:
#   sudo bash scripts/remove-docker-host00.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run with sudo: sudo bash $0"
    exit 1
fi

echo "=== Stopping Docker ==="
systemctl stop docker.socket docker.service 2>/dev/null || true
systemctl disable docker.socket docker.service 2>/dev/null || true

echo "=== Removing Docker packages ==="
pacman -Rns --noconfirm docker docker-buildx docker-compose lazydocker 2>/dev/null || true

echo "=== Unmounting stale Docker filesystems ==="
mount | grep docker | awk '{print $3}' | sort -r | while read -r mnt; do
    echo "  umount -l ${mnt}"
    umount -l "${mnt}" 2>/dev/null || true
done

echo "=== Removing Docker data ==="
rm -rf /var/lib/docker
rm -rf /var/lib/containerd
rm -rf /etc/docker

echo "=== Removing Docker network interfaces ==="
ip link delete docker0 2>/dev/null || true
for iface in $(ip -o link show | grep 'br-' | awk -F': ' '{print $2}'); do
    ip link delete "${iface}" 2>/dev/null || true
done

echo "=== Removing Docker group ==="
groupdel docker 2>/dev/null || true

echo ""
echo "Done. Docker removed from host00."
