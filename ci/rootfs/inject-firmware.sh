#!/bin/bash
# Inject extracted vendor firmware into an existing thyme rootfs tarball.
#
#   ./inject-firmware.sh thyme-rootfs-resolute-20261107.tar.zst stock-firmware/out
#   ./inject-firmware.sh <rootfs.tar.zst> <firmware-dir> [output.tar.zst]
#
# The firmware directory is the output of ci/rootfs/extract-stock-firmware.py
# and must contain lib/firmware/... The output tarball keeps the original
# ownership, xattrs and device nodes, so run this on Linux as root/sudo.
set -euo pipefail

ROOTFS_TAR="${1:?usage: inject-firmware.sh <rootfs.tar.zst> <firmware-dir> [out.tar.zst]}"
FW_DIR="${2:?usage: inject-firmware.sh <rootfs.tar.zst> <firmware-dir> [out.tar.zst]}"
OUT="${3:-${ROOTFS_TAR%.tar.zst}-with-firmware.tar.zst}"

[ -f "$ROOTFS_TAR" ] || { echo "missing $ROOTFS_TAR" >&2; exit 1; }
[ -d "$FW_DIR/lib/firmware" ] || { echo "$FW_DIR/lib/firmware not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'sudo rm -rf "$WORK"' EXIT

echo "==> unpacking $ROOTFS_TAR"
sudo tar --zstd --numeric-owner -xpf "$ROOTFS_TAR" -C "$WORK"

echo "==> installing firmware from $FW_DIR"
sudo cp -a "$FW_DIR"/lib/firmware/. "$WORK/lib/firmware/"

echo "==> repacking $OUT"
sudo tar --numeric-owner --xattrs --acls --zstd -C "$WORK" -cf "$OUT" .
sudo chown "$(id -u):$(id -g)" "$OUT"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")")
echo "==> done: $OUT"
