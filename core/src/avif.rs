//! AVIF via ravif (rav1e).

use crate::{Result, quant};
use ravif::{Encoder, Img};

pub fn encode(rgba: &[u8], width: u32, height: u32, quality: u8) -> Result<Vec<u8>> {
    let pixels = quant::as_pixels(rgba);
    let q = f32::from(quality);
    let encoded = Encoder::new()
        .with_quality(q)
        .with_alpha_quality(q)
        .with_speed(3)
        .encode_rgba(Img::new(&pixels[..], width as usize, height as usize))
        .map_err(|e| format!("ravif: {e}"))?;
    Ok(encoded.avif_file)
}
