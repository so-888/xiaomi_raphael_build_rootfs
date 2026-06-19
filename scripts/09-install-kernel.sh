#!/bin/bash
set -e

KERNEL_DEBS_DIR="${KERNEL_DEBS_DIR:-.}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09] 🧠 安装内核"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 内核包目录: ${KERNEL_DEBS_DIR}"

cp ${KERNEL_DEBS_DIR}/*-xiaomi-raphael.deb rootdir/tmp/

chroot rootdir mkdir -p /etc/initramfs-tools/hooks
chroot rootdir tee /etc/initramfs-tools/hooks/a630_sqe << 'EOF'
#!/bin/sh
PREREQS=""
case $1 in
prereqs) echo "$PREREQS"; exit 0;;
esac
. /usr/share/initramfs-tools/hook-functions

# 复制所有 a6 开头的固件
for fw in /lib/firmware/qcom/a6*; do
    [ -e "$fw" ] && copy_file firmware "$fw"
done

# 复制所有 ipa 开头的固件
for fw in /lib/firmware/qcom/ipa*; do
    [ -e "$fw" ] && copy_file firmware "$fw"
done
EOF

chroot rootdir chmod +x /etc/initramfs-tools/hooks/a630_sqe

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 firmware..."
chroot rootdir dpkg --force-all -i /tmp/firmware-xiaomi-raphael.deb

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 linux-image..."
chroot rootdir dpkg --force-all -i /tmp/linux-image-xiaomi-raphael.deb

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 安装 linux-headers..."
chroot rootdir dpkg --force-all -i /tmp/linux-headers-xiaomi-raphael.deb

rm rootdir/tmp/*-xiaomi-raphael.deb

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09]   └─ 更新 initramfs..."
chroot rootdir update-initramfs -c -k all

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [09] ✅ 内核安装完成"
