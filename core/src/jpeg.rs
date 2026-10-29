//! JPEG encoding with jpegli and IJG quality estimation from the luma DQT table.

use crate::Result;

unsafe extern "C" {
    fn krimp_jpegli_encode(
        rgb: *const u8,
        width: u32,
        height: u32,
        quality: i32,
        progressive: i32,
        out: *mut *mut u8,
        out_len: *mut usize,
        error: *mut u8,
        error_len: usize,
    ) -> i32;
    fn krimp_jpegli_free(buffer: *mut u8);
}

/// Composites straight-alpha RGBA over white and encodes it with jpegli.
pub fn encode(rgba: &[u8], width: u32, height: u32, quality: u8, progressive: bool) -> Result<Vec<u8>> {
    if width > 65_535 || height > 65_535 {
        return Err("JPEG supports at most 65535×65535 pixels".into());
    }
    let rgb = flatten_over_white(rgba);
    let mut out: *mut u8 = std::ptr::null_mut();
    let mut out_len = 0usize;
    let mut error = [0u8; 256];
    let status = unsafe {
        krimp_jpegli_encode(
            rgb.as_ptr(),
            width,
            height,
            i32::from(quality.clamp(1, 100)),
            i32::from(progressive),
            &mut out,
            &mut out_len,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    if status != 0 || out.is_null() {
        let end = error.iter().position(|&b| b == 0).unwrap_or(error.len());
        return Err(String::from_utf8_lossy(&error[..end]).into_owned());
    }
    let bytes = unsafe { std::slice::from_raw_parts(out, out_len) }.to_vec();
    unsafe { krimp_jpegli_free(out) };
    Ok(bytes)
}

fn flatten_over_white(rgba: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(rgba.len() / 4 * 3);
    for px in rgba.chunks_exact(4) {
        let a = u32::from(px[3]);
        for &c in &px[..3] {
            // c·a + 255·(1−a), rounded.
            rgb.push(((u32::from(c) * a + 255 * (255 - a) + 127) / 255) as u8);
        }
    }
    rgb
}

/// IJG standard luminance quantisation table (natural order), JPEG spec Annex K.1.
const STD_LUMA: [u16; 64] = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22,
    29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103,
    121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];

/// Zigzag position → natural index.
const ZIGZAG: [usize; 64] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
    21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60,
    61, 54, 47, 55, 62, 63,
];

/// Mean relative deviation from the best-fitting IJG table above which the table counts as
/// non-standard.
const MAX_MEAN_RELATIVE_ERROR: f64 = 0.15;

/// Scaled IJG luma table for `quality` (natural order), as libjpeg's `jpeg_set_quality` builds it.
fn ijg_table(quality: u8) -> [u16; 64] {
    let q = u32::from(quality.clamp(1, 100));
    let scale = if q < 50 { 5000 / q } else { 200 - 2 * q };
    STD_LUMA.map(|v| ((u32::from(v) * scale + 50) / 100).clamp(1, 255) as u16)
}

/// Reads the luma (id 0) quantisation table in natural order.
fn luma_table(jpeg: &[u8]) -> Option<[u16; 64]> {
    if jpeg.len() < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
        return None;
    }
    let mut i = 2;
    while i + 4 <= jpeg.len() {
        if jpeg[i] != 0xFF {
            return None;
        }
        let marker = jpeg[i + 1];
        if marker == 0xFF {
            i += 1; // fill byte
            continue;
        }
        if marker == 0xD8 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            i += 2;
            continue;
        }
        if marker == 0xDA || marker == 0xD9 {
            return None; // reached scan data without a luma table
        }
        let len = usize::from(u16::from_be_bytes([jpeg[i + 2], jpeg[i + 3]]));
        let end = i + 2 + len;
        if len < 2 || end > jpeg.len() {
            return None;
        }
        if marker == 0xDB {
            let mut p = i + 4;
            while p < end {
                let precision = jpeg[p] >> 4;
                let id = jpeg[p] & 0x0F;
                p += 1;
                let entry_size = if precision == 0 { 1 } else { 2 };
                if p + 64 * entry_size > end {
                    return None;
                }
                if id == 0 {
                    let mut table = [0u16; 64];
                    for (k, &natural) in ZIGZAG.iter().enumerate() {
                        table[natural] = if entry_size == 1 {
                            u16::from(jpeg[p + k])
                        } else {
                            u16::from_be_bytes([jpeg[p + 2 * k], jpeg[p + 2 * k + 1]])
                        };
                    }
                    return Some(table);
                }
                p += 64 * entry_size;
            }
        }
        i = end;
    }
    None
}

