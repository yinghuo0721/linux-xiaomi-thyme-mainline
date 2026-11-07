#!/usr/bin/env python3
"""Pack camera test images using the existing boot images' parameters."""
from pathlib import Path
import argparse
import hashlib
import struct
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
BOOT = ROOT / "boot-images"
BUILD = ROOT.parent.parent / "kernel-build/arch/arm64/boot"
HEADER = struct.Struct("<8s10I16s512s32s1024sIQI")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suffix", default="", choices=("", "-gpiofix", "-focus", "-focus-retry"))
    parser.add_argument("--build-dir", type=Path, default=BUILD.parent.parent.parent,
                        help="Kernel output directory containing arch/arm64/boot")
    parser.add_argument("--output-dir", type=Path, default=BOOT)
    args = parser.parse_args()
    suffix = args.suffix
    build = args.build_dir.resolve() / "arch/arm64/boot"
    boot = args.output_dir.resolve()
    boot.mkdir(parents=True, exist_ok=True)
    kernel = (build / "Image.gz").read_bytes()
    assert zlib.decompress(kernel, 31) == (build / "Image").read_bytes()
    checksums = []
    logs = [f"Input Image.gz SHA256: {sha256(kernel)}"]
    for variant in ("menu", "logdump", "display-test"):
        stable = ROOT / "templates" / f"thyme-{variant}.img"
        original = stable.read_bytes()
        old = HEADER.unpack_from(original)
        dtb_name = "sm8250-xiaomi-thyme" + ("-logdump" if variant == "logdump" else "")
        dtb_path = build / "dts/qcom" / (dtb_name + ".dtb")
        dtb = dtb_path.read_bytes()
        assert struct.unpack_from(">II", dtb) == (0xD00DFEED, len(dtb))
        assert not old[14].strip(b"\0"), "Unexpected extra command line"
        cmdline = old[12].split(b"\0", 1)[0].decode()
        output = boot / f"thyme-camera-{variant}{suffix}.img"
        result = subprocess.run(
            [sys.executable, str(ROOT / "tools/pack-bootimg.py"),
             str(build / "Image.gz"), str(dtb_path), str(output), cmdline],
            check=True, capture_output=True, text=True,
        )
        data = output.read_bytes()
        new = HEADER.unpack_from(data)
        assert new[:1] + new[2:] == old[:1] + old[2:], "Boot parameters changed"
        page = new[8]
        payload = kernel + dtb
        assert new[1] == len(payload)
        assert data[page:page + len(payload)] == payload
        assert len(data) == page + ((len(payload) + page - 1) // page) * page
        assert not any(data[HEADER.size:page])
        assert not any(data[page + len(payload):])
        decoder = zlib.decompressobj(31)
        assert decoder.decompress(payload) == (build / "Image").read_bytes()
        assert decoder.eof and decoder.unused_data == dtb
        assert stable.read_bytes() == original, "Original image changed"
        logs.append(result.stdout.strip())
        logs.append(f"PASS: {output.name}; header/command line, kernel, DTB, gzip, padding, original image verified")
        checksums.append(f"{sha256(data)}  {output.name}")
    (boot / f"SHA256SUMS-camera{suffix}").write_text("\n".join(checksums) + "\n")
    (boot / f"pack-images{suffix}.log").write_text("\n".join(logs) + "\n")
    print("\n".join(logs + checksums))


if __name__ == "__main__":
    main()
