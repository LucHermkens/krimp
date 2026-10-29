# Krimp

Tiny native macOS app that resizes/re-encodes images and minifies SVGs. SwiftUI app + Rust
static library (`core/`, C ABI via cbindgen). README.md covers usage and building.

## Hard rules
- Release `.app` under **10 MB**, arm64 only. Report the size (`make size`) whenever a change
  could move it; flag anything that pushes past budget instead of keeping it silently.
- Everything statically linked into the one executable: no helper binaries, dylibs, CLI tools,
  shell-outs, background processes, extensions, login items or folder watching. At runtime only
  Apple frameworks (ImageIO, Accelerate, CoreGraphics, AppKit/SwiftUI).
- No network access, ever. No App Sandbox; Hardened Runtime on; ad-hoc signing must work.
- macOS 26+ only, Swift 6 strict concurrency, no availability fallbacks. Native controls, no
  custom glass/effects. The app quits when its window closes.
- Strip all metadata from raster output, after applying EXIF orientation and converting to sRGB.
- Never overwrite or silently delete a user's file: Replace moves originals to the Trash, Save
  copy picks a free name.
- Licence is GPL-3.0-or-later (imagequant). Adding a dependency → `make notices`.
- Don't add libvips, ImageMagick, libheif, libraw, dav1d or other decoders; decoding is ImageIO.

## Working here
- If a requested change is wrong or clearly worse than an alternative, say so before doing it.
- Conventional commits. Never push without asking.
- `make` builds Release, `make test` runs cargo + Swift tests, `make size` prints the size table,
  `make fixtures` fetches the optional DNG sample, `make icon` redraws the icon.
- The Xcode project is generated from `project.yml` (`make project`); don't edit the .xcodeproj.

## Where things are
- `core/src/` — encoders (jpegli via `csrc/` shim + CMake, imagequant/oxipng, libwebp, gif,
  ravif), SVG render/rewrite/minify/compare (resvg, oxvg). `lib.rs` is the C ABI.
- `App/Pipeline/` — Decode → Normalize → Resize → Encode → Writer; `Pipeline.swift` orchestrates.
- `App/Model/OutputPlan.swift` — format/quality rules (Format on/off, "Same as original").
- `App/Model/AppModel.swift` — file list and batch runner (2 items in flight, cancellable).
- `Tests/` — Swift Testing, non-hosted bundle that compiles Model + Pipeline itself.

## Non-obvious decisions (keep unless there's a good reason)
- The core is built with `cargo rustc --crate-type staticlib`; listing staticlib next to rlib in
  Cargo.toml silently disables LTO (+3 MB).
- SVG/CSS/font crates are `opt-level = "z"` (oxvg + lightningcss would otherwise be ~10 MB);
  codecs stay at O3. oxvg is pinned to an exact version and is ~4 MB of the budget.
- `scripts/build-core.sh` runs cargo under `env -i`: Xcode's environment breaks jpegli's CMake.
- SVG minify safety net: compare renders at 512 px after a 2×2 box filter (max ≤ 8, mean ≤ 0.5),
  before resizing. Disable a misbehaving oxvg job in `DISABLED_JOBS` (`core/src/svg.rs`).
- Format off + JPEG re-encodes at the estimated IJG quality clamped to 50–99 (95 if unknown).
- The lossless PNG shortcut (oxipng on the original bytes) only runs for ≤ 8-bit sRGB/untagged
  PNGs; stripping another colour profile would shift colours.
- App icon is a hand-packed `.icns` of 256-colour PNGs; an asset catalog cost 0.77 MB.
