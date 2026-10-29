//! Links every exported function so `make size` can measure the core with dead-code
//! stripping applied (`cargo bloat --example size_probe`). Not shipped.

use krimp_core::*;
use std::hint::black_box;

fn main() {
    let px = black_box([0u8; 16]);
    let mut out = KrimpBuffer { ptr: std::ptr::null_mut(), len: 0 };
    let (mut w, mut h, mut max, mut mean) = (0f32, 0f32, 0u8, 0f32);
    unsafe {
        for format in [
            KrimpFormat::KRIMP_JPEG,
            KrimpFormat::KRIMP_PNG,
            KrimpFormat::KRIMP_WEBP,
            KrimpFormat::KRIMP_GIF,
            KrimpFormat::KRIMP_AVIF,
        ] {
            let opts = KrimpOptions { format: black_box(format), quality: black_box(90), progressive: true };
            krimp_encode(px.as_ptr(), 2, 2, opts, &mut out);
            krimp_buffer_free(std::mem::replace(&mut out, KrimpBuffer { ptr: std::ptr::null_mut(), len: 0 }));
        }
        krimp_optimize_png(px.as_ptr(), px.len(), &mut out);
        black_box(krimp_jpeg_estimate_quality(px.as_ptr(), px.len()));
        krimp_svg_size(px.as_ptr(), px.len(), &mut w, &mut h);
        krimp_svg_render(px.as_ptr(), px.len(), 2, 2, &mut out);
        krimp_svg_rewrite(px.as_ptr(), px.len(), 2, 2, black_box(true), &mut out);
        krimp_svg_compare(px.as_ptr(), px.len(), px.as_ptr(), px.len(), 8, &mut max, &mut mean);
        black_box(krimp_svg_minify_jobs());
        black_box(krimp_last_error());
        black_box(krimp_available_features());
    }
    black_box((w, h, max, mean));
}
