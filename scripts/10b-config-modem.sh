#!/bin/bash
set -e

# 固化基带（modem）运行态修复：
#
#   1) raphael-sim-init(.sh+.service) —— 把物理 SIM 卡槽映射到逻辑槽并在 MM 之前
#      绑定 USIM 供应会话，解决"无 SIM"。enable。
#   2) raphael-no-mobile-data(.sh+.service) —— 开机关闭 GSM autoconnect，避免开机
#      误拨移动数据。enable。
#   3) ModemManager.service.d/raphael.conf —— MM 在 sim-init 之后启动。
#   4) 99-raphael-modem-norecover.rules —— 禁用 modem remoteproc 就地恢复，modem
#      崩溃时保持 "crashed" 而不拖垮整机（B 类安全网）。
#
# 注：不再安装 raphael-modem-offline（00161 固件 + IPA 补丁已解决 RF/数据面崩溃，
#     该服务会把 RF 永久锁 offline 导致无法注册）。
#     内核 IPA 修复在 patchs/raphael.patch；00161 固件在 firmware-xiaomi-raphael.deb。
#     移动数据需 qrtr8+ ModemManager（QMAPv4 patch，见 06 安装 + patches/modemmanager/）。
#   5) NetworkManager + systemd-resolved DNS —— resolv.conf 走 stub，GSM 连上后
#      自动使用运营商 DNS（勿写死 1.1.1.1，否则 ping 域名失败）。

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b] 📡 配置基带 modem 服务 + 崩溃隔离"

install -d rootdir/usr/local/sbin
install -d rootdir/etc/systemd/system/ModemManager.service.d
install -d rootdir/etc/udev/rules.d

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ raphael-sim-init.sh"
cat > rootdir/usr/local/sbin/raphael-sim-init.sh << 'EOF'
#!/bin/sh
# Raphael: map physical SIM slot and bind USIM provisioning session before MM.
set -eu

QRTR_DEV=qrtr://0
PHYSICAL_SLOT=2
MAX_WAIT=120

wait_modem() {
	for rp in /sys/class/remoteproc/remoteproc*; do
		[ -f "$rp/name" ] || continue
		if [ "$(cat "$rp/name")" = modem ]; then
			i=0
			while [ "$i" -lt "$MAX_WAIT" ]; do
				state=$(cat "$rp/state" 2>/dev/null || echo unknown)
				case "$state" in
				running)
					echo "raphael-sim-init: modem running after ${i}s"
					return 0
					;;
				crashed)
					echo "raphael-sim-init: modem state=crashed" >&2
					return 1
					;;
				esac
				i=$((i + 1))
				sleep 1
			done
			echo "raphael-sim-init: modem not running after ${MAX_WAIT}s (last state=$state)" >&2
			return 1
		fi
	done
	echo "raphael-sim-init: modem remoteproc not found" >&2
	return 1
}