/// Estimates the IJG quality (1–100) that produced this JPEG's luma table.
/// Returns `None` if the table is missing or doesn't resemble a scaled IJG table.
pub fn estimate_quality(jpeg: &[u8]) -> Option<u8> {
    let table = luma_table(jpeg)?;
    let (quality, error) = (1..=100u8)
        .map(|q| {
            let expected = ijg_table(q);
            let err: f64 = table
                .iter()
                .zip(expected.iter())
                .map(|(&a, &e)| (f64::from(a) - f64::from(e)).abs() / f64::from(e))
                .sum::<f64>()
                / 64.0;
            (q, err)
        })
        .min_by(|a, b| a.1.total_cmp(&b.1))?;
    (error <= MAX_MEAN_RELATIVE_ERROR).then_some(quality)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    /// Marker types before the first scan.
    fn markers(jpeg: &[u8]) -> Vec<u8> {
        let mut found = Vec::new();
        let mut i = 2;
        while i + 4 <= jpeg.len() && jpeg[i] == 0xFF {
            let marker = jpeg[i + 1];
            found.push(marker);
            if marker == 0xDA {
                break;
            }
            i += 2 + usize::from(u16::from_be_bytes([jpeg[i + 2], jpeg[i + 3]]));
        }
        found
    }

    #[test]
    fn estimates_libjpeg_quality_within_3() {
        for q in [60, 75, 85, 95] {
            let estimate = estimate_quality(&fixture(&format!("jpeg/kodim23-q{q}.jpg"))).expect("standard table");
            println!("libjpeg q{q} → estimated q{estimate}");
            assert!((i32::from(estimate) - q).abs() <= 3, "q{q} estimated as {estimate}");
        }
    }

    #[test]
    fn rejects_missing_tables() {
        assert_eq!(estimate_quality(b"not a jpeg"), None);
        assert_eq!(estimate_quality(&[0xFF, 0xD8, 0xFF, 0xD9]), None);
    }

    #[test]
    fn ijg_tables_match_libjpeg() {
        assert_eq!(ijg_table(50), STD_LUMA);
        assert!(ijg_table(100).iter().all(|&v| v == 1));
    }

    #[test]
    fn progressive_toggle_and_no_metadata() {
        let img = decode(&fixture("photos/kodim03.png"));
        let progressive = encode(&img.rgba, img.width, img.height, 90, true).unwrap();
        let baseline = encode(&img.rgba, img.width, img.height, 90, false).unwrap();
        assert!(markers(&progressive).contains(&0xC2));
        assert!(markers(&baseline).contains(&0xC0));
        for jpeg in [&progressive, &baseline] {
            // Only JFIF (APP0) may appear; no Exif/XMP (APP1), ICC (APP2) or others.
            assert!(markers(jpeg).iter().all(|m| !(0xE1..=0xEF).contains(m)), "{:x?}", markers(jpeg));
        }
        // jpegli output re-estimates to something sane (informational).
        println!("jpegli q90 → estimated {:?}", estimate_quality(&progressive));
    }

    #[test]
    fn flattens_transparency_over_white() {
        let rgba = [0u8, 0, 0, 0].repeat(64);
        let jpeg = encode(&rgba, 8, 8, 90, true).unwrap();
        let px = decode(&jpeg).pixel(4, 4);
        assert!(px[..3].iter().all(|&c| c >= 250), "{px:?}");
    }
}
