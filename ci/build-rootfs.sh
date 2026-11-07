#!/bin/bash
# Build a bootable arm64 Ubuntu rootfs for Xiaomi Mi 10S (thyme).
#
# Requires: root, mmdebstrap, zstd, e2fsprogs, a native arm64 host (or qemu binfmt).
# The libcamera v0.7.0 install tree must be staged via LIBCAMERA_STAGE.
#
# IMAGE_FORMAT:
#   tar   - rootfs tarball for installing from an existing Linux
#   ext4  - raw ext4 image for `fastboot flash userdata` (single-system)
#   both  - both artifacts
set -euo pipefail
trap 'echo "ERROR: line $LINENO: $BASH_COMMAND" >&2' ERR

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
IMAGE_FORMAT="${IMAGE_FORMAT:-tar}"
IMAGE_MB="${IMAGE_MB:-6144}"

case "$IMAGE_FORMAT" in
    tar|ext4|both) ;;
    *) echo "ERROR: IMAGE_FORMAT must be tar, ext4 or both" >&2; exit 1 ;;
esac

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
# dpkg-query inside the chroot exits non-zero on this image even though the
# database is intact, so parse /var/lib/dpkg/status from the host instead.
sudo chroot "$ROOTFS" dpkg-query -W -f='${Package}\n' >/dev/null 2>&1 \
    || echo "note: chroot dpkg-query returned $?; using status file"
python3 - "$ROOTFS/var/lib/dpkg/status" "$OUT/manifest.txt" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
pkg = ver = None
rows = []
with open(src, encoding="utf-8", errors="replace") as f:
    for line in f:
        if line.startswith("Package: "):
            pkg = line.split(": ", 1)[1].strip()
        elif line.startswith("Version: "):
            ver = line.split(": ", 1)[1].strip()
        elif not line.strip() and pkg and ver:
            rows.append(f"{pkg}\t{ver}")
            pkg = ver = None
if pkg and ver:
    rows.append(f"{pkg}\t{ver}")
with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(sorted(rows)) + "\n")
print(f"manifest: {len(rows)} packages")
PY

TAG="$(date +%Y%m%d)"
if [ "$DESKTOP" = "true" ]; then DESKTOP_SUFFIX="-desktop"; else DESKTOP_SUFFIX=""; fi
NAME="thyme-rootfs-${SUITE}${DESKTOP_SUFFIX}-${TAG}"
TARBALL="$OUT/$NAME.tar.zst"
IMAGE="$OUT/$NAME.img"
IMAGE_ZST="$IMAGE.zst"

if [ "$IMAGE_FORMAT" != "ext4" ]; then
    echo "==> pack $NAME.tar.zst"
    sudo tar --numeric-owner --xattrs --acls --zstd \
        -C "$ROOTFS" -cf "$TARBALL" .
    sudo chown "$(id -u):$(id -g)" "$TARBALL"
fi

if [ "$IMAGE_FORMAT" = "ext4" ] || [ "$IMAGE_FORMAT" = "both" ]; then
    echo "==> create ext4 image ${IMAGE_MB}M -> $NAME.img"
    sudo rm -f "$IMAGE" "$IMAGE_ZST"
    sudo truncate -s "${IMAGE_MB}M" "$IMAGE"
    sudo mkfs.ext4 -F -L thyme "$IMAGE" >/dev/null
    MNT="$(mktemp -d)"
    if sudo mount -o loop "$IMAGE" "$MNT" 2>/dev/null; then
        sudo tar --numeric-owner --xattrs --acls -C "$ROOTFS" -cf - . \
            | sudo tar --numeric-owner --xattrs --acls -C "$MNT" -xf -
        sudo umount "$MNT"
    else
        echo "    loop mount unavailable, falling back to mke2fs -d"
        sudo rm -f "$IMAGE"
        sudo truncate -s "${IMAGE_MB}M" "$IMAGE"
        sudo mke2fs -F -t ext4 -L thyme -d "$ROOTFS" "$IMAGE" >/dev/null
    fi
    rmdir "$MNT" 2>/dev/null || true
    sudo e2fsck -fy "$IMAGE" >/dev/null 2>&1 || true
    if sudo resize2fs -M "$IMAGE" >/dev/null 2>&1; then
        BLOCKS="$(sudo dumpe2fs -h "$IMAGE" 2>/dev/null \
            | awk -F: '/Block count:/{gsub(/ /,"",$2); print $2}')"
        BSIZE="$(sudo dumpe2fs -h "$IMAGE" 2>/dev/null \
            | awk -F: '/Block size:/{gsub(/ /,"",$2); print $2}')"
        if [ -n "$BLOCKS" ] && [ -n "$BSIZE" ]; then
            sudo truncate -s "$((BLOCKS * BSIZE))" "$IMAGE"
        fi
    fi
    sudo e2fsck -fn "$IMAGE" >/dev/null
    echo "==> compress $(basename "$IMAGE")"
    df -h "$OUT" || true
    sudo zstd -T0 -10 -f "$IMAGE" -o "$IMAGE_ZST"
    sudo rm -f "$IMAGE"
    sudo chown "$(id -u):$(id -g)" "$IMAGE_ZST"
    ls -lh "$IMAGE_ZST"
