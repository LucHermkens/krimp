//! SVG rendering (resvg), dimension rewriting and minification (oxvg), plus the
//! pixel comparison used as a safety net for minification.

use crate::Result;
use resvg::{tiny_skia, usvg};
use std::ffi::CString;
use std::io::Read;
use std::sync::{Arc, OnceLock};

/// oxvg jobs from preset-default that are switched off. Add a job's camelCase name here
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
    /// Largest per-channel difference after a 2×2 box filter. The filter absorbs sub-pixel
    /// anti-aliasing shifts from rounded coordinates; real changes (moved or missing shapes,
    /// colour shifts) survive it. Tuned on the fixtures: minified output scores ≤ 2, a 1-unit
    /// move, a 1-step colour nudge or a removed 4-px dot score ≥ 16.
    pub max: u8,
    /// Mean absolute difference over all channels at full resolution.
    pub mean: f32,
}

/// Renders both documents into the same box (`long_edge` px on the long side, aspect from `a`)
/// and compares them, with colour weighted by alpha so invisible changes don't count.
pub fn compare(a: &[u8], b: &[u8], long_edge: u32) -> Result<Diff> {
    let ta = parse(a, true)?;
    let tb = parse(b, true)?;
    let s = ta.size();
    let scale = long_edge as f32 / s.width().max(s.height());
    let w = ((s.width() * scale).round() as u32).max(2);
    let h = ((s.height() * scale).round() as u32).max(2);
    let pa = premultiplied(&render_tree(&ta, w, h)?);
    let pb = premultiplied(&render_tree(&tb, w, h)?);

    let total: u64 = pa.iter().zip(&pb).map(|(x, y)| u64::from(x.abs_diff(*y))).sum();
    let mean = total as f32 / pa.len() as f32;

    let at = |p: &[u8], x: u32, y: u32, c: u32| u32::from(p[((y * w + x) * 4 + c) as usize]);
    let mut max = 0u32;
    for y in 0..h / 2 {
        for x in 0..w / 2 {
            for c in 0..4 {
                let box_sum = |p: &[u8]| {
                    at(p, 2 * x, 2 * y, c) + at(p, 2 * x + 1, 2 * y, c) + at(p, 2 * x, 2 * y + 1, c)
                        + at(p, 2 * x + 1, 2 * y + 1, c)
                };
                max = max.max(box_sum(&pa).abs_diff(box_sum(&pb)) / 4);
            }
        }
    }
    Ok(Diff { max: max as u8, mean })
}

fn premultiplied(rgba: &[u8]) -> Vec<u8> {
    let mut out = rgba.to_vec();
    for px in out.chunks_exact_mut(4) {
        let a = u32::from(px[3]);
        for c in &mut px[..3] {
            *c = ((u32::from(*c) * a + 127) / 255) as u8;
        }
    }
    out
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

    const FIXTURES: [&str; 5] = ["illustrator.svg", "inkscape.svg", "icon-viewbox.svg", "styled-classes.svg", "text.svg"];

    fn passes_safety_net(diff: &Diff) -> bool {
        diff.max <= crate::KRIMP_SVG_MAX_DIFF && diff.mean <= crate::KRIMP_SVG_MEAN_DIFF
    }

    #[cfg(feature = "svg-min")]
    #[test]
    fn fixtures_shrink_and_render_the_same() {
        use crate::testutil::fixture;
        println!("| File | Original | Minified | Saved | Max diff | Mean diff |\n|---|---|---|---|---|---|");
        for name in FIXTURES {
            let src = fixture(&format!("svg/{name}"));
            let out = rewrite(&src, 0, 0, true).unwrap();
            let diff = compare(&src, &out, 512).unwrap();
            println!(
                "| {name} | {} B | {} B | {:.1}% | {} | {:.3} |",
                src.len(),
                out.len(),
                100.0 * (1.0 - out.len() as f64 / src.len() as f64),
                diff.max,
                diff.mean
            );
            assert!(out.len() < src.len(), "{name} didn't shrink");
            assert!(passes_safety_net(&diff), "{name} renders differently: max {} mean {}", diff.max, diff.mean);
        }
        println!("jobs: {}", enabled_jobs().to_str().unwrap());
    }

    #[test]
    fn resize_changes_dimensions_not_rendering() {
        use crate::testutil::fixture;
        for name in FIXTURES {
            let src = fixture(&format!("svg/{name}"));
            let (w, h) = size(&src).unwrap();
            let (nw, nh) = ((w * 2.0).round() as u32, (h * 2.0).round() as u32);
            let out = rewrite(&src, nw, nh, false).unwrap();
            assert_eq!(size(&out).unwrap(), (nw as f32, nh as f32), "{name}");
            let diff = compare(&src, &out, 512).unwrap();
            assert!(passes_safety_net(&diff), "{name}: max {} mean {}", diff.max, diff.mean);
        }
    }

    #[test]
    fn svgz_is_gunzipped() {
        use std::io::Write;
        let src = crate::testutil::fixture("svg/text.svg");
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        gz.write_all(&src).unwrap();
        let svgz = gz.finish().unwrap();
        assert_eq!(size(&svgz).unwrap(), size(&src).unwrap());
        assert_eq!(rewrite(&svgz, 0, 0, false).unwrap(), src);
        assert_eq!(render(&svgz, 40, 20).unwrap(), render(&src, 40, 20).unwrap());
    }

    #[test]
    fn upscaled_render_is_sharp() {
        // A hard vertical edge at x = 12 of 24 stays a 1-px transition at 4000 px.
        let px = render(ICON.as_bytes(), 4000, 4000).unwrap();
        let row = 2000 * 4000 * 4;
        let edge = (4000.0 * 2.0 / 24.0) as usize;
        let before = &px[row + (edge - 2) * 4..row + (edge - 2) * 4 + 4];
        let after = &px[row + (edge + 2) * 4..row + (edge + 2) * 4 + 4];
        assert_eq!(before[3], 0);
        assert_eq!(after, &[255, 0, 0, 255]);
    }

    #[test]
    fn renders_text() {
        let src = crate::testutil::fixture("svg/text.svg");
        let px = render(&src, 400, 200).unwrap();
        // Count white-ish text pixels on the gradient in the title band.
        let white = (70..95)
            .flat_map(|y| (60..340).map(move |x| (y * 400 + x) * 4))
            .filter(|&i| px[i] > 240 && px[i + 1] > 240 && px[i + 2] > 240)
            .count();
        assert!(white > 500, "text missing ({white} white pixels)");
    }

    #[test]
    fn safety_net_catches_real_changes() {
        let ill = String::from_utf8(crate::testutil::fixture("svg/illustrator.svg")).unwrap();
        let dot = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" fill="#fff"/><circle cx="100" cy="100" r="2" fill="#000"/></svg>"##;
        let changed = [
            (ill.clone(), ill.replace("#E94E1B;}", "#E94E2B;}")),
            (ill.clone(), ill.replace(r#"x="90.0000" y="95.0000""#, r#"x="91.0000" y="95.0000""#)),
            (ill.clone(), ill.replace(r#"r="88.0000""#, r#"r="88.2000""#)),
            (dot.to_string(), dot.replace(r##"<circle cx="100" cy="100" r="2" fill="#000"/>"##, "")),
        ];
        for (a, b) in changed {
            assert_ne!(a, b, "fixture edit didn't apply");
            let diff = compare(a.as_bytes(), b.as_bytes(), 512).unwrap();
            assert!(!passes_safety_net(&diff), "missed a change: max {} mean {}", diff.max, diff.mean);
        }
    }
}
