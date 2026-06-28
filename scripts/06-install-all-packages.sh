#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
DEB_OUT_DIR="${DEB_OUT_DIR:-$SCRIPT_DIR/../debs}"

. "$CONFIG_DIR/build-config.sh"

SYSTEM_TYPE="${SYSTEM_TYPE:-ubuntu-server}"
DESKTOP_ENV="${DESKTOP_ENV:-}"
DEBIAN_VERSION="${DEBIAN_VERSION:-trixie}"
UBUNTU_VERSION="${UBUNTU_VERSION:-resolute}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] 📦 安装软件包"

export DEBIAN_FRONTEND=noninteractive

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 更新系统包..."
chroot rootdir apt-get update
chroot rootdir apt-get upgrade -y

BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano gpgv gnupg gpgv2 grub2-common ca-certificates kmod debconf wireless-regdb less procps psmisc iputils-ping systemd udev dbus net-tools rfkill wireless-tools network-manager initramfs-tools chrony curl wget locales tzdata iproute2 zram-tools"

if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then 
   BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager systemd-boot initramfs-tools chrony curl wget locales tzdata fonts-wqy-microhei dnsmasq iptables iproute2 zram-tools udev dbus kmod ca-certificates wireless-regdb"
elif [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
	if [[ "$SYSTEM_TYPE" == *"server"* ]]; then
		BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager net-tools initramfs-tools chrony curl wget locales tzdata dnsmasq iptables iproute2 zram-tools udev dbus kmod ca-certificates wireless-regdb"
	else
		BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager net-tools grub-efi-arm64-signed initramfs-tools chrony curl wget locales tzdata dnsmasq iptables iproute2 zram-tools udev dbus kmod ca-certificates wireless-regdb"
	fi
fi

# 通用外设 + Qualcomm 运行时依赖（Jammy 源中可安装的）
DEVICE_PACKAGES="wpasupplicant iw iproute2 alsa-ucm-conf alsa-utils power-profiles-daemon gpsd gpsd-clients libmbim-utils liblzma5"


if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    case "$DESKTOP_ENV" in
        "gnome")
            if [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
                DESKTOP_PACKAGES="ubuntu-desktop"
            elif [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
                DESKTOP_PACKAGES="gnome"
            fi
            ;;
        "phosh-core")
            DESKTOP_PACKAGES="phosh-core"
            ;;
        "phosh-full")
            DESKTOP_PACKAGES="phosh-full"
            ;;
        "phosh-phone")
            DESKTOP_PACKAGES="phosh-phone"
            ;;
        *)
            DESKTOP_PACKAGES=""
            ;;
    esac
else
    DESKTOP_PACKAGES=""
fi

# Plymouth provides the vendor boot-logo animation (script.so plugin, drm /
# frame-buffer renderers and the initramfs hook). Installed for every variant
# (incl. server) so the splash works; the theme itself is set up in
# 08b-config-plymouth.sh before the initramfs is generated in 09.
PLYMOUTH_PACKAGES="plymouth plymouth-themes plymouth-label"

