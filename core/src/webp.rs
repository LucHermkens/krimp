//! WebP via libwebp: lossy with sharp YUV below q100, exact lossless at q100.

use crate::Result;
use libwebp_sys::*;
use std::mem::MaybeUninit;

const MAX_DIMENSION: u32 = 16_383;

pub fn encode(rgba: &[u8], width: u32, height: u32, quality: u8) -> Result<Vec<u8>> {
    if width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err(format!("WebP supports at most {MAX_DIMENSION}×{MAX_DIMENSION} pixels"));
    }
    unsafe {
        let mut config = MaybeUninit::<WebPConfig>::zeroed();
        if !WebPInitConfig(config.as_mut_ptr()) {
            return Err("libwebp: version mismatch".into());
        }
        let mut config = config.assume_init();
        if quality >= 100 {
            WebPConfigLosslessPreset(&mut config, 6);
            config.lossless = 1;
            config.exact = 1;
        } else {
            config.lossless = 0;
            config.quality = f32::from(quality);
            config.method = 6;
            config.use_sharp_yuv = 1;
            config.alpha_quality = 100;
        }
        if WebPValidateConfig(&config) == 0 {
            return Err("libwebp: invalid config".into());
        }

        let mut picture = MaybeUninit::<WebPPicture>::zeroed();
        if !WebPPictureInit(picture.as_mut_ptr()) {
            return Err("libwebp: version mismatch".into());
        }
        let mut picture = picture.assume_init();
        picture.use_argb = 1;
        picture.width = width as i32;
        picture.height = height as i32;
        if WebPPictureImportRGBA(&mut picture, rgba.as_ptr(), (width * 4) as i32) == 0 {
            WebPPictureFree(&mut picture);
            return Err("libwebp: out of memory".into());
        }

        let mut writer = MaybeUninit::<WebPMemoryWriter>::zeroed();
        WebPMemoryWriterInit(writer.as_mut_ptr());
        let mut writer = writer.assume_init();
        picture.writer = Some(WebPMemoryWrite);
        picture.custom_ptr = (&mut writer as *mut WebPMemoryWriter).cast();

        let ok = WebPEncode(&config, &mut picture);
        let error = picture.error_code;
        WebPPictureFree(&mut picture);
        if ok == 0 {
            WebPMemoryWriterClear(&mut writer);
            return Err(format!("libwebp: encode failed ({error:?})"));
        }
        let bytes = std::slice::from_raw_parts(writer.mem, writer.size).to_vec();
        WebPMemoryWriterClear(&mut writer);
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    fn chunks(webp: &[u8]) -> Vec<String> {
        let mut found = Vec::new();
        let mut i = 12;
        while i + 8 <= webp.len() {
            found.push(String::from_utf8_lossy(&webp[i..i + 4]).into_owned());
            let len = u32::from_le_bytes(webp[i + 4..i + 8].try_into().unwrap()) as usize;
            i += 8 + len + (len & 1);
        }
        found
    }

    #[test]
    fn lossy_below_100_lossless_at_100() {
        let img = decode(&fixture("photos/kodim15.png"));
        let lossy = encode(&img.rgba, img.width, img.height, 90).unwrap();
        let lossless = encode(&img.rgba, img.width, img.height, 100).unwrap();
        assert_eq!(chunks(&lossy), ["VP8 "]);
        assert_eq!(chunks(&lossless), ["VP8L"]);
        assert_eq!(decode_webp(&lossless).rgba, img.rgba);
    }

    #[test]
    fn lossless_is_exact_under_transparency() {
        let rgba = [[10u8, 20, 30, 0], [40, 50, 60, 255], [70, 80, 90, 128], [1, 2, 3, 0]].concat();
        let webp = encode(&rgba, 2, 2, 100).unwrap();
        assert_eq!(decode_webp(&webp).rgba, rgba);
    }

    #[test]
    fn lossy_keeps_alpha() {
        let rgba = [[255u8, 0, 0, 0], [255, 0, 0, 255]].concat().repeat(32);
        let webp = encode(&rgba, 8, 8, 90).unwrap();
        assert!(chunks(&webp).contains(&"ALPH".to_string()));
        let img = decode_webp(&webp);
        assert_eq!(img.pixel(0, 0)[3], 0);
        assert_eq!(img.pixel(1, 0)[3], 255);
    }

    #[test]
    fn rejects_oversized() {
        assert!(encode(&[0; 4], 20_000, 1, 90).is_err());
    }
}
