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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    #[test]
    fn encodes_decodable_avif() {
        let src = decode(&fixture("photos/kodim03.png"));
        let avif = encode(&src.rgba, src.width, src.height, 90).unwrap();
        assert_eq!(&avif[4..12], b"ftypavif");
        let out = decode(&avif);
        assert_eq!((out.width, out.height), (src.width, src.height));
    }

    #[test]
    fn keeps_alpha() {
        let rgba = [[255u8, 0, 0, 0], [255, 0, 0, 255]].concat().repeat(32);
        let out = decode(&encode(&rgba, 8, 8, 90).unwrap());
        assert!(out.pixel(0, 0)[3] < 8);
        assert!(out.pixel(1, 0)[3] > 247);
    }
}