ALL_PACKAGES="$BASE_PACKAGES $DEVICE_PACKAGES $DESKTOP_PACKAGES $PLYMOUTH_PACKAGES"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 基础包: $(echo "$BASE_PACKAGES" | tr ' ' ', ')"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 设备包: $(echo "$DEVICE_PACKAGES" | tr ' ' ', ')"
if [ -n "$DESKTOP_PACKAGES" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 桌面包: $(echo "$DESKTOP_PACKAGES" | tr ' ' ', ')"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 开始安装（这可能需要几分钟...）"
chroot rootdir apt-get install -y $ALL_PACKAGES
if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 修复 Debian dpkg 错误"
    chroot rootdir dpkg --remove --force-remove-reinstreq shim-signed 2>/dev/null || true
    chroot rootdir dpkg --purge shim-signed 2>/dev/null || true
    chroot rootdir dpkg --configure -a 2>/dev/null || true
    chroot rootdir apt-get -f install -y 2>/dev/null || true
fi

install_qcom_local_debs() {
	local deb_dir="$1"
	local required=(
		libqrtr1_*_arm64.deb
		qrtr-tools_*_arm64.deb
		rmtfs_*_arm64.deb
		protection-domain-mapper_*_arm64.deb
		tqftpserv_*_arm64.deb
		audioreach-topology_*_all.deb
		modemmanager-qrtr-sm8150_*_jammy_arm64.deb
	)

	if [ ! -d "$deb_dir" ]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ deb 目录不存在: $deb_dir" >&2
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]    请先运行: $SCRIPT_DIR/docker-build.sh" >&2
		exit 1
	fi

	local missing=0
	for pattern in "${required[@]}"; do
		if ! compgen -G "$deb_dir/$pattern" >/dev/null; then
			echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 缺少: $deb_dir/$pattern" >&2
			missing=1
		fi
	done
	if [ "$missing" -ne 0 ]; then
		exit 1
	fi

	local mm_deb
	mm_deb="$(ls -1 "$deb_dir"/modemmanager-qrtr-sm8150_*_jammy_arm64.deb 2>/dev/null | sort -V | tail -1)"
	if [ -z "$mm_deb" ]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 缺少: $deb_dir/modemmanager-qrtr-sm8150_*_jammy_arm64.deb" >&2
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]    请先运行: $SCRIPT_DIR/build-modemmanager-deb.sh" >&2
		exit 1
	fi
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ ModemManager: $(basename "$mm_deb") (QMAPv4 patch, 禁用 v5)"

chroot rootdir sh -c "apt-get remove -y --allow-remove-essential \
	modemmanager libqmi-utils libqmi-proxy libqmi-glib5"
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装本地 Qualcomm deb: $deb_dir"
	mkdir -p rootdir/tmp/qcom-debs
	# 按依赖顺序：libqrtr1 -> tools/rmtfs/pd-mapper/tqftpserv -> topology -> MM
	cp "$deb_dir"/libqrtr1_*_arm64.deb rootdir/tmp/qcom-debs/
	cp "$deb_dir"/qrtr-tools_*_arm64.deb \
		"$deb_dir"/rmtfs_*_arm64.deb \
		"$deb_dir"/protection-domain-mapper_*_arm64.deb \
		"$deb_dir"/tqftpserv_*_arm64.deb \
		"$deb_dir"/audioreach-topology_*_all.deb \
		rootdir/tmp/qcom-debs/
	cp "$mm_deb" rootdir/tmp/qcom-debs/

	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/libqrtr1_*_arm64.deb"
	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/qrtr-tools_*_arm64.deb \
		/tmp/qcom-debs/rmtfs_*_arm64.deb \
		/tmp/qcom-debs/protection-domain-mapper_*_arm64.deb \
		/tmp/qcom-debs/tqftpserv_*_arm64.deb"
	chroot rootdir sh -c '
		export DEBIAN_FRONTEND=noninteractive
		dpkg -i --auto-deconfigure /tmp/qcom-debs/modemmanager-qrtr-sm8150_*.deb
		apt-get install -f -y
	'
	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/audioreach-topology_*_all.deb"
	chroot rootdir apt-get install -f -y
	rm -rf rootdir/tmp/qcom-debs

	mkdir -p rootdir/var/lib/rmtfs

	# qrtr-ns 在 lib/systemd/system；rmtfs/pd-mapper 在 usr/lib/systemd/system
	chroot rootdir systemctl enable qrtr-ns.service
	chroot rootdir systemctl disable rmtfs-dir.service 2>/dev/null || true
	chroot rootdir systemctl mask rmtfs-dir.service 2>/dev/null || true
	chroot rootdir systemctl unmask rmtfs.service 2>/dev/null || true
	#chroot rootdir systemctl enable rmtfs-dir.service pd-mapper.service tqftpserv.service
	chroot rootdir systemctl enable rmtfs.service pd-mapper.service tqftpserv.service
	# 避免与 rmtfs 主服务竞态（与 Debian 打包策略一致）

}

install_qcom_local_debs "$DEB_OUT_DIR"


