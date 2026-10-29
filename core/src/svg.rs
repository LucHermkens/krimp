//! SVG rendering (resvg), dimension rewriting and minification (oxvg), plus the
//! pixel comparison used as a safety net for minification.

use crate::Result;
use resvg::{tiny_skia, usvg};
use std::ffi::CString;
use std::io::Read;
use std::sync::{Arc, OnceLock};

/// oxvg jobs from preset-default that are switched off. Add a job's snake_case name here
/// (as listed by `krimp_svg_minify_jobs`) if it turns out to change rendering.
#[cfg(feature = "svg-min")]
const DISABLED_JOBS: &[&str] = &[];

const GZIP_MAGIC: [u8; 2] = [0x1F, 0x8B];

/// Returns the document as text, gunzipping `.svgz` input.
fn decode_text(data: &[u8]) -> Result<String> {
    if data.starts_with(&GZIP_MAGIC) {
        let mut text = String::new();
        flate2::read::MultiGzDecoder::new(data)
            .read_to_string(&mut text)
            .map_err(|e| format!("svgz: {e}"))?;
        Ok(text)
    } else {
        String::from_utf8(data.to_vec()).map_err(|_| "SVG is not valid UTF-8".into())
    }
}

/// System fonts, loaded once and shared by every render.
fn fontdb() -> Arc<usvg::fontdb::Database> {
    static DB: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    DB.get_or_init(|| {
        let mut db = usvg::fontdb::Database::new();
        db.load_system_fonts();
        // usvg's defaults are Times New Roman / Arial etc.; make sure the generic families
        // resolve to fonts that ship with macOS.
        db.set_serif_family("Times New Roman");
        db.set_sans_serif_family("Helvetica");
        db.set_monospace_family("Menlo");
        Arc::new(db)
    })
    .clone()
}

fn parse(data: &[u8], with_fonts: bool) -> Result<usvg::Tree> {
    let mut opts = usvg::Options::default();
    if with_fonts {
        opts.fontdb = fontdb();
    }
    usvg::Tree::from_data(data, &opts).map_err(|e| format!("SVG: {e}"))
}

/// Intrinsic size: width/height attributes, else the viewBox.
pub fn size(data: &[u8]) -> Result<(f32, f32)> {
    let size = parse(data, false)?.size();
    Ok((size.width(), size.height()))
}

fn render_tree(tree: &usvg::Tree, width: u32, height: u32) -> Result<Vec<u8>> {
    let mut pixmap = tiny_skia::Pixmap::new(width, height).ok_or("invalid render size")?;
    let size = tree.size();
    let transform =
        tiny_skia::Transform::from_scale(width as f32 / size.width(), height as f32 / size.height());
    resvg::render(tree, transform, &mut pixmap.as_mut());
    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for px in pixmap.pixels() {
        let c = px.demultiply();
        rgba.extend_from_slice(&[c.red(), c.green(), c.blue(), c.alpha()]);
    }
    Ok(rgba)
}

/// Renders at exactly `width`×`height` (stretching if the aspect differs) to straight-alpha RGBA.
pub fn render(data: &[u8], width: u32, height: u32) -> Result<Vec<u8>> {
    if width == 0 || height == 0 {
        return Err("render size is zero".into());
    }
    render_tree(&parse(data, true)?, width, height)
}

/// SVG → SVG: optional minification, then optional new root width/height.
/// Output is always plain UTF-8, even for `.svgz` input.
pub fn rewrite(data: &[u8], width: u32, height: u32, minify: bool) -> Result<Vec<u8>> {
    let original = decode_text(data)?;
    let mut text = if minify { minify_text(&original)? } else { original.clone() };
    if width > 0 && height > 0 {
        let old = size(original.as_bytes())?;
        text = set_root_size(&text, width, height, old)?;
    }
    Ok(text.into_bytes())
}

fn xml_options<'a>() -> roxmltree::ParsingOptions<'a> {
    roxmltree::ParsingOptions { allow_dtd: true, ..Default::default() }
}

