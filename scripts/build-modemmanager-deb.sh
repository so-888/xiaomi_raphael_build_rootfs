#!/bin/bash
# 交叉编译 ModemManager QRTR deb（含 QMAPv4 补丁，禁用 v5）并复制到 rootfs debs/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_OUT_DIR="${1:-$SCRIPT_DIR/../debs}"
MM_DIR="${MM_DIR:-$SCRIPT_DIR/../../基带测试/mm/mm}"

if [ ! -d "$MM_DIR" ]; then
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ❌ ModemManager 源码目录不存在: $MM_DIR" >&2
	echo "    可通过环境变量 MM_DIR 指定路径" >&2
	exit 1
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] 📡 编译 ModemManager (QRTR + QMAPv4 patch)..."
echo "[$(date +'%Y-%m-%d %H:%M:%S')]    源码: $MM_DIR"
echo "[$(date +'%Y-%m-%d %H:%M:%S')]    输出: $DEB_OUT_DIR"

mkdir -p "$DEB_OUT_DIR"
(
	cd "$MM_DIR"
	./build.sh
	./make-deb.sh
)

MM_DEB="$(ls -1 "$MM_DIR"/debs/modemmanager-qrtr-sm8150_*_jammy_arm64.deb | sort -V | tail -1)"
[ -f "$MM_DEB" ] || { echo "❌ 未找到编译产物" >&2; exit 1; }

# 只保留最新版 deb，避免 06 安装时 glob 歧义
rm -f "$DEB_OUT_DIR"/modemmanager-qrtr-sm8150_*_jammy_arm64.deb
cp "$MM_DEB" "$DEB_OUT_DIR/"
cp "$MM_DIR/debs/install-modemmanager-qrtr.sh" "$DEB_OUT_DIR/" 2>/dev/null || true

echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $(basename "$MM_DEB") → $DEB_OUT_DIR/"
