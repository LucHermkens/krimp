//! Test helpers: fixtures, decoding (in-process for PNG/WebP/GIF, via `sips` for the rest)
//! and SSIMULACRA2 scoring.

use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

pub fn fixture_path(rel: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../Tests/Fixtures").join(rel)
}

pub fn fixture(rel: &str) -> Vec<u8> {
    std::fs::read(fixture_path(rel)).unwrap_or_else(|e| panic!("{rel}: {e}"))
}

#[derive(Clone)]
pub struct Image {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

impl Image {
    pub fn pixel(&self, x: u32, y: u32) -> [u8; 4] {
        let i = ((y * self.width + x) * 4) as usize;
        self.rgba[i..i + 4].try_into().unwrap()
    }
}

pub fn decode_png(bytes: &[u8]) -> Image {
    let mut decoder = png::Decoder::new(Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().expect("png header");
    let mut buf = vec![0; reader.output_buffer_size().expect("png size")];
    let info = reader.next_frame(&mut buf).expect("png frame");
    buf.truncate(info.buffer_size());
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => buf.chunks_exact(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        png::ColorType::Grayscale => buf.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => unreachable!("EXPAND turns palettes into RGB(A)"),
    };
    Image { rgba, width: info.width, height: info.height }
}

pub fn decode_webp(bytes: &[u8]) -> Image {
    let mut decoder = image_webp::WebPDecoder::new(Cursor::new(bytes)).expect("webp header");
    let (width, height) = decoder.dimensions();
    let mut buf = vec![0; decoder.output_buffer_size().expect("webp size")];
    decoder.read_image(&mut buf).expect("webp image");
    let rgba =
        if decoder.has_alpha() { buf } else { buf.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect() };
    Image { rgba, width, height }
}

pub fn decode_gif(bytes: &[u8]) -> Image {
    let mut options = gif::DecodeOptions::new();
    options.set_color_output(gif::ColorOutput::RGBA);
    let mut decoder = options.read_info(Cursor::new(bytes)).expect("gif header");
    let frame = decoder.read_next_frame().expect("gif frame").expect("one frame");
    Image { rgba: frame.buffer.to_vec(), width: u32::from(frame.width), height: u32::from(frame.height) }
}

/// Decodes anything ImageIO understands by converting it to PNG with `sips` (test-only).
pub fn decode_with_sips(bytes: &[u8]) -> Image {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir()
        .join(format!("krimp-core-test-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed)));
    std::fs::create_dir_all(&dir).unwrap();
    let (input, output) = (dir.join("input"), dir.join("output.png"));
    std::fs::write(&input, bytes).unwrap();
    let status = Command::new("/usr/bin/sips")
        .args(["-s", "format", "png"])
        .arg(&input)
        .arg("--out")
        .arg(&output)
        .output()
        .expect("sips");
    assert!(status.status.success(), "sips failed: {}", String::from_utf8_lossy(&status.stderr));
    let image = decode_png(&std::fs::read(&output).unwrap());
    let _ = std::fs::remove_dir_all(&dir);
    image
}

pub fn decode(bytes: &[u8]) -> Image {
    if bytes.starts_with(b"\x89PNG") {
        decode_png(bytes)
    } else if bytes.starts_with(b"RIFF") {
        decode_webp(bytes)
    } else if bytes.starts_with(b"GIF8") {
        decode_gif(bytes)
    } else {
        decode_with_sips(bytes)
    }
}

/// SSIMULACRA2 of `distorted` against `source`, both composited over white.
pub fn ssimulacra2(source: &Image, distorted: &Image) -> f64 {
    use ssimulacra2::{ColorPrimaries, Rgb, TransferCharacteristic, compute_frame_ssimulacra2};
    assert_eq!((source.width, source.height), (distorted.width, distorted.height));
    let to_rgb = |img: &Image| {
        let data = img
            .rgba
            .chunks_exact(4)
            .map(|p| {
                let a = f32::from(p[3]) / 255.0;
                [0, 1, 2].map(|c| (f32::from(p[c]) / 255.0) * a + (1.0 - a))
            })
            .collect();
        Rgb::new(data, img.width as usize, img.height as usize, TransferCharacteristic::SRGB, ColorPrimaries::BT709)
            .expect("rgb")
    };
    compute_frame_ssimulacra2(to_rgb(source), to_rgb(distorted)).expect("ssimulacra2")
}

/// Walks PNG chunks and returns their four-character types.
pub fn png_chunks(png: &[u8]) -> Vec<String> {
    let mut chunks = Vec::new();
    let mut i = 8;
    while i + 8 <= png.len() {
        let len = u32::from_be_bytes(png[i..i + 4].try_into().unwrap()) as usize;
        chunks.push(String::from_utf8_lossy(&png[i + 4..i + 8]).into_owned());
        i += 12 + len;
    }
    chunks
}

/// Inserts a chunk right after IHDR (used to plant metadata in fixtures).
pub fn insert_png_chunk(png: &[u8], kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let ihdr_end = 8 + 12 + 13;
    let mut crc = flate2::Crc::new();
    crc.update(kind);
    crc.update(data);
    let mut out = png[..ihdr_end].to_vec();
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&crc.sum().to_be_bytes());
    out.extend_from_slice(&png[ihdr_end..]);
    out
}