wait_qmi() {
	i=0
	while [ "$i" -lt "$MAX_WAIT" ]; do
		if qmicli -p -d "$QRTR_DEV" --dms-get-ids >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

if ! wait_modem; then
	exit 1
fi

if ! wait_qmi; then
	echo "raphael-sim-init: QMI not ready" >&2
	exit 1
fi

# Raphael single tray is wired to physical slot 2.
qmicli -p -d "$QRTR_DEV" --uim-switch-slot="$PHYSICAL_SLOT" || true
sleep 1

LOGICAL_SLOT=$(qmicli -p -d "$QRTR_DEV" --uim-get-slot-status 2>/dev/null | awk -v ps="$PHYSICAL_SLOT" '
	$0 ~ "Physical slot " ps ":" { active=1 }
	active && /Logical slot:/ { print $3; exit }
')
[ -z "$LOGICAL_SLOT" ] && LOGICAL_SLOT=1

QMI_CARDS=$(qmicli -p -d "$QRTR_DEV" --uim-get-card-status)

i=0
while ! printf '%s' "$QMI_CARDS" | grep -Fq "Card state: 'present'"; do
	[ "$i" -ge 15 ] && break
	sleep 1
	i=$((i + 1))
	QMI_CARDS=$(qmicli -p -d "$QRTR_DEV" --uim-get-card-status)
done

if ! printf '%s' "$QMI_CARDS" | grep -Fq "Card state: 'present'"; then
	echo "raphael-sim-init: no SIM present" >&2
	exit 1
fi

if ! printf '%s' "$QMI_CARDS" | grep -Fq "Primary GW:   session doesn't exist"; then
	qmicli -p -d "$QRTR_DEV" \
		--uim-change-provisioning-session='activate=no,session-type=primary-gw-provisioning' \
		|| true
	QMI_CARDS=$(qmicli -p -d "$QRTR_DEV" --uim-get-card-status)
fi

AID=$(printf '%s' "$QMI_CARDS" | grep "usim (2)" -m1 -A3 \
	| grep -oE 'A0:[0-9A-F:]+' | head -1 | tr -d ':')
[ -z "$AID" ] && AID=A0000000871002FF86FFFF89FFFFFFFF

echo "raphael-sim-init: physical=$PHYSICAL_SLOT logical=$LOGICAL_SLOT aid=$AID"

qmicli -p -d "$QRTR_DEV" --uim-sim-power-on="$LOGICAL_SLOT" || true
qmicli -p -d "$QRTR_DEV" \
	--uim-change-provisioning-session="slot=${LOGICAL_SLOT},activate=yes,session-type=primary-gw-provisioning,aid=${AID}"

# MM may have started with sim-missing if provisioning was late; refresh once.
systemctl try-restart ModemManager.service --no-block 2>/dev/null || true

exit 0
EOF
chmod 755 rootdir/usr/local/sbin/raphael-sim-init.sh

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ raphael-no-mobile-data.sh"
cat > rootdir/usr/local/sbin/raphael-no-mobile-data.sh << 'EOF'
#!/bin/sh
# Keep cellular data disconnected at boot (user must manually connect).
set -eu

sleep 2

for u in $(nmcli -t -f UUID,TYPE connection show | awk -F: '$2=="gsm"{print $1}'); do
	nmcli connection modify "$u" connection.autoconnect no 2>/dev/null || true
done

nmcli device disconnect qrtr0 2>/dev/null || true

echo "raphael-no-mobile-data: gsm autoconnect disabled, qrtr0 disconnected"
EOF
chmod 755 rootdir/usr/local/sbin/raphael-no-mobile-data.sh

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ systemd units"
cat > rootdir/etc/systemd/system/raphael-sim-init.service << 'EOF'
[Unit]
Description=Raphael SIM slot 1 power-on via QMI
After=remoteproc.target sys-subsystem-net-devices-rmnet_ipa0.device
Before=ModemManager.service
Wants=remoteproc.target

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=24
ExecStart=/usr/local/sbin/raphael-sim-init.sh

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/systemd/system/raphael-no-mobile-data.service << 'EOF'
[Unit]
Description=Raphael disable GSM autoconnect at boot
After=NetworkManager.service ModemManager.service
Before=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/raphael-no-mobile-data.sh

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/systemd/system/ModemManager.service.d/raphael.conf << 'EOF'
[Unit]
After=raphael-sim-init.service
EOF

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ udev modem norecover 规则"
cat > rootdir/etc/udev/rules.d/99-raphael-modem-norecover.rules << 'EOF'
# Raphael: modem(mpss) SSR recovery via TZ pas_shutdown hangs in EL3 when
# RF firmware asserts, wedging the CPU and hard-locking the whole system.
# Disable in-place recovery so a modem crash stays contained (modem ends up
# in "crashed" state) instead of dragging down the machine. See
# RAPHAEL-MODEM-STATUS.md 3.1A. Remove once RF (A-fix) makes modem stable.
SUBSYSTEM=="remoteproc", ACTION=="add", ATTR{name}=="modem", ATTR{recovery}="disabled"
EOF

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ DNS: systemd-resolved + NM (GSM 运营商 DNS)"
install -d rootdir/etc/NetworkManager/conf.d
install -d rootdir/etc/systemd/resolved.conf.d

cat > rootdir/etc/NetworkManager/conf.d/raphael-dns.conf << 'EOF'
[main]
# Push per-link DNS (incl. GSM bearer) into systemd-resolved.
dns=systemd-resolved
systemd-resolved=true
EOF

cat > rootdir/etc/systemd/resolved.conf.d/raphael.conf << 'EOF'
[Resolve]
# Fallback when no interface provides DNS (e.g. USB debug only).
FallbackDNS=114.114.114.114 223.5.5.5
DNSStubListener=yes
EOF

chroot rootdir systemctl enable systemd-resolved.service

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ 启用服务"
chroot rootdir systemctl enable raphael-sim-init.service
chroot rootdir systemctl enable raphael-no-mobile-data.service

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b] ✅ 基带配置完成"
