//! Shared imagequant palette quantisation for PNG and GIF.

use crate::Result;
use imagequant::RGBA;

pub struct Quantized {
    pub palette: Vec<RGBA>,
    pub indices: Vec<u8>,
}

/// Quantises to ≤ 256 colours. Returns `Ok(None)` when imagequant can't reach `min_quality`.
pub fn quantize(
    pixels: &[RGBA],
    width: u32,
    height: u32,
    min_quality: u8,
    target_quality: u8,
    dithering: f32,
) -> Result<Option<Quantized>> {
    let mut attr = imagequant::new();
    attr.set_quality(min_quality, target_quality).map_err(|e| format!("imagequant: {e}"))?;
    let mut image = attr
        .new_image_borrowed(pixels, width as usize, height as usize, 0.0)
        .map_err(|e| format!("imagequant: {e}"))?;
    let mut result = match attr.quantize(&mut image) {
        Ok(r) => r,
        Err(imagequant::Error::QualityTooLow) => return Ok(None),
        Err(e) => return Err(format!("imagequant: {e}")),
    };
    result.set_dithering_level(dithering).map_err(|e| format!("imagequant: {e}"))?;
    let (palette, indices) = result.remapped(&mut image).map_err(|e| format!("imagequant: {e}"))?;
    Ok(Some(Quantized { palette, indices }))
}

pub fn as_pixels(rgba: &[u8]) -> Vec<RGBA> {
    rgba.chunks_exact(4).map(|p| RGBA::new(p[0], p[1], p[2], p[3])).collect()
}
