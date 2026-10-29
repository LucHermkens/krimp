//! krimp_core: the encoders and SVG tooling behind Krimp, exposed through a small C ABI.
//!
//! Every `extern "C"` function runs inside [`ffi_call`], which turns both `Err` values and
//! panics into a negative return code plus a thread-local message for `krimp_last_error`.

#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

#[cfg(feature = "avif")]
pub mod avif;
pub mod gif;
pub mod jpeg;
pub mod png;
mod quant;
pub mod svg;
pub mod webp;

pub type Result<T> = std::result::Result<T, String>;

/// Output formats `krimp_encode` can produce.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(non_camel_case_types)]
pub enum KrimpFormat {
    KRIMP_JPEG,
    KRIMP_PNG,
    KRIMP_WEBP,
    KRIMP_GIF,
    KRIMP_AVIF,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct KrimpOptions {
    pub format: KrimpFormat,
    /// 1–100; 100 = lossless where the format supports it.
    pub quality: u8,
    /// JPEG only.
    pub progressive: bool,
}

#[repr(C)]
#[derive(Debug)]
pub struct KrimpBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

impl KrimpBuffer {
    fn from_vec(v: Vec<u8>) -> Self {
        let mut boxed = v.into_boxed_slice();
        let buf = KrimpBuffer { ptr: boxed.as_mut_ptr(), len: boxed.len() };
        std::mem::forget(boxed);
        buf
    }
}

/// Bit for `krimp_available_features`: AVIF encoding is compiled in.
pub const KRIMP_FEATURE_AVIF: u32 = 1 << 0;
/// Bit for `krimp_available_features`: SVG minification is compiled in.
pub const KRIMP_FEATURE_SVG_MIN: u32 = 1 << 1;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_last_error(message: &str) {
    let c = CString::new(message.replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|e| *e.borrow_mut() = c);
}

/// Runs `f`, converting errors and panics into `-1` + `krimp_last_error`.
fn ffi_call(f: impl FnOnce() -> Result<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => {
            set_last_error("");
            0
        }
        Ok(Err(e)) => {
            set_last_error(&e);
            -1
        }
        Err(panic) => {
            let msg = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".into());
            set_last_error(&format!("internal error: {msg}"));
            -2
        }
    }
}

