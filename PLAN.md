# Krimp — plan for Claude Code

> Working title. Repo: **github.com/LucHermkens/krimp** (public).

A tiny native macOS app that resizes and/or re-encodes images, and minifies SVGs. You drop files in, pick a size and an output format (or keep the original format and quality), then either replace the originals or save a copy next to each one.

Think of it as a stripped-down Squash/Clop with three panels: **Resize**, **Format** and **Output**.

**Start:** read this whole file, then do **Phase 0**. After each phase, stop and post a report (format under *Phases*). Wait for my confirmation before starting the next phase.

---

## Non-negotiables

### Size
- Release `.app` **under 10 MB**, arm64 only.
- Report the size after every phase (table format under *Phases*). If a feature pushes the app past budget, flag it rather than silently keeping it.

### Everything bundled, nothing borrowed
- Every third-party library (jpegli, libwebp, imagequant, oxipng, ravif, gif, resvg, oxvg) is compiled from source at build time and **statically linked into the single main executable**.
- At runtime the app uses only Apple system frameworks: ImageIO, Accelerate, AppKit/SwiftUI, CoreGraphics.
- No Homebrew, no `/usr/local`, no CLI tools on the system, no extra executables or dylibs in the bundle.

### No background anything
- None of these: menu bar extra, login item, launch agent, helper app, XPC service, Finder/Share extension, Services menu entry, Quick Action, folder watching.
- No shell-outs at runtime.
- The app quits when its last window closes.
- Concurrency *inside* the app while the user waits is fine. "No background workers" means no daemons, not no threads.

### No network
The app never touches the network. No Sparkle, no analytics.

### Platform
- **macOS 26+ only.** Xcode 26, Swift 6.2, strict concurrency. No availability checks or fallbacks for older macOS.
- SwiftUI with `@Observable`, native controls only. Liquid Glass comes for free; add no custom glass or visual effects.
- Prefer native frameworks:
  - ImageIO for decoding, TIFF encoding and thumbnails
  - vImage for resizing
- Third-party code only where Apple's is weak or missing: encoders, SVG rendering and SVG minification.
- **No App Sandbox.** This is a personal tool, signed locally with Hardened Runtime on. Reason: "save a copy next to the original with a different name" isn't covered by sandboxed user-selected file access.

### Metadata
- **Strip all metadata from raster output:** EXIF, XMP, IPTC, GPS, ICC, maker notes.
- Before stripping, apply EXIF orientation and convert to sRGB (see Pipeline).

---

## Repo, licence, conventions

- **Repo:** `github.com/LucHermkens/krimp`, public, default branch `main`.
  - The initial commit contains only PLAN.md and CLAUDE.md.
  - Phase 0 adds `README.md` (short description, build requirements, licence) and `.gitignore` covering: `.DS_Store`, `*.xcodeproj/`, `*.xcworkspace/`, `xcuserdata/`, `DerivedData/`, `build/`, `Local.xcconfig`, `core/target/`, `Bridge/krimp_core.h`.
- **Licence:** **GPL-3.0-or-later**. Add `LICENSE` in Phase 0.
  - This isn't optional: the `imagequant` crate (libimagequant) is GPL-3.0-or-later (or commercial).
  - Any binary that statically links it must be distributed under the GPL.
  - If anyone ever wants a non-GPL build, imagequant is the one library to swap out.
- **Third-party notices:**
  - Add a `THIRD_PARTY_NOTICES.md` listing every bundled library with its licence and copyright line. Generate it, e.g. with `cargo about`, plus manual entries for jpegli and libwebp.
  - Show the same text in the standard About panel's credits (`Credits.rtf` or `NSHumanReadableCopyright` + credits). BSD/MIT licences require this for binary distribution.
- **Bundle id:** `io.github.luchermkens.krimp`.
- **Signing:**
  - Never commit a Team ID or signing identity.
  - `project.yml` includes an optional, git-ignored `Local.xcconfig` for `DEVELOPMENT_TEAM`.
  - Ad-hoc signing must also work when it's absent.
