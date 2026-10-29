# Krimp

A tiny native macOS app that resizes and re-encodes images and minifies SVGs. Drop files in,
pick a size and an output format (or keep the original format and quality), then replace the
originals or save a copy next to each one.

- Encoders: jpegli (JPEG), imagequant + oxipng (PNG), libwebp (WebP), ravif (AVIF),
  imagequant + gif (GIF), ImageIO (TIFF). SVG: resvg for rendering, oxvg for minifying.
- Every library is compiled from source and statically linked into the one executable.
  No helper processes, no network access, no background anything.
- macOS 26 or newer, Apple silicon.

## Building

Build machine requirements (none are needed at runtime):

- Xcode 26 or newer
- Rust via [rustup](https://rustup.rs) with the `aarch64-apple-darwin` target
- `cmake` (builds jpegli), `xcodegen`, `cbindgen`

```sh
make bootstrap   # checks/installs the tools above and fetches the jpegli submodule
make             # builds build/DerivedData/Build/Products/Release/Krimp.app
make test        # cargo tests + Swift Testing suite
make size        # app size table (needs cargo-bloat)
```

The Xcode project is generated from `project.yml` (`make project`) and is not checked in.
Builds are ad-hoc signed with Hardened Runtime. To sign with your own certificate, create a
git-ignored `Local.xcconfig` next to `project.yml`:

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development
```

## Licence

GPL-3.0-or-later; see `LICENSE`. This is required because the app statically links
libimagequant, which is GPL-3.0-or-later. Bundled libraries and their licences are listed in
`THIRD_PARTY_NOTICES.md`.
