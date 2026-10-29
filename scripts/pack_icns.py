#!/usr/bin/env python3
"""Packs PNGs from scripts/make_icon.swift into AppIcon.icns without re-encoding them.

    pack_icns.py <iconset-dir> <out.icns>

`iconutil` decodes and re-compresses every image (≈420 KB); icns entries can hold PNG
data as-is, so 256-colour PNGs keep the file around 150 KB.
"""

import struct
import sys
from pathlib import Path

# icns type → PNG file (from the AppIcon.appiconset naming).
TYPES = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    body = b""
    for kind, name in TYPES:
        data = (src / name).read_bytes()
        body += kind.encode() + struct.pack(">I", len(data) + 8) + data
    out.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"wrote {out} ({len(body) + 8} bytes)")


if __name__ == "__main__":
    main()