- **Git:**
  - Use conventional commits.
  - Commit at the end of every phase and whenever a coherent step is green.
  - **Never push without asking me first.**
  - Never commit `core/target/`, the generated `.xcodeproj`, `DerivedData/`, or the generated `Bridge/krimp_core.h`. These are already in `.gitignore`.

---

## Build requirements (build machine only, never runtime)

- Xcode 26
- Rust via rustup, with the `aarch64-apple-darwin` target
- `cmake` (for jpegli)
- `xcodegen`
- `cbindgen`

Document these in the README with a single `make bootstrap` that checks or installs them, and a `make` that builds the app. Build-time scripts are fine.

---

## Architecture

```
krimp/
├── project.yml                 ← XcodeGen spec (text, diffable); .xcodeproj is generated and git-ignored
├── Makefile                    ← bootstrap / build / test / size
├── App/                        ← SwiftUI app
│   ├── KrimpApp.swift
│   ├── Model/                  ← ImageItem, Settings (@AppStorage), OutputPlan, ResultRow
│   ├── Pipeline/               ← Decode.swift, Normalize.swift, Resize.swift, Encode.swift, Writer.swift
│   └── UI/                     ← ContentView, ImageGrid, ResultsTable, InspectorCards
├── core/                       ← Rust staticlib `krimp_core`
│   ├── Cargo.toml
│   ├── build.rs                ← builds jpegli (C++) statically via the `cmake` crate
│   ├── cbindgen.toml
│   └── src/{lib.rs, jpeg.rs, png.rs, webp.rs, gif.rs, avif.rs, svg.rs}
├── Bridge/                     ← module.modulemap (+ generated krimp_core.h, git-ignored)
├── Tests/                      ← Swift Testing + fixture images
├── LICENSE                     ← GPL-3.0-or-later
└── THIRD_PARTY_NOTICES.md
```

### Build setup
- An Xcode "Run Script" build phase runs `cargo build --release --target aarch64-apple-darwin` and cbindgen, then links `libkrimp_core.a`.
- Rust release profile:
  - `lto = "fat"`, `codegen-units = 1`, `strip = true`
  - `opt-level = 3` — keep it, because rav1e and imagequant are hot paths
  - `panic = "unwind"`, with **every** `extern "C"` fn wrapped in `catch_unwind` so a codec bug becomes an error, not a crash
- Swift: Release builds use `-Osize` and strip symbols.

### Codecs

| Purpose | Library | Notes |
|---|---|---|
| JPEG encode | **jpegli** (google/jpegli, C++, static) | Use the `jpegli_*` API to avoid libjpeg symbol clashes. q90 ≈ butteraugli distance 1.0 ("visually lossless"). **Fallback:** if the jpegli build becomes a time sink, switch to the `mozjpeg` crate and tell me. |
| PNG encode | **imagequant** + **oxipng** | Lossy palette quantization, then a lossless deflate pass. |
| WebP encode | **libwebp** via `libwebp-sys` | Vendored, static. |
| GIF encode | **imagequant** + **gif** crate | Single frame. |
| AVIF encode | **ravif** (pure Rust, rav1e) | Cargo feature `avif` (default on). Measure it; if AVIF alone breaks the budget, report it and I'll decide. |
| TIFF encode | **ImageIO** (LZW) | Lossless; the quality slider is disabled. |
| SVG render | **resvg** (+ usvg, tiny-skia) with the `text` feature | Load system fonts once into a shared `fontdb` (lazy `OnceLock`). Accepts `.svgz`. Do **not** use `NSImage`'s SVG loading: it relies on private CoreSVG, is undocumented, and chokes on some files. |
| SVG minify | **oxvg_optimiser** (Rust port of SVGO, MIT) | Pre-1.0 and explicitly unstable, so **pin an exact version** (`=x.y.z`). Put it behind Cargo feature `svg-min` (default on). It pulls in lightningcss, so measure it separately in the size table. Safety net below. |
| All other decoding | **ImageIO** | |

Do **not** add libvips, ImageMagick, libheif, libraw, dav1d, or any other decoder library.

### C ABI (`krimp_core.h`, generated by cbindgen)

