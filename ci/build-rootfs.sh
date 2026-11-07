#!/bin/bash
# Build a bootable arm64 Ubuntu rootfs for Xiaomi Mi 10S (thyme).
#
# Requires: root, mmdebstrap, zstd, a native arm64 host (or qemu binfmt).
# The libcamera v0.7.0 install tree must be staged via LIBCAMERA_STAGE.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

SUITE="${SUITE:-resolute}"
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
DESKTOP="${DESKTOP:-false}"
THYME_USER="${THYME_USER:-thyme}"
THYME_PASSWORD="${THYME_PASSWORD:-thyme}"
THYME_HOSTNAME="${THYME_HOSTNAME:-thyme}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PSK="${WIFI_PSK:-}"
ROOT_PART="${ROOT_PART:-/dev/sda38}"
LIBCAMERA_STAGE="${LIBCAMERA_STAGE:-}"
VENDOR_FIRMWARE_DIR="${VENDOR_FIRMWARE_DIR:-}"
if [ -n "$VENDOR_FIRMWARE_DIR" ]; then
    VENDOR_FIRMWARE_DIR="$(readlink -f "$VENDOR_FIRMWARE_DIR")"
    if [ ! -d "$VENDOR_FIRMWARE_DIR/lib/firmware" ]; then
        echo "ERROR: $VENDOR_FIRMWARE_DIR does not contain lib/firmware." >&2
        exit 1
    fi
fi

OUT="${OUT:-$REPO/out-rootfs}"
ROOTFS="${ROOTFS:-$REPO/work/rootfs-$SUITE}"

if [ -z "$LIBCAMERA_STAGE" ] || [ ! -d "$LIBCAMERA_STAGE" ]; then
    echo "ERROR: set LIBCAMERA_STAGE to the DESTDIR of 'meson install' for libcamera." >&2
    exit 1
fi

PKGS=(
    systemd systemd-sysv systemd-timesyncd dbus udev sudo
    openssh-server network-manager wpasupplicant iw rfkill
    iproute2 iputils-ping curl ca-certificates nano less
    kmod pciutils usbutils i2c-tools v4l-utils
    alsa-utils alsa-ucm-conf
    pipewire pipewire-bin pipewire-pulse pipewire-alsa pipewire-audio
    wireplumber libspa-0.2-modules libspa-0.2-libcamera libcamera-tools
    libgl1-mesa-dri mesa-vulkan-drivers mesa-utils
    linux-firmware bluez wireless-regdb fonts-dejavu-core
)
if [ "$DESKTOP" = "true" ]; then
    PKGS+=(ubuntu-desktop-minimal gnome-tweaks)
fi
INCLUDE="$(IFS=,; echo "${PKGS[*]}")"

echo "==> mmdebstrap $SUITE (desktop=$DESKTOP) -> $ROOTFS"
sudo rm -rf "$ROOTFS"
mkdir -p "$(dirname "$ROOTFS")"
sudo mmdebstrap \
    --architectures=arm64 \
    --components=main,universe \
    --variant=apt \
    --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
    --aptopt='APT::Install-Recommends "false"' \
    --include="$INCLUDE" \
    "$SUITE" "$ROOTFS" "$MIRROR"

echo "==> install thyme overlay"
sudo env \
    THYME_USER="$THYME_USER" \
    THYME_PASSWORD="$THYME_PASSWORD" \
    THYME_HOSTNAME="$THYME_HOSTNAME" \
    SSH_PUBKEY="$SSH_PUBKEY" \
    WIFI_SSID="$WIFI_SSID" \
    WIFI_PSK="$WIFI_PSK" \
    ROOT_PART="$ROOT_PART" \
    THYME_DESKTOP="$DESKTOP" \
    LIBCAMERA_STAGE="$(readlink -f "$LIBCAMERA_STAGE")" \
    VENDOR_FIRMWARE_DIR="$VENDOR_FIRMWARE_DIR" \
    bash "$HERE/rootfs/chroot-setup.sh" "$ROOTFS"

echo "==> verify rootfs"
sudo chroot "$ROOTFS" /bin/bash -euc '
    getent passwd thyme >/dev/null
    test -f /etc/fstab
    test -f /opt/thyme-camera-focus-color/lib/libcamera.so.0.7.0
    if ldd /opt/thyme-camera-focus-color/lib/libcamera.so.0.7.0 | grep -q "not found"; then
        echo "libcamera has unresolved dependencies" >&2
        exit 1
    fi
    systemctl is-enabled NetworkManager.service >/dev/null
    systemctl is-enabled ssh.service >/dev/null
    test -e /var/lib/systemd/linger/thyme
