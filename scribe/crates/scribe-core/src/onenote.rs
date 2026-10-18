//! Turns a OneNote page, as Microsoft Graph returns it, into a Scribe page.
//!
//! `GET /me/onenote/pages/{id}/content?includeInkML=true` answers with a
//! multipart body: the page as HTML (typed text, pictures and tables, each
//! block absolutely positioned in CSS pixels) and its handwriting as InkML
//! (traces in himetric, 1/100 mm, with pressure). Both measure from the
//! page's top-left corner, so everything lands where it was in OneNote,
//! however far right or down the page reached.
//!
//! Pictures aren't fetched here: the page lists them as [`PictureRef`]s with
//! where they go, and the app downloads them into the section's assets.
//! The result is a "canvas" page (`layout: "canvas"`): no fixed paper size,
//! growing as you write past an edge, like OneNote.

use std::collections::HashMap;

use regex::Regex;
use serde::Serialize;

use crate::model::{new_id, Background, PageDoc, Source, Stroke, Table, TextBox};

/// Page units (device-independent pixels) per himetric.
const HIMETRIC: f64 = 96.0 / 2540.0;
/// OneNote's pressure channel tops out at 32767, but everyday writing sits
/// around a third of that; this maps a firm stroke to full width.
const FULL_PRESSURE: f64 = 24576.0;

/// A picture the page shows, for the app to download and place.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PictureRef {
    pub src: String,
    /// "png", "jpeg", … from the picture's type.
    pub ext: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConvertedPage {
    pub page: PageDoc,
    pub pictures: Vec<PictureRef>,
    /// Things OneNote had that Scribe skipped (attachments, audio, …).
    pub skipped: Vec<String>,
}

/// Converts a page. `content_type` is the response's Content-Type header,
/// which carries the multipart boundary; a plain HTML answer works too.
pub fn convert(body: &str, content_type: &str, page_id: &str) -> ConvertedPage {
    let (html, inkml) = split_parts(body, content_type);

    let mut page = PageDoc {
        title: tag_text(&html, "title").unwrap_or_else(|| "Untitled page".into()),
        background: Background { kind: "blank".into(), ..Background::default() },
        source: Some(Source {
            app: "onenote".into(),
            id: Some(page_id.to_string()),
            imported_at: crate::model::now_stamp(),
            extra: Default::default(),
        }),
        ..PageDoc::default()
    };
    if let Some(created) = meta(&html, "created") {
        page.created = created;
    }
    page.extra.insert("layout".into(), "canvas".into());

    if let Some(ink) = inkml {
        page.strokes = strokes_from_inkml(&ink);
    }
    let blocks = blocks_from_html(&html);
    page.text_boxes = blocks.text_boxes;
    page.tables = blocks.tables;

    ConvertedPage { page, pictures: blocks.pictures, skipped: blocks.skipped }
}

// ---------------------------------------------------------------- multipart