# 修改服务配置
if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service 2>/dev/null || true
fi

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    if [ "$DESKTOP_ENV" = "gnome" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 配置 GDM 自动登录"
        cat > rootdir/etc/gdm3/custom.conf << 'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=user
EOF
		chroot rootdir systemctl disable brltty.service
		chroot rootdir systemctl mask brltty.service
        #chroot rootdir gsettings set org.gnome.mutter auto-rotate-screen true || true

        # Ubuntu 的 apt firefox 是 snap 过渡包，chroot 构建无 snapd → 无图标/无任务栏。
        # 改用 firefox-esr 原生 deb，并写入 dock 收藏与桌面快捷方式。
        if [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装 Firefox (firefox-esr deb, 非 snap)"
            chroot rootdir apt-get remove -y firefox 2>/dev/null || true
            chroot rootdir apt-get install -y firefox-esr

            if ! chroot rootdir dpkg -s firefox-esr >/dev/null 2>&1; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ firefox-esr 未安装成功，终止构建"
                exit 1
            fi

            # 修正 .desktop：确保显示在应用菜单/任务栏，WMClass 与 ubuntu-dock 匹配
            install -d rootdir/etc/skel/Desktop
            cat > rootdir/usr/share/applications/firefox-esr-custom.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Name=Firefox
Comment=Browse the Web
GenericName=Web Browser
Keywords=Internet;WWW;Browser;Web;Explorer
Exec=firefox-esr %u
Terminal=false
X-MultipleArgs=false
Type=Application
Icon=firefox-esr
Categories=GNOME;GTK;Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/geo;x-scheme-handler/mailto;
StartupNotify=true
StartupWMClass=Firefox-esr
Actions=new-window;new-private-window;

[Desktop Action new-window]
Name=Open a New Window
Exec=firefox-esr -new-window

[Desktop Action new-private-window]
Name=Open a New Private Window
Exec=firefox-esr -private-window
EOF
            cp rootdir/usr/share/applications/firefox-esr-custom.desktop \
               rootdir/etc/skel/Desktop/firefox-esr-custom.desktop
            chmod 755 rootdir/etc/skel/Desktop/firefox-esr-custom.desktop

            # 写入 ubuntu-dock 默认收藏（含 Firefox），首次登录即固定到任务栏
            install -d rootdir/etc/dconf/db/local.d rootdir/etc/dconf/profile
            cat > rootdir/etc/dconf/db/local.d/01-firefox-favorite << 'EOF'
[org/gnome/shell]
favorite-apps=['firefox-esr-custom.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Software.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Calculator.desktop', 'org.gnome.Terminal.desktop', 'gnome-control-center.desktop']

[org/gnome/desktop/default-applications/web]
browser='firefox-esr.desktop'
EOF
            cat > rootdir/etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
            chroot rootdir dconf update 2>/dev/null || true
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ Firefox (firefox-esr) 已配置 ✅"
        fi
    fi
fi

# K20 专属 ALSA UCM 声卡路由配置：设备声音正常的关键（依赖 alsa-ucm-conf）。
# 用 apt-get install ./deb 安装以自动解析依赖（dpkg -i 不解析依赖会留下未配置状态）。
# 桌面镜像若提供了该 deb 却装不上，直接终止构建——否则出来的镜像声音异常。
if [ -f "alsa-xiaomi-raphael.deb" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装 ALSA 配置 (alsa-xiaomi-raphael)"
    cp alsa-xiaomi-raphael.deb rootdir/tmp/
    chroot rootdir apt-get install -y /tmp/alsa-xiaomi-raphael.deb \
        || chroot rootdir sh -c 'dpkg -i /tmp/alsa-xiaomi-raphael.deb; apt-get install -fy'
    rm rootdir/tmp/alsa-xiaomi-raphael.deb

    if ! chroot rootdir dpkg -s alsa-xiaomi-raphael >/dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ alsa-xiaomi-raphael 未安装成功，设备声音会异常，终止构建"
        exit 1
    fi
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ alsa-xiaomi-raphael 已安装 ✅"
elif [[ "$SYSTEM_TYPE" == *"phosh"* || "$SYSTEM_TYPE" == *"gnome"* ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 桌面镜像缺少 alsa-xiaomi-raphael.deb，设备声音会异常，终止构建"
    exit 1
fi

# ================================================================
# 音频：Raphael 设备专用策略（配合 alsa-xiaomi-raphael UCM）
# ----------------------------------------------------------------
# 扬声器 TFA9874 在 UCM 中没有硬件音量控件，PipeWire 默认走 HW mixer
# 路径会导致音量极小/几乎无声；PulseAudio 走软件音量则正常。
#
# - 低版本（jammy 等仍提供 pulseaudio 包）：用 PulseAudio 作音频服务。
#   只 mask PipeWire 用户服务，绝不 purge 包（purge 会级联卸载 GNOME 桌面）。
# - 高版本（noble 等无独立 pulseaudio 包）：保留 PipeWire，注入 WirePlumber
#   soft-mixer 配置，强制软件音量 + 默认 100%。
# ================================================================
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 配置音频服务 (Raphael 适配)"

_use_pulseaudio=false
if chroot rootdir apt-cache show pulseaudio >/dev/null 2>&1; then
    _use_pulseaudio=true
fi

if [ "$_use_pulseaudio" = true ]; then
    # ── 路径 A：PulseAudio（jammy / bookworm 等）────────────────────────
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 使用 PulseAudio（本发行版可用，避免 PipeWire 音量异常）"
    chroot rootdir apt-get install -y pulseaudio pulseaudio-utils

    # 屏蔽 PipeWire 用户服务（保留包以满足桌面依赖，但不自启）
    for unit in pipewire.socket pipewire-pulse.socket pipewire.service \
                pipewire-pulse.service wireplumber.service \
                pipewire-media-session.service; do
        chroot rootdir systemctl --global mask "$unit" 2>/dev/null || true
    done
    chroot rootdir systemctl --global unmask pulseaudio.service pulseaudio.socket 2>/dev/null || true
    chroot rootdir systemctl --global enable pulseaudio.service pulseaudio.socket 2>/dev/null || true

else
    # ── 路径 B：PipeWire + soft-mixer 修复（noble / resolute 等）────────
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 使用 PipeWire + soft-mixer 修复（本发行版无独立 pulseaudio）"

    PW_CANDIDATES="pipewire pipewire-pulse pipewire-audio pipewire-alsa \
        pipewire-audio-client-libraries libspa-0.2-bluetooth wireplumber"
    PW_INSTALL=""
    for p in $PW_CANDIDATES; do
        if chroot rootdir apt-cache show "$p" >/dev/null 2>&1; then
            PW_INSTALL="$PW_INSTALL $p"
        fi
    done
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装 PipeWire 包:$PW_INSTALL"
    chroot rootdir apt-get install -y $PW_INSTALL

    # TFA9874 扬声器无 HW 音量控件 → 强制软件混音 + 输出节点默认 100% 音量
    install -d rootdir/etc/wireplumber/wireplumber.conf.d
    cat > rootdir/etc/wireplumber/wireplumber.conf.d/50-raphael-soft-mixer.conf << 'EOF'
# Raphael (TFA9874): speaker has no ALSA HW volume control in UCM.
# PipeWire defaults to HW mixer path → near-silent output.
# Force software volume and set default output to 100%.
monitor.alsa.rules = [
  {
    matches = [ { device.name = "~alsa_card.*" } ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
        api.alsa.use-ucm = true
      }
    }
  }
]
monitor.rules = [
  {
    matches = [ { node.name = "~alsa_output.*" } ]
    actions = {
      update-props = {
        volume = 1.0
      }
    }
  }
]
EOF

    chroot rootdir systemctl --global unmask \
        pipewire.socket pipewire-pulse.socket pipewire.service \
        pipewire-pulse.service wireplumber.service 2>/dev/null || true
    chroot rootdir systemctl --global enable \
        pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 音频配置完成 ✅"

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    if [[ "$DESKTOP_ENV" == phosh* ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 启用 Phosh 服务"
        chroot rootdir systemctl enable phosh
    fi
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ✅ 软件包安装完成"
