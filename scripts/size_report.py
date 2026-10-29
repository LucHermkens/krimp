#!/usr/bin/env python3
"""App size table for the phase reports.

    size_report.py <Krimp.app> <link-map.txt> [--save out.json] [--previous prev.json]

Sizes come from three sources:
  * the Release link map (Xcode LD_GENERATE_MAP_FILE): bytes per object file in the main
    executable, which separates Swift, jpegli, libwebp, libdeflate and the Rust LTO object;
  * `cargo bloat --crates` on core/examples/size_probe: splits the Rust object by crate;
  * feature builds of the size probe: the exact marginal cost of `avif` and `svg-min`.
Probe builds use their own target dir so they never touch the app's libkrimp_core.a.
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "core"
TARGET = "aarch64-apple-darwin"
PROBE_DIR = CORE / "target" / "size-probe"

RESVG_CRATES = {
    "resvg", "usvg", "tiny_skia", "tiny_skia_path", "harfrust", "skrifa", "read_fonts", "font_types",
    "fontdb", "roxmltree", "svgtypes", "image_webp", "zune_jpeg", "zune_core", "png", "fdeflate", "imagesize",
    "kurbo", "strict_num", "simplecss", "unicode_bidi", "unicode_script", "unicode_vo", "unicode_ccc",
    "unicode_properties", "xmlwriter", "base64", "memmap2", "float_cmp", "rctree", "pico_args", "data_url",
    "siphasher", "arrayref", "bytemuck", "core_maths", "libm", "ttf_parser", "unicode_bidi_mirroring",
    "gif", "weezl", "color_quant",
}
QUANT_CRATES = {"imagequant", "oxipng", "libdeflater", "libdeflate_sys", "rgb", "indexmap", "bitvec", "crc32fast"}


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def env():
    e = dict(os.environ)
    e["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
    e["PATH"] = f"{Path.home()}/.cargo/bin:/opt/homebrew/bin:" + e.get("PATH", "")
    return e


def probe_size(features):
    """Stripped size of the size probe built with the given feature list (None = defaults)."""
    cmd = ["cargo", "build", "-q", "--release", "--target", TARGET, "--example", "size_probe",
           "--target-dir", str(PROBE_DIR)]
    if features is not None:
        cmd += ["--no-default-features", "--features", ",".join(features)]
    run(cmd, cwd=CORE, env=env())
    return (PROBE_DIR / TARGET / "release" / "examples" / "size_probe").stat().st_size


def bloat_crates():
    e = env()
    e["CARGO_PROFILE_RELEASE_STRIP"] = "false"
    out = run(["cargo", "bloat", "--release", "--target", TARGET, "--example", "size_probe", "--crates",
               "-n", "0", "--message-format", "json", "--target-dir", str(PROBE_DIR / "bloat")], cwd=CORE, env=e)
    data = json.loads(out.strip().splitlines()[-1])
    return {c["name"]: c["size"] for c in data["crates"]}


def archive_members():
    """Maps archive member names of native libs built by -sys crates to a component."""
    members = {}
    build = CORE / "target" / TARGET / "release" / "build"
    for lib in build.glob("*/out/**/*.a"):
        crate = lib.relative_to(build).parts[0].rsplit("-", 1)[0]
        if crate == "krimp_core":
            component = "jpegli"
        elif crate == "libwebp-sys":
            component = "libwebp"
        elif crate.startswith("libdeflate"):
            component = "quant"
        elif crate == "rav1e":
            component = "avif"
        else:
            component = "other"
        for name in run(["ar", "t", str(lib)]).split():
            members[name] = component
    return members


def link_map_components(map_path):
    objects, sizes = {}, defaultdict(int)
    section = None
    for line in Path(map_path).read_text(errors="replace").splitlines():
        if line.startswith("# Object files:"):
            section = "objects"
            continue
        if line.startswith("# Sections:"):
            section = None
            continue
        if line.startswith("# Symbols:"):
            section = "symbols"
            continue
        if line.startswith("# Dead Stripped Symbols:"):
            break
        if section == "objects":
            m = re.match(r"\[\s*(\d+)\]\s+(.*)", line)
            if m:
                objects[int(m.group(1))] = m.group(2)
        elif section == "symbols":
            m = re.match(r"0x[0-9A-F]+\s+0x([0-9A-F]+)\s+\[\s*(\d+)\]", line)
            if m:
                sizes[int(m.group(2))] += int(m.group(1), 16)

    members = archive_members()
    totals = defaultdict(int)
    for index, size in sizes.items():
        path = objects.get(index, "")
        member = re.search(r"\(([^)]*)\)$", path)
        if "libkrimp_core.a" in path and member:
            name = member.group(1)
            if ".rcgu." in name:
                totals["rust"] += size
            else:
                totals[members.get(name, "jpegli" if name.endswith(".cc.o") else "other-native")] += size
        elif path.endswith(".o") and "Krimp.build" in path:
            totals["swift"] += size
        else:
            totals["other"] += size
    return totals


def bundle_size(app):
    return sum(f.stat().st_size for f in Path(app).rglob("*") if f.is_file() and not f.is_symlink())


def measure(app, link_map):
    app = Path(app)
    exe = app / "Contents" / "MacOS" / app.stem
    native = link_map_components(link_map)
    crates = bloat_crates()
    rust_text = sum(crates.values()) or 1

    def rust_share(names):
        return native["rust"] * sum(v for k, v in crates.items() if k in names) / rust_text

    full = probe_size(None)
    no_avif = probe_size(["svg-min"])
    no_svgmin = probe_size(["avif"])
    return {
        "Krimp.app total": bundle_size(app),
        "main executable": exe.stat().st_size,
        "└ jpegli": native["jpegli"],
        "└ libwebp": native["libwebp"],
        "└ imagequant + oxipng": native["quant"] + rust_share(QUANT_CRATES),
        "└ ravif / rav1e": full - no_avif,
        "└ resvg (+ text)": rust_share(RESVG_CRATES),
        "└ oxvg (+ lightningcss)": full - no_svgmin,
        "└ Swift app code": native["swift"],
    }


def fmt(n):
    return f"{n / 1_000_000:.2f} MB" if n >= 100_000 else f"{n / 1000:.0f} KB"


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    app, link_map = args[0], args[1]
    save = args[args.index("--save") + 1] if "--save" in args else None
    previous = json.loads(Path(args[args.index("--previous") + 1]).read_text()) if "--previous" in args else None

    now = measure(app, link_map)
    if save:
        Path(save).write_text(json.dumps(now, indent=2))

    if previous:
        print("| Component | Previous | Now | Δ % |\n|---|---|---|---|")
        for key, value in now.items():
            before = previous.get(key)
            delta = f"{(value - before) / before * 100:+.1f}%" if before else "—"
            print(f"| `{key}` | {fmt(before) if before is not None else '—'} | {fmt(value)} | {delta} |")
    else:
        print("| Component | Now |\n|---|---|")
        for key, value in now.items():
            print(f"| `{key}` | {fmt(value)} |")
    print("\nMB = 10^6 bytes. Rows under the executable are approximate: ravif and oxvg are exact feature")
    print("deltas; resvg and imagequant + oxipng split the Rust LTO object by `cargo bloat` proportions.")


if __name__ == "__main__":
    main()
