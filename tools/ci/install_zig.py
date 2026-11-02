#!/usr/bin/env python3
"""Install the exact tested Zig release, verifying official archive checksums.

Source: https://ziglang.org/download/index.json (0.17.0, checked 2026-10-18).
No floating master build or third-party setup action is used.
"""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import tarfile
import tempfile
import urllib.request
import zipfile

VERSION = "0.17.0"
ARCHIVES = {
    "x86_64-linux": ("tar.xz", "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026"),
    "x86_64-macos": ("tar.xz", "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6"),
    "aarch64-macos": ("tar.xz", "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a"),
    "x86_64-windows": ("zip", "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", type=Path)
    parser.add_argument("--platform", choices=ARCHIVES)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    arch = {"AMD64": "x86_64", "arm64": "aarch64"}.get(platform.machine(), platform.machine())
    system = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]
    target = args.platform or f"{arch}-{system}"
    extension, checksum = ARCHIVES[target]
    directory = f"zig-{target}-{VERSION}"
    url = f"https://ziglang.org/download/{VERSION}/{directory}.{extension}"
    if args.dry_run:
        print(url, checksum)
        return
    if args.dest is None:
        parser.error("--dest is required for installation")
    args.dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zicr-zig-") as tmp:
        archive = Path(tmp) / f"zig.{extension}"
        with urllib.request.urlopen(url, timeout=30) as response, archive.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != checksum:
            raise RuntimeError(f"Zig archive checksum mismatch: {actual}")
        if extension == "zip":
            with zipfile.ZipFile(archive) as package:
                package.extractall(args.dest)
        else:
            with tarfile.open(archive) as package:
                package.extractall(args.dest, filter="data")
    binary_dir = (args.dest / directory).resolve()
    if "GITHUB_PATH" in os.environ:
        with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as output:
            output.write(str(binary_dir) + "\n")
    print(binary_dir)


if __name__ == "__main__":
    main()
