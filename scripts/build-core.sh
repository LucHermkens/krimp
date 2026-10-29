#!/bin/sh
# Builds the Rust static library and regenerates Bridge/krimp_core.h.
# Runs from the Xcode "Build Rust core" phase and from `make core`.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Xcode exports hundreds of build settings into this environment, and some of them change how
# jpegli's CMake configures (e.g. it turns BUILD_TESTING on). Run cargo with a clean environment
# so Xcode and command-line builds are identical and share one cache.
run() {
    env -i \
        HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 \
        PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        MACOSX_DEPLOYMENT_TARGET=26.0 \
        ${RUSTUP_TOOLCHAIN:+RUSTUP_TOOLCHAIN="$RUSTUP_TOOLCHAIN"} \
        "$@"
}

cd "$ROOT/core"

# Optional: KRIMP_FEATURES="svg-min" builds without AVIF, etc.
if [ -n "${KRIMP_FEATURES+x}" ]; then
    run cargo build --release --target aarch64-apple-darwin --no-default-features --features "$KRIMP_FEATURES"
else
    run cargo build --release --target aarch64-apple-darwin
fi

# cbindgen only rewrites the header when its content changes.
run cbindgen --quiet --config cbindgen.toml --crate krimp_core --output "$ROOT/Bridge/krimp_core.h" .
