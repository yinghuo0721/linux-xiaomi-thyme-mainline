#!/usr/bin/env python3
"""Extract thyme (Xiaomi Mi 10S) firmware blobs from a stock MIUI/HyperOS ROM.

The stock package ships a raw super image plus dsp/modem/vendor images.  The
mainline device tree expects the files below, but the stock firmware is in
Qualcomm split format (foo.mdt + foo.b00, foo.b01, ...).  qcom_mdt_loader names
segments by replacing the last three characters of the firmware name with
"bNN", so renaming foo.mdt to foo.mbn and keeping foo.bNN next to it makes the
device tree paths loadable without rebuilding the kernel.

Usage:
    python3 extract-stock-firmware.py --rom-dir "/path/to/stock-rom" \
        --out stock-firmware

The output layout is a root filesystem overlay:

    lib/firmware/qcom/sm8250/umi/{adsp,cdsp,slpi,venus,a650_zap}.mbn + .bNN
    lib/firmware/qcom/a650_sqe.fw

Requires 7-Zip (7z/7za/7zz on PATH, or --sevenzip) to read the ext4/FAT images.
Only the vendor firmware referenced by the device tree is extracted; no stock
Android code is copied.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SECTOR = 512
SUPER_METADATA_GEOMETRY_OFFSET = 4096
SUPER_METADATA_OFFSET = 12288  # three 4 KiB geometry copies
LP_GEOMETRY_MAGIC = 0x616C4467
LP_HEADER_MAGIC = 0x414C5030
EXT4_MAGIC = 0xEF53

# firmware name -> (source dir in extracted image, stock stem)
SPLIT_BLOBS = {
    "adsp": ("modem", "image/adsp"),
    "cdsp": ("modem", "image/cdsp"),
    "slpi": ("modem", "image/slpi"),
    "venus": ("modem", "image/venus"),
    "a650_zap": ("vendor", "firmware/a650_zap"),
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def find_7zip(explicit: str | None) -> str:
    candidates = [explicit] if explicit else []
    candidates += [shutil.which(n) for n in ("7z", "7za", "7zz")]
    candidates += [
        r"C:\Program Files\7-Zip\7z.exe",
        r"C:\Program Files (x86)\7-Zip\7z.exe",
    ]
    for c in candidates:
        if c and Path(c).exists():
            return str(c)
    raise SystemExit(
        "7-Zip not found; install p7zip-full on Linux or use --sevenzip PATH"
    )


def run_7z(sevenzip: str, archive: Path, patterns: list[str], dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    cmd = [sevenzip, "x", "-y", f"-o{dest}", str(archive), *patterns]
    # The stock FAT/ext4 images make 7-Zip report "Archives with Errors: 1"
    # even when every requested file is extracted.  Verify files afterwards
    # instead of trusting the exit status.
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def read_exact(f, offset: int, size: int) -> bytes:
    f.seek(offset)
    data = f.read(size)
    if len(data) != size:
        raise SystemExit(f"short read at offset {offset:#x}")
    return data


def parse_geometry(f) -> tuple[int, int, int, int, int]:
    """Return (metadata_offset, metadata_max_size, slot_count, block_size, header_size)."""
    raw = read_exact(f, SUPER_METADATA_GEOMETRY_OFFSET, 52)
    magic, struct_size = struct.unpack_from("<II", raw, 0)
    if magic != LP_GEOMETRY_MAGIC:
        raise SystemExit("super.img: bad LP geometry magic")
    # Android 14 stores a 32-byte SHA-256 checksum in the geometry; older
    # images store a 32-bit checksum.  Detect by validating the known fields.
    layouts = (
        (40, 44, 48, 80, 256),  # SHA-256 checksum, header_size 256
        (12, 16, 20, 24, 128),  # legacy 32-bit checksum
    )
    for max_off, slots_off, block_off, _, header_size in layouts:
        max_size, slots, block = struct.unpack_from("<III", raw, max_off)
        if 0 < slots <= 4 and block == 4096 and 0x10000 <= max_size <= 0x1000000:
            metadata_offset = SUPER_METADATA_OFFSET
            return metadata_offset, max_size, slots, block, header_size
    raise SystemExit("super.img: unsupported LP geometry layout")


def parse_metadata(f, meta_off: int, meta_max: int, header_hint: int) -> tuple[list, list]:
    hdr = read_exact(f, meta_off, 256)
    magic = struct.unpack_from("<I", hdr, 0)[0]
    if magic != LP_HEADER_MAGIC:
        raise SystemExit("super.img: bad LP metadata magic")
    header_size = struct.unpack_from("<I", hdr, 8)[0]
    # SHA-256 variants keep checksums at 12..43 and tables_size at 44;
    # legacy variants have tables_size at 16 and descriptors at 24.
    tables_size = struct.unpack_from("<I", hdr, 44)[0]
    desc_off = 80
    if not (0 < tables_size <= meta_max and header_size >= 256):
        tables_size = struct.unpack_from("<I", hdr, 16)[0]
        desc_off = 24
        header_size = min(header_size, 256)
    if not (0 < tables_size <= meta_max):
        raise SystemExit("super.img: implausible LP tables size")
    tables = read_exact(f, meta_off + header_size, tables_size)

    def descriptor(index: int) -> tuple[int, int, int]:
        return struct.unpack_from("<III", hdr, desc_off + index * 12)

    p_off, p_num, p_esz = descriptor(0)
    e_off, e_num, e_esz = descriptor(1)
    partitions = []
    for i in range(p_num):
        e = tables[p_off + i * p_esz : p_off + (i + 1) * p_esz]
        name = e[:36].split(b"\0")[0].decode(errors="replace")
        _, first, num, _ = struct.unpack_from("<IIII", e, 36)
        partitions.append((name, first, num))
    extents = []
    for i in range(e_num):
        e = tables[e_off + i * e_esz : e_off + (i + 1) * e_esz]
        nsec, ttype, tdata, _ = struct.unpack_from("<QIII", e, 0)
        extents.append((nsec, ttype, tdata))
    return partitions, extents


def extract_vendor(super_img: Path, out_img: Path) -> None:
    f = super_img.open("rb")
    head = f.read(4)
    if head == bytes.fromhex("3aff26ed"):
        raise SystemExit(
            "super.img is an Android sparse image; convert it first with "
            "'simg2img super.img super.raw.img'"
        )
    meta_off, meta_max, _, _, header_hint = parse_geometry(f)
    partitions, extents = parse_metadata(f, meta_off, meta_max, header_hint)
    chosen = next((p for p in partitions if p[0] == "vendor_a"), None)
    if chosen is None:
        chosen = next((p for p in partitions if p[0] == "vendor"), None)
    if chosen is None:
        raise SystemExit("super.img: no vendor partition found")

    _, first, num = chosen
    with out_img.open("wb") as out:
        for nsec, ttype, tdata in extents[first : first + num]:
            if ttype != 0:
                raise SystemExit(f"unsupported extent target type {ttype}")
            f.seek(tdata * SECTOR)
            left = nsec * SECTOR
            while left:
                chunk = f.read(min(left, 8 << 20))
                if not chunk:
                    raise SystemExit("short read while extracting vendor")
                out.write(chunk)
                left -= len(chunk)
    f.close()

    with out_img.open("rb") as v:
        magic = struct.unpack_from("<H", read_exact(v, 0x438, 2), 0)[0]
    if magic != EXT4_MAGIC:
        raise SystemExit("extracted vendor partition is not ext4")


def check_elf_split(path: Path) -> None:
    data = path.read_bytes()
    if data[:4] != b"\x7fELF":
        raise SystemExit(f"{path.name}: not an ELF/MBN header")
    phoff, = struct.unpack_from("<I", data, 28)
    phentsize, phnum = struct.unpack_from("<HH", data, 42)
    stem = path.stem
    for i in range(phnum):
        p_type, _, _, _, p_filesz, _, _, _ = struct.unpack_from(
            "<IIIIIIII", data, phoff + i * phentsize
        )
        if p_type == 1 and p_filesz:
            seg = path.with_name(f"{stem}.b{i:02d}")
            if not seg.exists():
                raise SystemExit(f"missing segment {seg.name} for {path.name}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rom-dir", required=True, type=Path,
                    help="stock package directory containing images/")
    ap.add_argument("--out", default=Path("stock-firmware"), type=Path,
                    help="output directory (default: ./stock-firmware)")
    ap.add_argument("--sevenzip", default=None,
                    help="path to 7z executable")
    args = ap.parse_args()

    images = args.rom_dir / "images"
    required = {
        "super": images / "super.img",
        "modem": images / "modem.img",
        "vendor": None,  # produced below
    }
    if not required["super"].exists() or not required["modem"].exists():
        raise SystemExit(f"expected images/super.img and images/modem.img under {images}")

    sevenzip = find_7zip(args.sevenzip)
    out = args.out.resolve()
    fw_root = out / "lib/firmware"
    umi = fw_root / "qcom/sm8250/umi"
    umi.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="thyme-fw-") as tmp:
        tmp = Path(tmp)
        vendor_img = tmp / "vendor.img"
        print(f"==> extracting vendor partition from {required['super'].name}")
        extract_vendor(required["super"], vendor_img)

        print("==> extracting split firmware with 7-Zip")
        run_7z(sevenzip, required["modem"],
               ["image/adsp.*", "image/cdsp.*", "image/slpi.*", "image/venus.*"],
               tmp / "modem")
        run_7z(sevenzip, vendor_img,
               ["firmware/a650_zap.*", "firmware/a650_sqe.fw"],
               tmp / "vendor")

        print("==> assembling lib/firmware/qcom/sm8250/umi")
        for name, (src, prefix) in SPLIT_BLOBS.items():
            stem = prefix.rsplit("/", 1)[1]
            src_dir = tmp / src
            # 7-Zip may keep the archive's directory prefix on either side.
            matches = list(src_dir.rglob(f"{stem}.mdt"))
            if not matches:
                raise SystemExit(f"{src}: {prefix}.mdt not found after extraction")
            workdir = matches[0].parent
            header = workdir / f"{stem}.mdt"
            shutil.copyfile(header, umi / f"{name}.mbn")
            for seg in sorted(workdir.glob(f"{stem}.b*")):
                shutil.copyfile(seg, umi / f"{name}{seg.suffix}")
            check_elf_split(umi / f"{name}.mbn")
            print(f"    {name}.mbn + {len(list(umi.glob(f'{name}.b*')))} segments")

        sqe = list((tmp / "vendor").rglob("a650_sqe.fw"))
        if sqe:
            shutil.copyfile(sqe[0], fw_root / "qcom/a650_sqe.fw")

    manifest = []
    for path in sorted(fw_root.rglob("*")):
        if path.is_file():
            manifest.append(f"{sha256(path)}  {path.relative_to(out).as_posix()}")
    (out / "SHA256SUMS").write_text("\n".join(manifest) + "\n")
    (out / "MANIFEST.txt").write_text(
        "Extracted from stock firmware for personal use on the same device.\n"
        f"Source: {args.rom_dir}\n"
        f"Files: {len(manifest)}\n"
        "Target: /lib/firmware/qcom/sm8250/umi (mainline device tree paths)\n"
    )
    print(f"==> done: {len(manifest)} files under {out}")
    print(f"    install with: sudo cp -a {out}/lib/firmware/. /lib/firmware/")


if __name__ == "__main__":
    main()
