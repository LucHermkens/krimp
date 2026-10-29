# Krimp build entry points. See README.md.

DERIVED   := build/DerivedData
PRODUCTS  := $(DERIVED)/Build/Products
APP       := $(PRODUCTS)/Release/Krimp.app
LINK_MAP  := $(PRODUCTS)/Krimp-LinkMap.txt
XCODEBUILD = xcodebuild -project Krimp.xcodeproj -scheme Krimp -derivedDataPath $(DERIVED)

export PATH := $(HOME)/.cargo/bin:/opt/homebrew/bin:$(PATH)
export MACOSX_DEPLOYMENT_TARGET := 26.0

.PHONY: all bootstrap core project app run test test-core test-app size notices clean

all: app

## Checks for (and where possible installs) the build-time tools. Nothing here is needed at runtime.
bootstrap:
	@xcodebuild -version | head -1 | grep -Eq 'Xcode (2[6-9]|[3-9][0-9])' || { echo "Xcode 26 or newer is required"; exit 1; }
	@command -v rustup >/dev/null || { echo "Install Rust via https://rustup.rs first"; exit 1; }
	rustup target add aarch64-apple-darwin
	@command -v brew >/dev/null || { echo "Homebrew is needed to install cmake and xcodegen (or install them yourself)"; }
	@command -v cmake >/dev/null || brew install cmake
	@command -v xcodegen >/dev/null || brew install xcodegen
	@command -v cbindgen >/dev/null || cargo install --locked cbindgen
	git submodule update --init core/vendor/jpegli
	git -C core/vendor/jpegli submodule update --init --depth 1 third_party/highway third_party/libjpeg-turbo
	@echo "Optional, for 'make size' and 'make notices': cargo install cargo-bloat; cargo install cargo-about --features cli"

core:
	scripts/build-core.sh

project:
	xcodegen generate --quiet

app: project
	$(XCODEBUILD) -configuration Release build | grep -E '^(\*\*|error|warning: [^l])' || true
	@test -d $(APP) && echo "Built $(APP)"

run: app
	open $(APP)

test: test-core test-app

test-core:
	cd core && cargo test --release --target aarch64-apple-darwin

test-app: project
	$(XCODEBUILD) -configuration Debug test | grep -E '^(\*\*|error|✔|✘|􀢄|Test)|passed|failed' || true

## Prints the size table. PREVIOUS=build/size-phase0.json adds a comparison column.
size: app
	scripts/size_report.py $(APP) $(LINK_MAP) --save build/size.json $(if $(PREVIOUS),--previous $(PREVIOUS))

notices:
	cd core && cargo about generate --fail -o ../build/rust-notices.md about.hbs
	scripts/make_notices.py build/rust-notices.md

clean:
	rm -rf build core/target Krimp.xcodeproj Bridge/krimp_core.h