fi

echo "==> write info and install notes"
{
    echo "thyme rootfs build"
    echo "suite:        $SUITE"
    echo "mirror:       $MIRROR"
    echo "format:       $IMAGE_FORMAT"
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

构建: $NAME
格式: $IMAGE_FORMAT
根分区: $ROOT_PART

前提
----
- boot 镜像的 cmdline 必须与根分区一致。单系统刷 userdata 时使用
  root=PARTLABEL=userdata rw rootwait（kernel 产物里的 thyme-userdata.img）。
- 内核已内置 UFS/SCSI/ext4，不需要 initramfs。
- 写入/刷写会清空目标分区（userdata 会清空 Android 数据），请先备份。

方式 A: fastboot 刷 ext4 镜像（手机上还没有 Linux 时用这个）
------------------------------------------------------------
  # 用 7-Zip 或 zstd 解开 .img.zst
  7z e $NAME.img.zst
  # 或: zstd -d $NAME.img.zst

  fastboot flash boot_a thyme-userdata.img
  fastboot flash boot_b thyme-userdata.img
  fastboot erase userdata
  fastboot flash userdata $NAME.img
  fastboot reboot

首次启动会自动把 ext4 扩到 userdata 分区大小（fstab 的 x-systemd.growfs），
可能需要几分钟。Android 数据会被清空。

方式 B: 从已有的 Linux 写入分区（仅当格式为 tar/both）
-----------------------------------------------
  sudo mkfs.ext4 -L thyme $ROOT_PART
  sudo mount $ROOT_PART /mnt
  sudo tar --zstd --numeric-owner -xpf $NAME.tar.zst -C /mnt
  sudo cp -a stock-firmware/out/lib/firmware/. /mnt/lib/firmware/
  sudo umount /mnt

首次启动
--------
- 用户: $THYME_USER  密码: 见构建输入（默认 thyme，请立即修改）
- SSH: ssh $THYME_USER@<手机 IP>（需要已配置 Wi-Fi 或有线网络）
- 串口: ttyMSM0 已启用 getty
- 桌面: $([ "$DESKTOP" = "true" ] && echo "已安装 ubuntu-desktop-minimal，GDM 自动登录 $THYME_USER" || echo "未安装，仅控制台/SSH")

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

echo "==> checksums and verification report"
(
    cd "$OUT"
    find . -maxdepth 1 -type f \
        \( -name '*.tar.zst' -o -name '*.img.zst' -o -name 'manifest.txt' \) \
        -printf '%f\0' | sort -z | xargs -0 sha256sum > SHA256SUMS
)

echo "==> verification report"
{
    echo "== image =="
    echo "$NAME ($IMAGE_FORMAT)"
    echo
    echo "== fstab =="
    cat "$ROOTFS/etc/fstab"
    echo
    echo "== hostname =="
    cat "$ROOTFS/etc/hostname"
    echo
    echo "== gdm =="
    cat "$ROOTFS/etc/gdm3/custom.conf" 2>/dev/null || echo "(no gdm3, minimal image)"
    ls -l "$ROOTFS/etc/systemd/system/display-manager.service" 2>/dev/null || true
    echo
    echo "== key packages =="
    grep -E '^(ubuntu-desktop-minimal|gnome-shell|gdm3|gnome-tweaks|pipewire|wireplumber|libcamera-tools|linux-firmware)[[:space:]]' \
        "$OUT/manifest.txt" || true
    echo
    echo "== user configs =="
    sudo find "$ROOTFS/home/$THYME_USER/.config" -maxdepth 4 \
        \( -type f -o -type l \) -printf '%p\n' 2>/dev/null \
        | sed "s|$ROOTFS||" | sort || true
    echo
    echo "== libcamera =="
    ls -l "$ROOTFS/opt/thyme-camera-focus-color/lib/libcamera.so.0.7.0" 2>/dev/null || true
    echo
    echo "== firmware check =="
    sudo chroot "$ROOTFS" /usr/local/sbin/thyme-check-firmware 2>&1 || true
    echo
    echo "== artifacts =="
    ( cd "$OUT" && ls -lh *.tar.zst *.img.zst 2>/dev/null || true )
    sha256sum "$OUT"/*.tar.zst "$OUT"/*.img.zst 2>/dev/null || true
} > "$OUT/verify-report.txt"

echo "==> done"
ls -lh "$OUT"/*.tar.zst "$OUT"/*.img.zst 2>/dev/null || true
cat "$OUT/SHA256SUMS"