```c
typedef enum { KRIMP_JPEG, KRIMP_PNG, KRIMP_WEBP, KRIMP_GIF, KRIMP_AVIF } KrimpFormat;

typedef struct {
    KrimpFormat format;
    uint8_t     quality;      // 1–100; 100 = lossless where the format supports it
    bool        progressive;  // JPEG only
} KrimpOptions;

typedef struct { uint8_t *ptr; size_t len; } KrimpBuffer;

// rgba: 8-bit sRGB, STRAIGHT (non-premultiplied) alpha, tightly packed, width*4 stride
int32_t     krimp_encode(const uint8_t *rgba, uint32_t width, uint32_t height,
                         KrimpOptions opts, KrimpBuffer *out);

// Lossless re-optimisation of existing PNG bytes (oxipng)
int32_t     krimp_optimize_png(const uint8_t *png, size_t len, KrimpBuffer *out);

// IJG-equivalent quality of a JPEG from its luma DQT table: 1–100, or -1 if non-standard/missing
int32_t     krimp_jpeg_estimate_quality(const uint8_t *jpeg, size_t len);

// SVG raster: intrinsic size (width/height, else viewBox) and rendering at an exact size.
// Output is straight-alpha sRGB RGBA, width*4 stride.
int32_t     krimp_svg_size(const uint8_t *svg, size_t len, float *width, float *height);
int32_t     krimp_svg_render(const uint8_t *svg, size_t len, uint32_t width, uint32_t height,
                             KrimpBuffer *out_rgba);

// SVG → SVG. width/height = 0 keeps the current size; otherwise set root width/height
// (adding a viewBox from the old size if none exists). minify = run oxvg preset-default.
// Output is UTF-8 SVG (never gzipped, even for .svgz input).
int32_t     krimp_svg_rewrite(const uint8_t *svg, size_t len, uint32_t width, uint32_t height,
                              bool minify, KrimpBuffer *out);

void        krimp_buffer_free(KrimpBuffer buf);
const char *krimp_last_error(void);          // thread-local, valid until next call on that thread
uint32_t    krimp_available_features(void);  // bitmask: AVIF, SVG_MIN; Swift hides what's off
```

Swift wraps this in one small `Core` type with throwing methods.

---

## Pipeline (per item)

### Raster output (JPEG / PNG / WebP / AVIF / GIF / TIFF)

1. **Decode.**
   - **SVG/SVGZ input:**
     - Get the intrinsic size via `krimp_svg_size` and compute the target size (see Resize).
     - Call `krimp_svg_render` **directly at the target size**. Upscaling is allowed for SVG.
     - Skip steps 2–3.
   - **Everything else:** decode with `CGImageSource`, index 0 only.
     - Animated input (GIF, APNG, animated WebP, HEICS): use the first frame and show an "animated → first frame" badge.
     - Camera RAW goes through ImageIO.
     - If decoding fails, mark the item "Unsupported" and move on.
2. **Normalise:**
   - Apply EXIF orientation.
   - Draw into an 8-bit RGBA `CGContext` in **sRGB**. This handles CMYK, 16-bit, P3, grayscale and HDR (gain maps are dropped).
3. **Resize** with vImage (`vImageScale_ARGB8888`, `kvImageHighQualityResampling`).
   - Premultiply alpha before scaling and unpremultiply after, to avoid dark halos.
   - Modes: **Width**, **Height**, **Longest edge**, **Percentage**. Keep the aspect ratio.
   - **Never upscale** raster sources.
4. **Flatten:**
   - JPEG: composite over white.
   - GIF: transparent index where alpha < 128.
5. **Encode** (quality rules below).
6. **Write** (see Output).

**Shortcut:** for PNG→PNG with no resize and lossless settings, call `krimp_optimize_png` on the original bytes. The pixels stay bit-identical.

### SVG output (SVG input only)

- Run `krimp_svg_rewrite`:
  - `minify = true` when the Format card is on.
  - Pass the target width/height when Resize is on.
- **Visual safety net:**
  - Render the original and the rewritten SVG with resvg at 512 px on the long edge and compare pixels.
  - If they differ beyond a small tolerance (tune it on fixtures; start at max channel diff 8 and mean abs diff 0.5), keep the original untouched and mark the item "Skipped: minify changed rendering".
  - Log which oxvg jobs were enabled, so a misbehaving job can be disabled in config.