unsafe fn slice<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8]> {
    if ptr.is_null() {
        return Err("null input".into());
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Encodes straight-alpha sRGB RGBA (`width * 4` stride) into `opts.format`.
pub fn encode(rgba: &[u8], width: u32, height: u32, opts: KrimpOptions) -> Result<Vec<u8>> {
    if width == 0 || height == 0 {
        return Err("image has zero size".into());
    }
    let expected = width as usize * height as usize * 4;
    if rgba.len() != expected {
        return Err(format!("expected {expected} bytes of RGBA, got {}", rgba.len()));
    }
    let quality = opts.quality.clamp(1, 100);
    match opts.format {
        KrimpFormat::KRIMP_JPEG => jpeg::encode(rgba, width, height, quality, opts.progressive),
        KrimpFormat::KRIMP_PNG => png::encode(rgba, width, height, quality),
        KrimpFormat::KRIMP_WEBP => webp::encode(rgba, width, height, quality),
        KrimpFormat::KRIMP_GIF => gif::encode(rgba, width, height, quality),
        #[cfg(feature = "avif")]
        KrimpFormat::KRIMP_AVIF => avif::encode(rgba, width, height, quality),
        #[cfg(not(feature = "avif"))]
        KrimpFormat::KRIMP_AVIF => Err("AVIF support is not compiled in".into()),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_encode(
    rgba: *const u8,
    width: u32,
    height: u32,
    opts: KrimpOptions,
    out: *mut KrimpBuffer,
) -> i32 {
    ffi_call(|| {
        let len = (width as usize)
            .checked_mul(height as usize)
            .and_then(|n| n.checked_mul(4))
            .ok_or("image too large")?;
        let input = unsafe { slice(rgba, len)? };
        let bytes = encode(input, width, height, opts)?;
        unsafe { *out = KrimpBuffer::from_vec(bytes) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_optimize_png(png: *const u8, len: usize, out: *mut KrimpBuffer) -> i32 {
    ffi_call(|| {
        let input = unsafe { slice(png, len)? };
        let bytes = png::optimize(input)?;
        unsafe { *out = KrimpBuffer::from_vec(bytes) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_jpeg_estimate_quality(jpeg: *const u8, len: usize) -> i32 {
    let mut quality = -1;
    let status = ffi_call(|| {
        let input = unsafe { slice(jpeg, len)? };
        quality = jpeg::estimate_quality(input).map_or(-1, i32::from);
        Ok(())
    });
    if status == 0 { quality } else { -1 }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_svg_size(svg: *const u8, len: usize, width: *mut f32, height: *mut f32) -> i32 {
    ffi_call(|| {
        let input = unsafe { slice(svg, len)? };
        let (w, h) = svg::size(input)?;
        unsafe {
            *width = w;
            *height = h;
        }
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_svg_render(
    svg: *const u8,
    len: usize,
    width: u32,
    height: u32,
    out_rgba: *mut KrimpBuffer,
) -> i32 {
    ffi_call(|| {
        let input = unsafe { slice(svg, len)? };
        let pixels = svg::render(input, width, height)?;
        unsafe { *out_rgba = KrimpBuffer::from_vec(pixels) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_svg_rewrite(
    svg: *const u8,
    len: usize,
    width: u32,
    height: u32,
    minify: bool,
    out: *mut KrimpBuffer,
) -> i32 {
    ffi_call(|| {
        let input = unsafe { slice(svg, len)? };
        let bytes = svg::rewrite(input, width, height, minify)?;
        unsafe { *out = KrimpBuffer::from_vec(bytes) };
        Ok(())
    })
}

/// Renders both SVGs at `size` px on the long edge and compares them.
/// Writes the largest per-channel difference and the mean absolute difference.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_svg_compare(
    a: *const u8,
    a_len: usize,
    b: *const u8,
    b_len: usize,
    size: u32,
    max_diff: *mut u8,
    mean_diff: *mut f32,
) -> i32 {
    ffi_call(|| {
        let (a, b) = unsafe { (slice(a, a_len)?, slice(b, b_len)?) };
        let diff = svg::compare(a, b, size)?;
        unsafe {
            *max_diff = diff.max;
            *mean_diff = diff.mean;
        }
        Ok(())
    })
}

/// Comma-separated oxvg jobs that `krimp_svg_rewrite` runs when minifying (empty without `svg-min`).
/// The string is static and must not be freed.
#[unsafe(no_mangle)]
pub extern "C" fn krimp_svg_minify_jobs() -> *const c_char {
    svg::enabled_jobs().as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn krimp_buffer_free(buf: KrimpBuffer) {
    if !buf.ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buf.ptr, buf.len)) });
    }
}

/// Thread-local; valid until the next krimp_* call on the same thread.
#[unsafe(no_mangle)]
pub extern "C" fn krimp_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn krimp_available_features() -> u32 {
    let mut features = 0;
    if cfg!(feature = "avif") {
        features |= KRIMP_FEATURE_AVIF;
    }
    if cfg!(feature = "svg-min") {
        features |= KRIMP_FEATURE_SVG_MIN;
    }
    features
}

#[cfg(test)]
mod tests {
    use super::*;

    const PIXELS: [u8; 16] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 0];

    #[test]
    fn encodes_2x2_in_every_format() {
        let formats = [
            (KrimpFormat::KRIMP_JPEG, &b"\xFF\xD8"[..]),
            (KrimpFormat::KRIMP_PNG, &b"\x89PNG"[..]),
            (KrimpFormat::KRIMP_WEBP, &b"RIFF"[..]),
            (KrimpFormat::KRIMP_GIF, &b"GIF8"[..]),
            #[cfg(feature = "avif")]
            (KrimpFormat::KRIMP_AVIF, &b"\0\0\0"[..]),
        ];
        for (format, magic) in formats {
            for quality in [90, 100] {
                let opts = KrimpOptions { format, quality, progressive: true };
                let bytes = encode(&PIXELS, 2, 2, opts).unwrap_or_else(|e| panic!("{format:?}: {e}"));
                assert!(bytes.starts_with(magic), "{format:?} q{quality}");
            }
        }
    }

    #[test]
    fn ffi_reports_errors() {
        let mut out = KrimpBuffer { ptr: std::ptr::null_mut(), len: 0 };
        let opts = KrimpOptions { format: KrimpFormat::KRIMP_PNG, quality: 90, progressive: false };
        let status = unsafe { krimp_encode(PIXELS.as_ptr(), 0, 2, opts, &mut out) };
        assert_eq!(status, -1);
        let msg = unsafe { std::ffi::CStr::from_ptr(krimp_last_error()) };
        assert!(msg.to_str().unwrap().contains("zero size"));
    }
}
