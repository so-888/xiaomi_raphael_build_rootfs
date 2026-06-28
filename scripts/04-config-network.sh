#!/bin/bash
set -e

HOSTNAME="${HOSTNAME:-xiaomi-raphael}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04] 🌐 配置网络和主机名"

# DNS 由 systemd-resolved + NetworkManager 按链路下发（GSM 用运营商 DNS）。
# 勿在此写死 nameserver，否则移动数据连上后 ping 域名会失败。
rm -f rootdir/etc/resolv.conf
ln -sf ../run/systemd/resolve/stub-resolv.conf rootdir/etc/resolv.conf

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04]   └─ 主机名: ${HOSTNAME}"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04]   └─ DNS: systemd-resolved stub (per-link, 见 10b)"

echo "${HOSTNAME}" > rootdir/etc/hostname
echo "127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}" > rootdir/etc/hosts

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [04] ✅ 网络配置完成"