fn split_parts(body: &str, content_type: &str) -> (String, Option<String>) {
    let boundary = Regex::new(r#"boundary="?([^";]+)"?"#)
        .unwrap()
        .captures(content_type)
        .map(|c| c[1].to_string());
    let Some(boundary) = boundary else {
        return (body.to_string(), None);
    };
    let mut html = String::new();
    let mut ink = None;
    for part in body.split(&format!("--{boundary}")) {
        // Each part: headers, a blank line, the content.
        let Some((headers, content)) = part.split_once("\r\n\r\n").or_else(|| part.split_once("\n\n")) else {
            continue;
        };
        let headers = headers.to_ascii_lowercase();
        if headers.contains("inkml") {
            ink = Some(content.to_string());
        } else if headers.contains("text/html") {
            html = content.to_string();
        }
    }
    (html, ink)
}

// --------------------------------------------------------------------- ink

fn strokes_from_inkml(ink: &str) -> Vec<Stroke> {
    let attr = Regex::new(r#"name="([^"]+)"\s+value="([^"]*)""#).unwrap();
    let brush_re = Regex::new(r#"(?s)<inkml:brush\s+xml:id="([^"]+)"[^>]*>(.*?)</inkml:brush>"#).unwrap();
    let mut brushes: HashMap<String, HashMap<String, String>> = HashMap::new();
    for b in brush_re.captures_iter(ink) {
        let props = attr.captures_iter(&b[2]).map(|c| (c[1].to_string(), c[2].to_string())).collect();
        brushes.insert(b[1].to_string(), props);
    }

    let trace_re = Regex::new(r#"(?s)<inkml:trace\b([^>]*)>(.*?)</inkml:trace>"#).unwrap();
    let brush_ref = Regex::new(r##"brushRef="#?([^"]+)""##).unwrap();
    let mut strokes = Vec::new();
    for t in trace_re.captures_iter(ink) {
        let brush = brush_ref
            .captures(&t[1])
            .and_then(|c| brushes.get(&c[1]))
            .cloned()
            .unwrap_or_default();
        let mut points = Vec::new();
        for sample in t[2].split(',') {
            let v: Vec<f64> = sample.split_whitespace().filter_map(|n| n.parse().ok()).collect();
            if v.len() < 2 {
                continue;
            }
            let pressure = v.get(2).map_or(0.5, |f| (f / FULL_PRESSURE).clamp(0.05, 1.0));
            points.extend([round2(v[0] * HIMETRIC), round2(v[1] * HIMETRIC), round3(pressure)]);
        }
        if points.len() < 3 {
            continue;
        }
        let num = |k: &str, d: f64| brush.get(k).and_then(|v| v.parse::<f64>().ok()).unwrap_or(d);
        let width = round2(num("width", 53.0) * HIMETRIC);
        let height = round2(num("height", num("width", 53.0)) * HIMETRIC);
        let highlighter = brush.get("rasterOp").is_some_and(|r| r == "maskPen") || num("transparency", 0.0) > 0.0;
        strokes.push(Stroke {
            color: brush.get("color").cloned().unwrap_or_else(|| "#000000".into()),
            width,
            height,
            tip: brush.get("tip").cloned().unwrap_or_else(|| "ellipse".into()),
            highlighter,
            fit: brush.get("fitToCurve").is_some_and(|v| v == "true"),
            pressure_sensitive: brush.get("ignorePressure").map_or(true, |v| v != "true"),
            points,
            ..Stroke::default()
        });
    }
    strokes
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

// -------------------------------------------------------------------- html

struct Blocks {
    text_boxes: Vec<TextBox>,
    tables: Vec<Table>,
    pictures: Vec<PictureRef>,
    skipped: Vec<String>,
}

/// One absolutely positioned block of the page (OneNote's "outline"),
/// filled in as its contents stream past.
struct Container {
    depth: usize,
    x: f64,
    y: f64,
    width: f64,
    text: String,
    font_px: Option<f64>,
    bold: bool,
    /// How far down the block its flow has reached, for placing pictures
    /// and tables that sit between paragraphs.
    lines: usize,
    table: Option<Vec<Vec<String>>>,
    table_y: f64,
    lists: Vec<(bool, usize)>,
}

fn blocks_from_html(html: &str) -> Blocks {
    let mut out = Blocks { text_boxes: vec![], tables: vec![], pictures: vec![], skipped: vec![] };
    let body = match (html.find("<body"), html.rfind("</body>")) {
        (Some(a), Some(b)) if b > a => &html[a..b],
        _ => html,
    };
    let tag_re = Regex::new(r#"(?s)<!--.*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*?)(/?)>"#).unwrap();

    let mut depth = 0usize;
    // Pages made outside OneNote's editor (by other apps) flow without
    // positions; their content collects here, at the usual margin.
    let mut stack: Vec<Container> = vec![Container {
        depth: usize::MAX,
        x: 48.0,
        y: 96.0,
        width: 624.0,
        text: String::new(),
        font_px: None,
        bold: false,
        lines: 0,
        table: None,
        table_y: 0.0,
        lists: Vec::new(),
    }];
    let mut cell: Option<String> = None;
    let mut last = 0;

    for m in tag_re.captures_iter(body) {
        let whole = m.get(0).unwrap();
        // Text between tags.
        let text = decode_entities(&body[last..whole.start()]);
        last = whole.end();
        if let Some(c) = stack.last_mut() {
            let clean = collapse_space(&text);
            if !clean.trim().is_empty() {
                if let Some(cell) = cell.as_mut() {
                    cell.push_str(&clean);
                } else {
                    c.text.push_str(&clean);
                }
            }
        }
        if whole.as_str().starts_with("<!--") {
            continue;
        }
        let closing = &m[1] == "/";
        let name = m[2].to_ascii_lowercase();
        let attrs = &m[3];
        let void = &m[4] == "/" || matches!(name.as_str(), "img" | "br" | "meta" | "input" | "hr" | "object");

        if closing {
            match name.as_str() {
                "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "li" => {
                    if let Some(c) = stack.last_mut() {
                        newline(c);
                    }
                }
                "td" | "th" => {
                    if let (Some(c), Some(text)) = (stack.last_mut(), cell.take()) {
                        if let Some(rows) = c.table.as_mut() {
                            if let Some(row) = rows.last_mut() {
                                row.push(text.trim().to_string());
                            }
                        }
                    }
                }
                "table" => {
                    if let Some(c) = stack.last_mut() {
                        if let Some(rows) = c.table.take() {
                            let rows: Vec<Vec<String>> = rows.into_iter().filter(|r| !r.is_empty()).collect();
                            if !rows.is_empty() {
                                c.lines += rows.len() * 2;
                                out.tables.push(Table { x: c.x, y: c.table_y, rows, has_header: false, ..Table::default() });
                            }
                        }
                    }
                }
                "ul" | "ol" => {
                    if let Some(c) = stack.last_mut() {
                        c.lists.pop();
                    }
                }
                _ => {}
            }
            depth = depth.saturating_sub(1);
            if stack.last().is_some_and(|c| c.depth == depth) {
                finish(stack.pop().unwrap(), &mut out);
            }
            continue;
        }

        let style = attr_value(attrs, "style").unwrap_or_default();
        let absolute = style.contains("position:absolute");

        match name.as_str() {
            "img" => {
                let src = attr_value(attrs, "data-fullres-src").or_else(|| attr_value(attrs, "src")).unwrap_or_default();
                let kind = attr_value(attrs, "data-fullres-src-type")
                    .or_else(|| attr_value(attrs, "data-src-type"))
                    .unwrap_or_else(|| "image/png".into());
                let width = attr_value(attrs, "width").and_then(|w| w.parse().ok()).unwrap_or(200.0);
                let height = attr_value(attrs, "height").and_then(|h| h.parse().ok()).unwrap_or(150.0);
                let (x, y) = if absolute {
                    (css_px(&style, "left").unwrap_or(0.0), css_px(&style, "top").unwrap_or(0.0))
                } else if let Some(c) = stack.last_mut() {
                    let y = flow_y(c);
                    c.lines += (height / line_px(c)).ceil() as usize + 1;
                    newline(c);
                    (c.x, y)
                } else {
                    (0.0, 0.0)
                };
                if !src.is_empty() {
                    let ext = kind.rsplit('/').next().unwrap_or("png").replace("jpg", "jpeg");
                    out.pictures.push(PictureRef { src, ext, x, y, width, height });
                }
            }
            "br" => {
                if let Some(c) = stack.last_mut() {
                    newline(c);
                }
            }
            "object" => out.skipped.push(attr_value(attrs, "data-attachment").unwrap_or_else(|| "an attachment".into())),
            "table" => {
                if let Some(c) = stack.last_mut() {
                    c.table = Some(Vec::new());
                    c.table_y = flow_y(c);
                }
            }
            "tr" => {
                if let Some(rows) = stack.last_mut().and_then(|c| c.table.as_mut()) {
                    rows.push(Vec::new());
                }
            }
            "td" | "th" => cell = Some(String::new()),
            "ul" | "ol" => {
                if let Some(c) = stack.last_mut() {
                    c.lists.push((name == "ol", 0));
                }
            }
            "li" => {
                if let Some(c) = stack.last_mut() {
                    let indent = "    ".repeat(c.lists.len().saturating_sub(1));
                    let marker = match c.lists.last_mut() {
                        Some((true, n)) => {
                            *n += 1;
                            format!("{n}. ")
                        }
                        _ => "• ".into(),
                    };
                    c.text.push_str(&indent);
                    c.text.push_str(&marker);
                }
            }
            _ => {}
        }

        if !void {
            if absolute && name != "img" {
                stack.push(Container {
                    depth,
                    x: css_px(&style, "left").unwrap_or(0.0),
                    y: css_px(&style, "top").unwrap_or(0.0),
                    width: css_px(&style, "width").unwrap_or(624.0),
                    text: String::new(),
                    font_px: None,
                    bold: false,
                    lines: 0,
                    table: None,
                    table_y: 0.0,
                    lists: Vec::new(),
                });
            }
            if let Some(c) = stack.last_mut() {
                if c.font_px.is_none() {
                    c.font_px = css_size(&style);
                }
                if matches!(name.as_str(), "h1" | "h2" | "h3") {
                    c.bold = true;
                }
            }
            depth += 1;
        }
    }
    while let Some(c) = stack.pop() {
        finish(c, &mut out);
    }
    out
}

fn finish(c: Container, out: &mut Blocks) {
    let text = c
        .text
        .lines()
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
        .trim_matches('\n')
        .to_string();
    if text.trim().is_empty() {
        return;
    }
    out.text_boxes.push(TextBox {
        id: new_id(),
        x: c.x,
        y: c.y,
        width: c.width.max(40.0),
        text,
        font_family: "Calibri".into(),
        font_size: c.font_px.unwrap_or(11.0 * 96.0 / 72.0),
        bold: c.bold,
        ..TextBox::default()
    });
}

fn newline(c: &mut Container) {
    if !c.text.is_empty() && !c.text.ends_with('\n') {
        c.text.push('\n');
        c.lines += 1;
    }
}

fn line_px(c: &Container) -> f64 {
    c.font_px.unwrap_or(14.67) * 1.4
}

fn flow_y(c: &Container) -> f64 {
    c.y + c.lines as f64 * line_px(c)
}

fn attr_value(attrs: &str, name: &str) -> Option<String> {
    let re = Regex::new(&format!(r#"(?i)\b{}\s*=\s*"([^"]*)""#, regex::escape(name))).unwrap();
    re.captures(attrs).map(|c| decode_entities(&c[1]))
}

/// A CSS length in page units (px as is; pt converted).
fn css_px(style: &str, property: &str) -> Option<f64> {
    let re = Regex::new(&format!(r"(?i)(?:^|;)\s*{}\s*:\s*(-?[0-9.]+)\s*(px|pt)?", regex::escape(property))).unwrap();
    let c = re.captures(style)?;
    let v: f64 = c[1].parse().ok()?;
    Some(if c.get(2).is_some_and(|u| u.as_str().eq_ignore_ascii_case("pt")) { v * 96.0 / 72.0 } else { v })
}

fn css_size(style: &str) -> Option<f64> {
    css_px(style, "font-size")
}

fn tag_text(html: &str, tag: &str) -> Option<String> {
    let re = Regex::new(&format!(r"(?is)<{tag}[^>]*>(.*?)</{tag}>")).unwrap();
    re.captures(html).map(|c| decode_entities(c[1].trim())).filter(|t| !t.is_empty())
}

fn meta(html: &str, name: &str) -> Option<String> {
    let re = Regex::new(&format!(r#"(?i)<meta\s+name="{name}"\s+content="([^"]+)""#)).unwrap();
    re.captures(html).map(|c| c[1].to_string())
}

fn collapse_space(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    for ch in s.chars() {
        if ch.is_whitespace() && ch != '\u{a0}' {
            if !space {
                out.push(' ');
            }
            space = true;
        } else {
            out.push(if ch == '\u{a0}' { ' ' } else { ch });
            space = false;
        }
    }
    out
}

fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let re = Regex::new(r"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);").unwrap();
    re.replace_all(s, |c: &regex::Captures| {
        let e = &c[1];
        let ch = if let Some(hex) = e.strip_prefix("#x") {
            u32::from_str_radix(hex, 16).ok().and_then(char::from_u32)
        } else if let Some(dec) = e.strip_prefix('#') {
            dec.parse().ok().and_then(char::from_u32)
        } else {
            match e {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ => None,
            }
        };
        ch.map_or_else(|| c[0].to_string(), |ch| ch.to_string())
    })
    .into_owned()
}

// --------------------------------------------------------------- importing

/// What importing one page did.
#[derive(Debug, Clone, Serialize)]
pub struct ImportedPage {
    /// The new page file, or the one made on an earlier run.
    pub path: String,
    /// True when an earlier run had already imported it.
    pub existing: bool,
    pub pictures: Vec<PictureRef>,
    pub skipped: Vec<String>,
}

const MANIFEST: &str = ".scribe/onenote-import.json";

/// Converts a page and saves it into `section`, unless an earlier import
/// already brought it in (remembered in the workspace's
/// `.scribe/onenote-import.json`, by OneNote page id), so a run that stopped
/// part way picks up where it left off.
pub fn import_page(
    ws: &crate::workspace::Workspace,
    section: &std::path::Path,
    body: &str,
    content_type: &str,
    page_id: &str,
) -> crate::workspace::Result<ImportedPage> {
    let manifest_path = ws.root.join(MANIFEST);
    let mut manifest: HashMap<String, String> = crate::workspace::read_json(&manifest_path).unwrap_or_default();
    if let Some(rel) = manifest.get(page_id) {
        let path = ws.root.join(rel);
        if path.is_file() {
            return Ok(ImportedPage { path: crate::workspace::path_str(&path), existing: true, pictures: vec![], skipped: vec![] });
        }
    }

    let converted = convert(body, content_type, page_id);
    let file = ws.create_page(section, &converted.page.title)?;
    let mut doc = converted.page;
    ws.write_page(&file, &mut doc)?;

    if let Ok(rel) = file.strip_prefix(&ws.root) {
        manifest.insert(page_id.to_string(), rel.to_string_lossy().replace('\\', "/"));
        crate::workspace::write_json(&manifest_path, &manifest)?;
    }
    Ok(ImportedPage {
        path: crate::workspace::path_str(&file),
        existing: false,
        pictures: converted.pictures,
        skipped: converted.skipped,
    })
}

/// A folder of imported pages moved from `from` to `to` (both relative to
/// the workspace): the record follows it.
pub fn moved(ws: &crate::workspace::Workspace, from: &str, to: &str) -> crate::workspace::Result<()> {
    let path = ws.root.join(MANIFEST);
    let Some(mut manifest) = crate::workspace::read_json::<HashMap<String, String>>(&path) else { return Ok(()) };
    let prefix = format!("{from}/");
    let mut changed = false;
    for rel in manifest.values_mut() {
        if let Some(rest) = rel.strip_prefix(&prefix) {
            *rel = format!("{to}/{rest}");
            changed = true;
        }
    }
    if changed {
        crate::workspace::write_json(&path, &manifest)?;
    }
    Ok(())
}

/// Already-imported OneNote pages by id, for resuming.
pub fn imported_ids(ws: &crate::workspace::Workspace) -> Vec<String> {
    let manifest: HashMap<String, String> = crate::workspace::read_json(&ws.root.join(MANIFEST)).unwrap_or_default();
    manifest.into_iter().filter(|(_, rel)| ws.root.join(rel).is_file()).map(|(id, _)| id).collect()
}
