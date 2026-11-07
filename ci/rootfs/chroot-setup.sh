#!/bin/bash
# Configure a freshly debootstrapped arm64 rootfs for Xiaomi Mi 10S (thyme).
# Runs as root on a native arm64 host; $1 is the rootfs directory.
set -euo pipefail

ROOT="${1:?usage: chroot-setup.sh <rootfs>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OVERLAY="$HERE/overlay"

THYME_USER="${THYME_USER:-thyme}"
THYME_PASSWORD="${THYME_PASSWORD:-thyme}"
THYME_HOSTNAME="${THYME_HOSTNAME:-thyme}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PSK="${WIFI_PSK:-}"
ROOT_PART="${ROOT_PART:-/dev/sda38}"
case "$ROOT_PART" in
    /dev/*) ;;
    *)
        echo "ERROR: ROOT_PART must look like /dev/sdXN (got '$ROOT_PART')." >&2
        echo "On Windows/Git Bash pass -f root_part='//dev/sda38' or set MSYS_NO_PATHCONV=1." >&2
        exit 1
        ;;
esac
THYME_DESKTOP="${THYME_DESKTOP:-false}"
LIBCAMERA_STAGE="${LIBCAMERA_STAGE:-}"
VENDOR_FIRMWARE_DIR="${VENDOR_FIRMWARE_DIR:-}"

echo "--> overlay"
cp -a "$OVERLAY"/. "$ROOT"/

echo "--> base configuration"
printf '%s\n' "$THYME_HOSTNAME" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $THYME_HOSTNAME
::1 localhost ip6-localhost ip6-loopback
EOF
ln -sf /usr/share/zoneinfo/UTC "$ROOT/etc/localtime"
printf 'UTC\n' > "$ROOT/etc/timezone"
printf 'LANG=C.UTF-8\n' > "$ROOT/etc/default/locale"
: > "$ROOT/etc/machine-id"
printf '%s / ext4 defaults,noatime 0 1\n' "$ROOT_PART" > "$ROOT/etc/fstab"

echo "--> libcamera v0.7.0"
if [ -n "$LIBCAMERA_STAGE" ]; then
    cp -a "$LIBCAMERA_STAGE"/. "$ROOT"/
fi
install -d "$ROOT/opt/thyme-camera-focus-color/share/rootfs-config"
for f in libcamera-cpu.yaml 91-thyme-camera-names.conf 96-thyme-focus-color.conf; do
    cp -a "$REPO/thyme-camera/records/$f" \
        "$ROOT/opt/thyme-camera-focus-color/share/rootfs-config/$f"
done

echo "--> firmware"
if [ -n "$VENDOR_FIRMWARE_DIR" ] && [ -d "$VENDOR_FIRMWARE_DIR/lib/firmware" ]; then
    cp -a "$VENDOR_FIRMWARE_DIR"/lib/firmware/. "$ROOT/lib/firmware/"
    echo "    installed vendor firmware from $VENDOR_FIRMWARE_DIR"
else
    echo "    no vendor firmware supplied (run thyme-check-firmware later)"
fi

echo "--> user $THYME_USER"
if ! chroot "$ROOT" id -u "$THYME_USER" >/dev/null 2>&1; then
    chroot "$ROOT" useradd -m -s /bin/bash \
        -G adm,sudo,video,audio,render,plugdev,netdev,bluetooth,input \
        "$THYME_USER"
fi
printf '%s:%s\n' "$THYME_USER" "$THYME_PASSWORD" | chroot "$ROOT" chpasswd
chroot "$ROOT" passwd -l root >/dev/null

UID_T="$(chroot "$ROOT" id -u "$THYME_USER")"
GID_T="$(chroot "$ROOT" id -g "$THYME_USER")"
HOME_T="$ROOT/home/$THYME_USER"

install -d -m755 -o "$UID_T" -g "$GID_T" \
    "$HOME_T/.config" \
    "$HOME_T/.config/systemd/user" \
    "$HOME_T/.config/libcamera" \
    "$HOME_T/.config/wireplumber/wireplumber.conf.d"

install -m644 -o "$UID_T" -g "$GID_T" \
    "$REPO/thyme-camera/records/libcamera-cpu.yaml" \
    "$HOME_T/.config/libcamera/configuration.yaml"
install -m644 -o "$UID_T" -g "$GID_T" \
    "$REPO/thyme-camera/records/91-thyme-camera-names.conf" \
    "$HOME_T/.config/wireplumber/wireplumber.conf.d/91-thyme-camera-names.conf"

# The LD_LIBRARY_PATH override only makes sense when the distro libcamera
# ABI matches the v0.7.0 build; otherwise keep it staged but disabled.
if [ -e "$ROOT/usr/lib/aarch64-linux-gnu/libcamera.so.0.7" ]; then
    for svc in pipewire.service wireplumber.service; do
        install -d -o "$UID_T" -g "$GID_T" \
            "$HOME_T/.config/systemd/user/$svc.d"
        install -m644 -o "$UID_T" -g "$GID_T" \
            "$REPO/thyme-camera/records/96-thyme-focus-color.conf" \
            "$HOME_T/.config/systemd/user/$svc.d/96-thyme-focus-color.conf"
    done
    echo "    distro libcamera ABI 0.7 found: camera drop-ins enabled"
else
    cat > "$ROOT/opt/thyme-camera-focus-color/share/rootfs-config/README.txt" <<'EOF'
The distribution libcamera ABI is not 0.7, so the LD_LIBRARY_PATH drop-ins
were not enabled automatically. To enable them manually, copy
96-thyme-focus-color.conf to:
  ~/.config/systemd/user/pipewire.service.d/
  ~/.config/systemd/user/wireplumber.service.d/
then run: systemctl --user daemon-reload
EOF
    echo "    distro libcamera ABI is not 0.7: camera drop-ins left disabled"
fi

if [ "$THYME_DESKTOP" = "true" ] && [ -f "$REPO/thyme-camera/records/90-thyme-native-gl.conf" ]; then
    install -d -o "$UID_T" -g "$GID_T" \
        "$HOME_T/.config/systemd/user/org.gnome.Shell@ubuntu.service.d"
    install -m644 -o "$UID_T" -g "$GID_T" \
        "$REPO/thyme-camera/records/90-thyme-native-gl.conf" \
        "$HOME_T/.config/systemd/user/org.gnome.Shell@ubuntu.service.d/90-thyme-native-gl.conf"
fi

echo "--> ssh"
install -d -m700 -o "$UID_T" -g "$GID_T" "$HOME_T/.ssh"
if [ -n "$SSH_PUBKEY" ]; then
    printf '%s\n' "$SSH_PUBKEY" > "$HOME_T/.ssh/authorized_keys"
    chown "$UID_T:$GID_T" "$HOME_T/.ssh/authorized_keys"
    chmod 600 "$HOME_T/.ssh/authorized_keys"
fi
install -d "$ROOT/etc/ssh/sshd_config.d"
cat > "$ROOT/etc/ssh/sshd_config.d/99-thyme.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication yes
EOF

echo "--> network"
if [ -n "$WIFI_SSID" ]; then
    install -d -m700 "$ROOT/etc/NetworkManager/system-connections"
    profile="$ROOT/etc/NetworkManager/system-connections/thyme-wifi.nmconnection"
    {
        printf '[connection]\nid=thyme-wifi\ntype=wifi\nautoconnect=true\n\n'
        printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$WIFI_SSID"
        if [ -n "$WIFI_PSK" ]; then
            printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$WIFI_PSK"
        fi
        printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } > "$profile"
    chmod 600 "$profile"
fi

echo "--> services"
chroot "$ROOT" systemctl enable \
    NetworkManager.service ssh.service bluetooth.service \
    systemd-timesyncd.service thyme-firstboot.service >/dev/null
chroot "$ROOT" systemctl enable serial-getty@ttyMSM0.service >/dev/null 2>&1 || true
chroot "$ROOT" systemctl mask systemd-firstboot.service >/dev/null 2>&1 || true
if [ "$THYME_DESKTOP" = "true" ]; then
    install -d "$ROOT/etc/gdm3"
    cat > "$ROOT/etc/gdm3/custom.conf" <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$THYME_USER
EOF
    chroot "$ROOT" systemctl enable gdm3.service >/dev/null 2>&1 || true
    # Skip the GNOME first-login wizard on a device without a keyboard.
    install -m644 -o "$UID_T" -g "$GID_T" /dev/null \
        "$HOME_T/.config/gnome-initial-setup-done"
    chroot "$ROOT" systemctl --global mask \
        gnome-initial-setup-first-login.service >/dev/null 2>&1 || true
    chroot "$ROOT" systemctl set-default graphical.target >/dev/null
else
    chroot "$ROOT" systemctl set-default multi-user.target >/dev/null
fi

echo "--> user session units"
install -d -o "$UID_T" -g "$GID_T" "$HOME_T/.config/systemd/user/default.target.wants"
for unit in pipewire.socket pipewire-pulse.socket wireplumber.service; do
    if [ -e "$ROOT/usr/lib/systemd/user/$unit" ]; then
        ln -sf "/usr/lib/systemd/user/$unit" \
            "$HOME_T/.config/systemd/user/default.target.wants/$unit"
    fi
done
install -d "$ROOT/var/lib/systemd/linger"
touch "$ROOT/var/lib/systemd/linger/$THYME_USER"
chown -R "$UID_T:$GID_T" "$HOME_T"

echo "--> done"
