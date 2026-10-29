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
