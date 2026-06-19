#!/bin/bash
set -e

IMAGE_SIZE="${IMAGE_SIZE:-3G}"
IMAGE_NAME="${IMAGE_NAME:-rootfs.img}"
BOOT_NAME="${BOOT_NAME:-xiaomi-k20pro-boot.img}"
BOOT_SIZE="${BOOT_SIZE:-222M}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] 📦 创建根文件系统镜像 (${IMAGE_SIZE})"

truncate -s ${IMAGE_SIZE} ${IMAGE_NAME}
mkfs.ext4 ${IMAGE_NAME}
mkdir -p rootdir
mount -o loop ${IMAGE_NAME} rootdir
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] ✅ 根文件系统镜像创建完成"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] 📦 创建Boot镜像 (${BOOT_SIZE})"
truncate -s ${BOOT_SIZE} ${BOOT_NAME}
mkfs.fat -F 32 -S 4096 -s 1 -v -n "efi" ${BOOT_NAME}
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] ✅ Boot镜像创建完成"
