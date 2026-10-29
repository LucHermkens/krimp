//! Builds jpegli (C++) statically with CMake and compiles the small C++ shim that
//! exposes a setjmp-safe encode function to Rust.

use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let jpegli_src = manifest.join("vendor/jpegli");
    assert!(
        jpegli_src.join("third_party/highway/CMakeLists.txt").exists(),
        "jpegli submodules missing: run `make bootstrap` (git submodule update --init --recursive)"
    );

    // If the compiler path changes between runs, CMake silently wipes its cache and reconfigures
    // without our -D options (BUILD_TESTING flips back on). Always configure from scratch; this
    // script only reruns when its inputs change, and ninja keeps the object files.
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let _ = std::fs::remove_file(out_dir.join("build/CMakeCache.txt"));

    let mut cfg = cmake::Config::new(&jpegli_src);
    cfg.profile("Release")
        .build_target("jpegli-static")
        .define("BUILD_TESTING", "OFF")
        .define("BUILD_SHARED_LIBS", "OFF")
        .define("JPEGLI_ENABLE_TOOLS", "OFF")
        .define("JPEGLI_ENABLE_BENCHMARK", "OFF")
        .define("JPEGLI_ENABLE_DOXYGEN", "OFF")
        .define("JPEGLI_ENABLE_MANPAGES", "OFF")
        .define("JPEGLI_ENABLE_JNI", "OFF")
        .define("JPEGLI_ENABLE_SJPEG", "OFF")
        .define("JPEGLI_ENABLE_OPENEXR", "OFF")
        .define("JPEGLI_ENABLE_SKCMS", "OFF")
        .define("JPEGLI_ENABLE_FUZZERS", "OFF")
        .define("JPEGLI_ENABLE_JPEGLI_LIBJPEG", "OFF")
        .define("JPEGLI_BUNDLE_LIBPNG", "OFF")
        .define("CMAKE_OSX_ARCHITECTURES", "arm64")
        .define("CMAKE_OSX_DEPLOYMENT_TARGET", "26.0");
    if which("ninja") {
        cfg.generator("Ninja");
    }
    let dst = cfg.build();
    let build = dst.join("build");

    println!("cargo:rustc-link-search=native={}", build.join("lib").display());
    println!("cargo:rustc-link-search=native={}", build.join("third_party/highway").display());
    println!("cargo:rustc-link-lib=static=jpegli-static");
    println!("cargo:rustc-link-lib=static=hwy");

    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("csrc/jpegli_shim.cc")
        .include(&jpegli_src)
        .include(build.join("lib/include/jpegli"))
        .flag("-fno-exceptions")
        .compile("krimp_jpegli_shim");

    println!("cargo:rustc-link-lib=c++");
    println!("cargo:rerun-if-changed=csrc/jpegli_shim.cc");
    println!("cargo:rerun-if-changed=build.rs");
}

fn which(tool: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(tool).is_file()))
        .unwrap_or(false)
}