fn format_number(v: f32) -> String {
    let s = format!("{v:.3}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() { "0".into() } else { s.into() }
}

/// Sets `width`/`height` on the root element by splicing the source text, so nothing else in
/// the document changes. Adds a viewBox built from the old size when there is none.
fn set_root_size(text: &str, width: u32, height: u32, old: (f32, f32)) -> Result<String> {
    let doc = roxmltree::Document::parse_with_options(text, xml_options()).map_err(|e| format!("SVG: {e}"))?;
    let root = doc.root_element();
    if root.tag_name().name() != "svg" {
        return Err("root element is not <svg>".into());
    }

    // (byte range to replace, replacement), applied back to front.
    let mut edits: Vec<(std::ops::Range<usize>, String)> = Vec::new();
    let mut additions = String::new();
    for (name, value) in [("width", width.to_string()), ("height", height.to_string())] {
        match root.attributes().find(|a| a.namespace().is_none() && a.name() == name) {
            Some(attr) => edits.push((attr.range_value(), value)),
            None => additions.push_str(&format!(" {name}=\"{value}\"")),
        }
    }
    if root.attribute("viewBox").is_none() {
        additions.push_str(&format!(" viewBox=\"0 0 {} {}\"", format_number(old.0), format_number(old.1)));
    }
    if !additions.is_empty() {
        // Insert right after the element name (`<svg` or `<prefix:svg`).
        let start = root.range().start;
        let name_len = text[start + 1..]
            .find(|c: char| c.is_whitespace() || c == '/' || c == '>')
            .ok_or("malformed <svg> tag")?;
        let at = start + 1 + name_len;
        edits.push((at..at, additions));
    }

    edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    let mut out = text.to_string();
    for (range, replacement) in edits {
        out.replace_range(range, &replacement);
    }
    Ok(out)
}

#[cfg(feature = "svg-min")]
fn jobs() -> Result<oxvg_optimiser::Jobs> {
    let mut value = serde_json::to_value(oxvg_optimiser::Jobs::default()).map_err(|e| e.to_string())?;
    if let Some(map) = value.as_object_mut() {
        for job in DISABLED_JOBS {
            map.remove(*job);
        }
    }
    serde_json::from_value(value).map_err(|e| e.to_string())
}

#[cfg(feature = "svg-min")]
fn minify_text(text: &str) -> Result<String> {
    use oxvg_ast::{parse::roxmltree::parse_with_options, serialize::Node as _, visitor::Info};
    let jobs = jobs()?;
    let options = oxvg_ast::parse::roxmltree::ParsingOptions { allow_dtd: true, ..Default::default() };
    parse_with_options(text, options, |dom, allocator| -> Result<String> {
        jobs.run(dom, &Info::new(allocator)).map_err(|e| format!("oxvg: {e}"))?;
        dom.serialize().map_err(|e| format!("oxvg: {e}"))
    })
    .map_err(|e| format!("oxvg: {e}"))?
}

#[cfg(not(feature = "svg-min"))]
fn minify_text(_text: &str) -> Result<String> {
    Err("SVG minification is not compiled in".into())
}

/// Jobs that run when minifying, as a static comma-separated C string.
pub fn enabled_jobs() -> &'static CString {
    static JOBS: OnceLock<CString> = OnceLock::new();
    JOBS.get_or_init(|| {
        #[cfg(feature = "svg-min")]
        let list = jobs()
            .ok()
            .and_then(|j| serde_json::to_value(j).ok())
            .and_then(|v| v.as_object().map(|m| m.keys().cloned().collect::<Vec<_>>().join(",")))
            .unwrap_or_default();
        #[cfg(not(feature = "svg-min"))]
        let list = String::new();
        CString::new(list).unwrap_or_default()
    })
}

pub struct Diff {
    /// Largest difference in any channel of any pixel.
    pub max: u8,
    /// Mean absolute difference over all channels.
    pub mean: f32,
}

/// Renders both documents into the same box (`long_edge` px on the long side, aspect from `a`)
/// and compares premultiplied-equivalent pixels.
pub fn compare(a: &[u8], b: &[u8], long_edge: u32) -> Result<Diff> {
    let ta = parse(a, true)?;
    let tb = parse(b, true)?;
    let s = ta.size();
    let scale = long_edge as f32 / s.width().max(s.height());
    let w = ((s.width() * scale).round() as u32).max(1);
    let h = ((s.height() * scale).round() as u32).max(1);
    let pa = render_tree(&ta, w, h)?;
    let pb = render_tree(&tb, w, h)?;

    let mut max = 0u8;
    let mut total = 0u64;
    for (x, y) in pa.chunks_exact(4).zip(pb.chunks_exact(4)) {
        // Compare colour weighted by alpha so invisible colour changes don't count.
        let (ax, ay) = (u32::from(x[3]), u32::from(y[3]));
        for c in 0..3 {
            let vx = (u32::from(x[c]) * ax + 127) / 255;
            let vy = (u32::from(y[c]) * ay + 127) / 255;
            let d = vx.abs_diff(vy) as u8;
            max = max.max(d);
            total += u64::from(d);
        }
        let d = x[3].abs_diff(y[3]);
        max = max.max(d);
        total += u64::from(d);
    }
    Ok(Diff { max, mean: total as f32 / pa.len() as f32 })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ICON: &str = r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="20" fill="red"/></svg>"#;

    #[test]
    fn size_from_viewbox() {
        assert_eq!(size(ICON.as_bytes()).unwrap(), (24.0, 24.0));
    }

    #[test]
    fn rewrite_sets_dimensions_only() {
        let out = String::from_utf8(rewrite(ICON.as_bytes(), 48, 48, false).unwrap()).unwrap();
        assert_eq!(
            out,
            r#"<svg width="48" height="48" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="20" fill="red"/></svg>"#
        );
        assert_eq!(size(out.as_bytes()).unwrap(), (48.0, 48.0));
    }

    #[test]
    fn rewrite_adds_viewbox_when_missing() {
        let src = r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="20"><rect width="10" height="20"/></svg>"#;
        let out = String::from_utf8(rewrite(src.as_bytes(), 5, 10, false).unwrap()).unwrap();
        assert!(out.contains(r#"width="5""#) && out.contains(r#"height="10""#));
        assert!(out.contains(r#"viewBox="0 0 10 20""#));
        let diff = compare(src.as_bytes(), out.as_bytes(), 64).unwrap();
        assert_eq!(diff.max, 0);
    }

    #[test]
    fn render_is_straight_alpha() {
        let px = render(ICON.as_bytes(), 24, 24).unwrap();
        assert_eq!(&px[0..4], &[0, 0, 0, 0]);
        let center = (12 * 24 + 12) * 4;
        assert_eq!(&px[center..center + 4], &[255, 0, 0, 255]);
    }

    #[cfg(feature = "svg-min")]
    #[test]
    fn minify_shrinks_and_matches() {
        let src = r##"<?xml version="1.0"?>
<!-- comment -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <metadata>junk</metadata>
  <g><rect x="2.0000" y="2.0000" width="20" height="20" fill="#ff0000"/></g>
</svg>"##;
        let out = rewrite(src.as_bytes(), 0, 0, true).unwrap();
        assert!(out.len() < src.len());
        let diff = compare(src.as_bytes(), &out, 128).unwrap();
        assert_eq!(diff.max, 0);
    }
}
