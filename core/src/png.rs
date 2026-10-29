//! PNG: imagequant palette quantisation (lossy) followed by an oxipng pass.

use crate::{Result, quant};
use oxipng::{BitDepth, ColorType, Deflater, Options, RawImage, StripChunks, ZopfliOptions};

fn options(lossy: bool, max_effort: bool) -> Options {
    let mut opts = Options::from_preset(4);
    if max_effort {
        opts.deflater = Deflater::Zopfli(ZopfliOptions::default());
    }
    opts.strip = StripChunks::All;
    // Rewriting RGB under fully transparent pixels is invisible, but keep lossless output exact.
    opts.optimize_alpha = lossy;
    opts
}

pub fn encode(rgba: &[u8], width: u32, height: u32, quality: u8, max_effort: bool) -> Result<Vec<u8>> {
    if quality < 100 {
        let pixels = quant::as_pixels(rgba);
        let min = quality.saturating_sub(20);
        if let Some(q) = quant::quantize(&pixels, width, height, min, quality, 1.0)? {
            let palette = q.palette.iter().map(|c| rgb::RGBA8::new(c.r, c.g, c.b, c.a)).collect();
            let raw = RawImage::new(width, height, ColorType::Indexed { palette }, BitDepth::Eight, q.indices)
                .map_err(|e| format!("oxipng: {e}"))?;
            return raw.create_optimized_png(&options(true, max_effort)).map_err(|e| format!("oxipng: {e}"));
        }
    }
    let raw = RawImage::new(width, height, ColorType::RGBA, BitDepth::Eight, rgba.to_vec())
        .map_err(|e| format!("oxipng: {e}"))?;
    raw.create_optimized_png(&options(false, max_effort)).map_err(|e| format!("oxipng: {e}"))
}

/// Lossless re-optimisation of an existing PNG; pixel data stays bit-identical.
pub fn optimize(png: &[u8], max_effort: bool) -> Result<Vec<u8>> {
    oxipng::optimize_from_memory(png, &options(false, max_effort)).map_err(|e| format!("oxipng: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    const COLOR_TYPE_OFFSET: usize = 25;
    const INDEXED: u8 = 3;

    #[test]
    fn lossless_is_exact() {
        let img = decode(&fixture("photos/kodim03.png"));
        let png = encode(&img.rgba, img.width, img.height, 100, false).unwrap();
        assert_eq!(decode_png(&png).rgba, img.rgba);
    }

    #[test]
    fn lossy_quantizes_graphics_to_a_palette() {
        let img = decode(&fixture("graphics/poster.png"));
        let lossy = encode(&img.rgba, img.width, img.height, 90, false).unwrap();
        let lossless = encode(&img.rgba, img.width, img.height, 100, false).unwrap();
        assert_eq!(lossy[COLOR_TYPE_OFFSET], INDEXED);
        assert!(lossy.len() < lossless.len(), "{} vs {}", lossy.len(), lossless.len());
    }

    #[test]
    fn falls_back_to_full_colour_when_quality_unreachable() {
        // Noise can't be represented in 256 colours at quality ≥ 70.
        let mut state = 0x1234_5678u32;
        let rgba: Vec<u8> = (0..64 * 64)
            .flat_map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                let b = state.to_le_bytes();
                [b[0], b[1], b[2], 255]
            })
            .collect();
        let png = encode(&rgba, 64, 64, 90, false).unwrap();
        assert_ne!(png[COLOR_TYPE_OFFSET], INDEXED);
        assert_eq!(decode_png(&png).rgba, rgba);
    }

    #[test]
    fn optimize_keeps_pixels_and_strips_metadata() {
        let original = fixture("graphics/ui-screenshot.png");
        let tagged = insert_png_chunk(&original, b"tEXt", b"Comment\0secret");
        let tagged = insert_png_chunk(&tagged, b"eXIf", b"MM\0*\0\0\0\x08\0\0");
        assert!(png_chunks(&tagged).contains(&"tEXt".to_string()));

        let optimized = optimize(&tagged, false).unwrap();
        assert_eq!(decode_png(&optimized).rgba, decode_png(&original).rgba);
        assert!(optimized.len() <= original.len());
        let chunks = png_chunks(&optimized);
        assert!(chunks.iter().all(|c| ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"].contains(&c.as_str())), "{chunks:?}");
    }

    #[test]
    fn keeps_alpha() {
        let rgba = [[255u8, 0, 0, 255], [0, 0, 255, 128], [0, 0, 0, 0], [0, 255, 0, 255]].concat();
        for q in [90, 100] {
            let png = encode(&rgba, 2, 2, q, false).unwrap();
            let px = decode_png(&png);
            assert_eq!(px.pixel(0, 1)[3], 0);
            assert!((i32::from(px.pixel(1, 0)[3]) - 128).abs() <= 2);
        }
    }

    #[test]
    fn max_effort_is_smaller_and_lossless() {
        let original = fixture("graphics/ui-screenshot.png");
        let normal = optimize(&original, false).unwrap();
        let zopfli = optimize(&original, true).unwrap();
        println!("oxipng {} B, zopfli {} B", normal.len(), zopfli.len());
        assert!(zopfli.len() <= normal.len());
        assert_eq!(decode_png(&zopfli).rgba, decode_png(&original).rgba);
    }
}
