//! PNG: imagequant palette quantisation (lossy) followed by an oxipng pass.

use crate::{Result, quant};
use oxipng::{BitDepth, ColorType, Options, RawImage, StripChunks};

fn options(lossy: bool) -> Options {
    let mut opts = Options::from_preset(4);
    opts.strip = StripChunks::All;
    // Rewriting RGB under fully transparent pixels is invisible, but keep lossless output exact.
    opts.optimize_alpha = lossy;
    opts
}

pub fn encode(rgba: &[u8], width: u32, height: u32, quality: u8) -> Result<Vec<u8>> {
    if quality < 100 {
        let pixels = quant::as_pixels(rgba);
        let min = quality.saturating_sub(20);
        if let Some(q) = quant::quantize(&pixels, width, height, min, quality, 1.0)? {
            let palette = q.palette.iter().map(|c| rgb::RGBA8::new(c.r, c.g, c.b, c.a)).collect();
            let raw = RawImage::new(width, height, ColorType::Indexed { palette }, BitDepth::Eight, q.indices)
                .map_err(|e| format!("oxipng: {e}"))?;
            return raw.create_optimized_png(&options(true)).map_err(|e| format!("oxipng: {e}"));
        }
    }
    let raw = RawImage::new(width, height, ColorType::RGBA, BitDepth::Eight, rgba.to_vec())
        .map_err(|e| format!("oxipng: {e}"))?;
    raw.create_optimized_png(&options(false)).map_err(|e| format!("oxipng: {e}"))
}

/// Lossless re-optimisation of an existing PNG; pixel data stays bit-identical.
pub fn optimize(png: &[u8]) -> Result<Vec<u8>> {
    oxipng::optimize_from_memory(png, &options(false)).map_err(|e| format!("oxipng: {e}"))
}