'
if [ -n "$VENDOR_FIRMWARE_DIR" ]; then
    sudo test -f "$ROOTFS/lib/firmware/qcom/sm8250/umi/adsp.mbn"
fi

echo "==> clean package caches"
sudo chroot "$ROOTFS" /bin/bash -c \
    'apt-get clean; rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/*'

mkdir -p "$OUT"
echo "==> package manifest"
sudo chroot "$ROOTFS" dpkg-query -W -f='${Package}\t${Version}\n' | sort > "$OUT/manifest.txt"

TAG="$(date +%Y%m%d)"
NAME="thyme-rootfs-${SUITE}$([ "$DESKTOP" = "true" ] && echo -desktop)-${TAG}"
echo "==> pack $NAME.tar.zst"
sudo tar --numeric-owner --xattrs --acls --zstd \
    -C "$ROOTFS" -cf "$OUT/$NAME.tar.zst" .
sudo chown "$(id -u):$(id -g)" "$OUT/$NAME.tar.zst"

{
    echo "thyme rootfs build"
    echo "suite:        $SUITE"
    echo "mirror:       $MIRROR"
    echo "desktop:      $DESKTOP"
    echo "hostname:     $THYME_HOSTNAME"
    echo "user:         $THYME_USER"
    echo "root part:    $ROOT_PART"
    echo "kernel:       mainline thyme 7.2.0-rc5-sm8250-modem (no initramfs)"
    echo "libcamera:    v0.7.0 staged from CI build"
    if [ -n "$VENDOR_FIRMWARE_DIR" ]; then
        echo "firmware:     vendor blobs installed from $VENDOR_FIRMWARE_DIR"
    else
        echo "firmware:     linux-firmware only; vendor blobs NOT installed"
    fi
    echo "packages:     $(wc -l < "$OUT/manifest.txt")"
    echo "built:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/$NAME.info.txt"

cat > "$OUT/INSTALL.zh-CN.txt" <<EOF
thyme rootfs 安装说明
=====================

镜像包: $NAME.tar.zst

前提
----
- boot 镜像的 cmdline 必须包含 root=$ROOT_PART（上游模板默认为 /dev/sda38）。
- 内核已内置 UFS/SCSI/ext4，不需要 initramfs。
- 写入操作会清空目标分区，请先确认分区号并备份。

写入分区
--------
  sudo mkfs.ext4 $ROOT_PART
  sudo mount $ROOT_PART /mnt
  sudo tar --zstd --numeric-owner -xpf $NAME.tar.zst -C /mnt
  sudo umount /mnt

首次启动
--------
- 用户: $THYME_USER  密码: 见构建输入（默认 thyme，请立即修改）
- SSH: ssh $THYME_USER@<手机 IP>（需要已配置 Wi-Fi 或有线网络）
- 串口: ttyMSM0 已启用 getty
- 桌面: $([ "$DESKTOP" = "true" ] && echo "已安装 ubuntu-desktop-minimal" || echo "未安装，仅控制台/SSH")

固件
----
原厂 blobs 需要从 stock 固件提取。$([ -n "$VENDOR_FIRMWARE_DIR" ] && echo "本包已包含 CI 输入提供的 vendor blobs。" || echo "本包不含原厂 blobs，只带 linux-firmware。")
提取工具:
  python3 ci/rootfs/extract-stock-firmware.py --rom-dir <stock-rom> --out stock-firmware
  sudo cp -a stock-firmware/out/lib/firmware/. /mnt/lib/firmware/
或用 firmware_url 输入重新触发构建。
运行 sudo thyme-check-firmware 查看缺项，详见
/usr/local/share/thyme/firmware/README.zh-CN.md。

相机
----
自定义 libcamera 位于 /opt/thyme-camera-focus-color。当发行版自带
libcamera 的 ABI 为 0.7 时，PipeWire/WirePlumber 的 LD_LIBRARY_PATH
drop-in 会自动启用；否则放在同目录的 rootfs-config/ 中，需要自行评估。
EOF

(cd "$OUT" && sha256sum "$NAME.tar.zst" manifest.txt > SHA256SUMS)

echo "==> done"
ls -lh "$OUT/$NAME.tar.zst"
cat "$OUT/SHA256SUMS"