- **Raster inputs with SVG chosen as output:** mark them "Can't convert raster to SVG" and skip them.

### Format card ON: compress (slider 1–100, default **90**)

- **JPEG (jpegli):**
  - Quality = slider.
  - jpegli picks the chroma subsampling.
  - Progressive follows the toggle (default on).
- **PNG:**
  - If slider < 100:
    - Run imagequant with `set_quality(min: slider−20, target: slider)`, dithering 1.0.
    - If imagequant can't reach `min`, fall back to lossless full colour.
    - Then run oxipng at preset 4 with libdeflater.
  - If slider = 100: run oxipng only.
  - Zopfli stays off. Mention a possible "max effort" option in your report.
- **WebP:**
  - If slider < 100: lossy, `quality = slider`, `method = 6`, `use_sharp_yuv = 1`, `alpha_quality = 100`.
  - If slider = 100: lossless, `exact = 1`.
- **AVIF (ravif):** quality = slider, alpha quality = slider, speed 3.
- **GIF:** imagequant to ≤ 256 colours, target quality = slider.
- **TIFF:** LZW. The slider is disabled and shows "Lossless".
- **SVG:** oxvg preset-default. The slider is disabled and shows "Lossless".

### Format card OFF: resize only, keep format and quality

- **JPEG:**
  - Re-encode with jpegli at `krimp_jpeg_estimate_quality(source)`, clamped to 50–100.
  - If the estimate returns -1, use **95**.
  - Progressive on.
  - Never q100: it bloats files, often past the original.
- **PNG:** lossless (no quantization, oxipng only).
- **WebP:**
  - `VP8L` source: lossless.
  - Lossy source: q95.
- **AVIF:** q95.
- **GIF:** requantize at quality 100.
- **TIFF:** LZW.
- **SVG:** `krimp_svg_rewrite` with the new size and `minify = false`. Dimensions only.
- **Inputs that aren't an output format** (HEIC, RAW, BMP, PSD…): use the "Same as original" mapping. JPEG at q95, PNG lossless.
- **Both cards off:** the action button is disabled, with the hint "Turn on Resize or Format".

### Concurrency
- At most **2 items in flight**, because imagequant, ravif, resvg and jpegli parallelise internally.
- Processing is cancellable via Stop.
- Progress is shown per item.
- No encoding on the main actor.

---

## Output

The Output card has a segmented control with two modes.

### Replace original (default)
1. Write to a temp file on the same volume.
2. Move the original to the **Trash** (`FileManager.trashItem`).
3. Move the temp file to `<original basename>.<new ext>`.

If trashing fails (e.g. a volume with no Trash), ask before permanently replacing. Never delete silently.

### Save copy
- Target name: `<prefix><basename><suffix>.<ext>` in the same folder.
- Defaults: **prefix empty**, **suffix `-small`**.
- **Prefix and suffix both empty + same extension:** the target would be the original itself, so use the suffix **`-copy`** (`photo.jpg` → `photo-copy.jpg`).
- **Prefix and suffix both empty + different extension:** no suffix needed (`photo.png` → `photo.webp`).
- **Collision with an existing file:** append `-2`, `-3`, … (`photo-small.jpg` → `photo-small-2.jpg`). Never overwrite.
- Reject `/` and `:` in the prefix and suffix fields, with inline validation.

### Both modes
- **"Skip if larger"** toggle, default on:
  - Same output format as input, no resize, and result ≥ original: keep the original untouched and mark the item "Already optimal".
  - Format changed and result larger: write it anyway (it was asked for), but show the delta in red.
- Errors are shown per item: read-only file, disk full, unsupported. One failure never stops the batch.
- File dates are not preserved (out of scope).

### "Same as original" format
This is the first option in the format popup.
- If the input format is also an output format, keep it. **SVG input → SVG (minified).**
- Otherwise (HEIC, RAW, BMP, PSD…): **PNG** when the image has meaningful alpha, **JPEG** otherwise.
- Show the resolved conversion on the thumbnail badge, e.g. `HEIC → JPEG` or `SVG → SVG`.

