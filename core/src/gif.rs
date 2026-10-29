//! Single-frame GIF: imagequant to ≤ 256 colours with a 1-bit alpha threshold.

use crate::{Result, quant};
use imagequant::RGBA;
use std::borrow::Cow;

pub fn encode(rgba: &[u8], width: u32, height: u32, quality: u8) -> Result<Vec<u8>> {
    let (w, h) = (u16::try_from(width), u16::try_from(height));
    let (Ok(w), Ok(h)) = (w, h) else {
        return Err("GIF supports at most 65535×65535 pixels".into());
    };
    // GIF transparency is on/off: alpha < 128 becomes the transparent index.
    let pixels: Vec<RGBA> = rgba
        .chunks_exact(4)
        .map(|p| if p[3] < 128 { RGBA::new(0, 0, 0, 0) } else { RGBA::new(p[0], p[1], p[2], 255) })
        .collect();
    let q = quant::quantize(&pixels, width, height, 0, quality, 1.0)?
        .ok_or("imagequant could not quantise the image")?;

    let mut palette = Vec::with_capacity(q.palette.len() * 3);
    let mut transparent = None;
    for (i, c) in q.palette.iter().enumerate() {
        palette.extend_from_slice(&[c.r, c.g, c.b]);
        if c.a < 128 && transparent.is_none() {
            transparent = Some(i as u8);
        }
    }

    let mut out = Vec::new();
    {
        let mut encoder = gif::Encoder::new(&mut out, w, h, &palette).map_err(|e| format!("gif: {e}"))?;
        let frame = gif::Frame {
            width: w,
            height: h,
            buffer: Cow::Borrowed(&q.indices),
            transparent,
            ..gif::Frame::default()
        };
        encoder.write_frame(&frame).map_err(|e| format!("gif: {e}"))?;
    }
    Ok(out)
}