---

## Supported input

- **Raster formats:** whatever ImageIO decodes on the running system.
  - Build the accepted `UTType` list from `CGImageSourceCopyTypeIdentifiers()` at launch.
  - Add `public.svg-image` and `.svgz`.
  - Use the same list for the open panel, drag-and-drop and Dock drops.
- **Reference list** (from FileFlow's thumbnail service). Log which of these ImageIO handles:

```
jpg jpeg jpe jfif png gif webp avif heic heif tif tiff bmp ico cur tga psd jp2 jpf jxl exr hdr dds
pbm pgm ppm pnm pam
dng cr2 cr3 crw nef nrw arw sr2 srf raf orf rw2 pef 3fr fff iiq mos mrw mef kdc dcr raw
svg svgz
```

- **Explicitly unsupported** (no libraries for these, just show "Unsupported"):
  - PDF, AI, EPS
  - XCF, PCX, WPG, MNG, XPM, XBM, PCD, picon
  - FITS, SGI, RAS, unless ImageIO happens to decode them

---

## UI

A single window modelled on Squash, trimmed down: content on the left, an inspector on the right.

### Left pane: Grid or Table
The toolbar has a segmented toggle between the two views. The view switches to **Table automatically when a batch finishes**.

**Grid**
- Thumbnails from `CGImageSourceCreateThumbnailAtIndex` at ~256 px (SVG via `krimp_svg_render`).
- Badges:
  - Before processing: `JPEG · 722 KB`
  - After processing: `WebP · 214 KB (−70%)`
  - Status: Already optimal / Unsupported / Skipped / Error, with a hover tooltip.

**Table (results)** — a SwiftUI `Table` with these columns:

| Column | Example |
|---|---|
| Name | `IMG_0412.HEIC` |
| Conversion | `HEIC → JPEG` |
| Dimensions | `4032×3024 → 2000×1500` |
| Old size | `3.4 MB` |
| New size | `612 KB` |
| % | `−82%`, red when positive |
| Status | ✓ / Already optimal / Skipped / Error |

- All columns are sortable.
- A pinned **totals row** shows the summed old size, summed new size and overall %. Only processed items count.
- Context menu "Copy results as Markdown" puts the table plus totals on the clipboard.

**Common to both views**
- Empty state: "Drop images here" with an "Open…" button.
- Context menu: Reveal in Finder, Remove from list.
- Toolbar: Add (⌘O), Grid/Table toggle, Clear list (trash icon).

### Right pane: inspector
Three cards styled like Squash's: rounded group boxes with title, subtitle, a header toggle where noted, and controls below.

1. **Resize** (toggle, default off)
   - Mode popup: Width / Height / Longest edge / Percentage.
   - Value field: pixels, or %.
2. **Format** (toggle, default **on**)
   - **On:**
     - Format popup: Same as original / JPEG / PNG / WebP / AVIF / GIF / TIFF / SVG.
     - Quality slider with a numeric label, default 90%. Disabled and showing "Lossless" for TIFF/SVG.
     - Progressive toggle, shown only for JPEG.
   - **Off:** the subtitle reads "Keep format and quality" and the controls collapse.
3. **Output**
   - Segmented control: Replace original / Save copy.
   - Prefix and Suffix fields, Save copy only. Defaults: empty / `-small`.
   - "Skip if larger" toggle.

**Bottom of the inspector:** one full-width primary button. Its label follows the mode: "Compress 3 Images", "Resize 3 Images" (Format off) or "Save 3 Copies". While running it becomes "Stop".

### Opening files
- Drag onto the window or the Dock icon.
- ⌘O.
- Finder's "Open With": declare `CFBundleDocumentTypes` with `LSHandlerRank = Alternate` so Krimp never becomes the default app.

### Settings
All inspector settings and the Grid/Table choice persist via `@AppStorage`. There is no Settings window.

---

## Phases

### Report after every phase
- What's done, and anything that deviates from this plan.
- **App size table**, comparing against the previous phase:

  | Component | Previous | Now | Δ % |
  |---|---|---|---|
  | `Krimp.app` total | | | |
  | main executable | | | |
  | └ jpegli | | | |
  | └ libwebp | | | |
  | └ imagequant + oxipng | | | |
  | └ ravif / rav1e | | | |
  | └ resvg (+ text) | | | |
  | └ oxvg (+ lightningcss) | | | |
  | └ Swift app code | | | |

  Use `cargo bloat --crates` (dev-only) for the Rust split. Phase 0 has no "Previous" column.
- Open questions.

### Phase 0: scaffolding
- `LICENSE`, `THIRD_PARTY_NOTICES.md` skeleton, Makefile, XcodeGen project, Rust crate, cbindgen header, build phase, linking.
- A test that round-trips a 2×2 RGBA buffer through `krimp_encode` for every format, renders one trivial SVG and minifies it.

### Phase 1: Rust core
- Implement jpeg (incl. quality estimation), png (incl. `krimp_optimize_png`), webp, gif, avif, svg render and svg rewrite/minify, with `cargo test` per module.
- `ssimulacra2` as a **dev-dependency only**: log quality scores at slider 90 on 3 photo fixtures and 2 graphic/screenshot fixtures, and flag anything noticeably low.
- `krimp_jpeg_estimate_quality` must land within ±3 on libjpeg fixtures at q60, q75, q85 and q95.
- SVG minify fixtures:
  - an Illustrator export
  - an Inkscape export (with editor namespaces/metadata)
  - an icon with a `viewBox` only
  - a file with `<style>` + classes
  - one with `<text>`

  Each must shrink and pass the visual safety net. Report per-file savings.

### Phase 2: Swift pipeline
Decode → Normalize → Resize → Encode → Writer, plus ImageIO TIFF and both Format modes. Swift Testing on these fixtures:
- iPhone HEIC (orientation 6, Display P3)
- transparent PNG (check for halos after downscale)
- 16-bit PNG
- CMYK JPEG
- animated GIF
- DNG
- ~50 MP image (check peak memory)
- Unicode + spaces in the filename
- read-only file
- SVG with `viewBox` only
- SVG with text/gradient/clip path
- `.svgz`
- SVG upscaled to 4000 px (must be sharp)
- SVG→SVG with resize (dimensions change, rendering identical)
- resize-only JPEG (estimated quality within ±3 of source)
- copy naming:
  - `-small` default
  - empty prefix/suffix with the same extension → `-copy`
  - empty prefix/suffix with a different extension → bare name
  - collision → `-2`

### Phase 3: UI
As described in the UI section, including the results Table and totals row.

### Phase 4: Output and polish
- Replace/Trash flow, collisions, skip-if-larger, per-item errors, cancel.
- About-panel credits.
- README with screenshots.
- Final report.

---

## Definition of done

- [ ] Release `.app` under 10 MB, arm64, Hardened Runtime, no sandbox, no network code.
- [ ] `find Krimp.app -type f -perm +111` lists only the main executable.
- [ ] `otool -L` on the main executable shows only system frameworks and `/usr/lib` libraries.
- [ ] Rotated iPhone photos come out upright, and P3 photos don't shift colour.
- [ ] Defaults (resize off, format on, same format, q90): a typical iPhone JPEG comes out visibly identical and smaller.
- [ ] Format off + Resize on: a JPEG gets smaller dimensions at matching quality and isn't bloated.
- [ ] SVG → raster is sharp at any size, including text.
- [ ] SVG → SVG minify never ships a visually different file.
- [ ] The results table shows old, new and % per file, plus totals.
- [ ] Replace mode always leaves the original in the Trash.
- [ ] Save copy never overwrites anything.
- [ ] `LICENSE` (GPL-3.0-or-later) and `THIRD_PARTY_NOTICES.md` are present, and the About panel shows the credits.
- [ ] The app quits when its window closes and leaves nothing running.

## Out of scope (don't build, don't ask)

- Menu bar app, drop zones, presets, pipelines, watch folders, clipboard optimisation
- Raster → SVG tracing
- Video, PDF
- Metadata preservation, date retention
- Watermarks, borders, effects
- Rename beyond prefix/suffix
- Animated output
- Settings window, auto-update, localisation (English UI only), CI
