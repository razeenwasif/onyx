//! Imports OneNote's own section files (`.one`), as OneDrive's Download
//! gives them or OneNote for desktop saves them, read with the
//! `onenote_parser` crate. Nothing goes through Microsoft's servers, so
//! pages of any size come in whole (the web route, `onenote.rs`, times out
//! on very large ones), with no token and no rate limits.
//!
//! Positions follow OneNote's units: outlines, pictures and ink offsets are
//! in half-inches (48 page units each), ink points in himetric. Pages
//! become canvas pages, like the web import, and share its record
//! (`.scribe/onenote-import.json`) so a page is never brought in twice.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use onenote_parser::Parser;
use onenote_parser::contents::{Content, Image, Ink, OutlineElement, OutlineItem, RichText, Table as OneTable};
use onenote_parser::page::{Page, PageContent};
use serde::Serialize;
use typed_path::TypedPath;

use crate::model::{new_id, Background, Image as PageImage, PageDoc, Source, Stroke, Table, TextBox};
use crate::workspace::{path_str, read_json, write_json, Result, Workspace};

/// Page units per OneNote half-inch.
const HALF_INCH: f64 = 48.0;
/// Page units per himetric (1/100 mm).
const HIMETRIC: f64 = 96.0 / 2540.0;
/// OneNote's default body text, 11 pt.
const BODY_PX: f64 = 11.0 * 96.0 / 72.0;
const MANIFEST: &str = ".scribe/onenote-import.json";

/// A `.one` file found in a download, and where it belongs.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct FileSection {
    pub path: String,
    /// The OneNote notebook (folder holding a `.onetoc2`), or the folder.
    pub notebook: String,
    /// Section groups between the notebook and the file, outermost first.
    pub groups: Vec<String>,
    pub name: String,
}

impl FileSection {
    /// The Scribe notebook name: the section after its groups, as the web
    /// import names it.
    pub fn scribe_name(&self) -> String {
        if self.groups.is_empty() { self.name.clone() } else { format!("{} – {}", self.groups.join(" – "), self.name) }
    }
}

/// Every section file under `root` (a folder, or one `.one` file),
/// leaving out OneNote's recycle bin.
pub fn find_sections(root: &Path) -> Vec<FileSection> {
    let mut out = Vec::new();
    if root.is_file() {
        if is_section(root) {
            let name = stem(root);
            let notebook = root.parent().map(dir_name).unwrap_or_else(|| "OneNote".into());
            out.push(FileSection { path: path_str(root), notebook, groups: vec![], name });
        }
        return out;
    }
    walk(root, root, &mut out);
    out.sort_by(|a, b| (&a.notebook, &a.groups, &a.name).cmp(&(&b.notebook, &b.groups, &b.name)));
    out
}

fn walk(dir: &Path, top: &Path, out: &mut Vec<FileSection>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    entries.sort();
    for path in entries {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if name.starts_with('.') || name.starts_with("__MACOSX") || name.eq_ignore_ascii_case("OneNote_RecycleBin") {
            continue;
        }
        if path.is_dir() {
            walk(&path, top, out);
        } else if is_section(&path) {
            let parent = path.parent().unwrap_or(top);
            // The notebook is the nearest folder up that holds a .onetoc2;
            // the folders between it and the file are section groups.
            let mut notebook_dir = None;
            let mut cursor = Some(parent);
            while let Some(d) = cursor {
                if has_toc(d) {
                    notebook_dir = Some(d.to_path_buf());
                    break;
                }
                if d == top {
                    break;
                }
                cursor = d.parent();
            }
            let notebook_dir = notebook_dir.unwrap_or_else(|| parent.to_path_buf());
            let groups = parent
                .strip_prefix(&notebook_dir)
                .map(|rel| rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect())
                .unwrap_or_default();
            out.push(FileSection { path: path_str(&path), notebook: dir_name(&notebook_dir), groups, name: stem(&path) });
        }
    }
}

fn is_section(p: &Path) -> bool {
    p.extension().is_some_and(|e| e.eq_ignore_ascii_case("one"))
}

fn has_toc(dir: &Path) -> bool {
    std::fs::read_dir(dir)
        .map(|it| it.filter_map(|e| e.ok()).any(|e| e.path().extension().is_some_and(|x| x.eq_ignore_ascii_case("onetoc2"))))
        .unwrap_or(false)
}

fn stem(p: &Path) -> String {
    p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "Section".into())
}

fn dir_name(p: &Path) -> String {
    p.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "OneNote".into())
}

/// How one section's import went.
#[derive(Debug, Clone, Default, Serialize)]
pub struct SectionImport {
    /// Pages written.
    pub made: usize,
    /// Pages already here from an earlier import (by file or from the web).
    pub existing: usize,
    /// Things Scribe left out (attachments and the like).
    pub skipped: Vec<String>,
}

/// Imports every page of the section file `file` into the Scribe notebook
/// (section folder) `section`.
pub fn import_section(ws: &Workspace, section: &Path, file: &Path) -> Result<SectionImport> {
    let data = std::fs::read(file).map_err(|e| format!("Could not read {}: {e}", file.display()))?;
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let parsed = Parser::new()
        .parse_section_buffer(&data, TypedPath::derive(&name))
        .map_err(|e| format!("Couldn't read the OneNote section “{name}”: {e}"))?;

    let manifest_path = ws.root.join(MANIFEST);
    let mut manifest: HashMap<String, String> = read_json(&manifest_path).unwrap_or_default();
    // Pages already in this notebook before the run (the web import's), by
    // title. Pages made in this run don't count: OneNote allows two pages
    // with the same title.
    let titles: HashSet<String> = ws
        .list_pages(section)
        .into_iter()
        .map(|p| p.title.trim().to_lowercase())
        .filter(|t| t != "untitled page")
        .collect();

    let mut result = SectionImport::default();
    for series in parsed.page_series() {
        for page in series.pages() {
            let id = format!("file:{}", page.link_target_id());
            if manifest.get(&id).is_some_and(|rel| ws.root.join(rel).is_file()) {
                result.existing += 1;
                continue;
            }
            let title = page.title_text().map(|t| t.trim().to_string()).filter(|t| !t.is_empty()).unwrap_or_else(|| "Untitled page".into());
            if titles.contains(&title.to_lowercase()) {
                result.existing += 1;
                continue;
            }

            let mut built = PageBuilder::new(ws, section);
            built.page(page, &title, &id);
            let PageBuilder { mut doc, skipped, .. } = built;
            keep_on_page(&mut doc);
            let path = ws.create_page(section, &title)?;
            ws.write_page(&path, &mut doc)?;
            if let Ok(rel) = path.strip_prefix(&ws.root) {
                manifest.insert(id, rel.to_string_lossy().replace('\\', "/"));
                write_json(&manifest_path, &manifest)?;
            }
            result.made += 1;
            result.skipped.extend(skipped);
        }
    }
    Ok(result)
}

/// Builds one Scribe page from a OneNote page.
struct PageBuilder<'a> {
    ws: &'a Workspace,
    section: &'a Path,
    doc: PageDoc,
    skipped: Vec<String>,
}

/// A run of paragraphs in one outline, becoming one text box.
struct Flow {
    x: f64,
    y: f64,
    width: f64,
    text: String,
    font_px: f64,
    bold: bool,
    /// Where the next thing in this outline goes.
    cursor: f64,
}

impl<'a> PageBuilder<'a> {
    fn new(ws: &'a Workspace, section: &'a Path) -> Self {
        let mut doc = PageDoc {
            background: Background { kind: "blank".into(), ..Background::default() },
            ..PageDoc::default()
        };
        doc.extra.insert("layout".into(), "canvas".into());
        PageBuilder { ws, section, doc, skipped: vec![] }
    }

    fn page(&mut self, page: &Page, title: &str, id: &str) {
        self.doc.title = title.to_string();
        self.doc.source = Some(Source {
            app: "onenote".into(),
            id: Some(id.to_string()),
            imported_at: crate::model::now_stamp(),
            extra: Default::default(),
        });
        if let Some(created) = chrono::DateTime::from_timestamp(page.created_time().unix_timestamp(), 0) {
            self.doc.created = created.with_timezone(&chrono::Local).to_rfc3339_opts(chrono::SecondsFormat::Secs, false);
        }

        // The title sits where OneNote draws it, a little in from the corner.
        if let Some(t) = page.title() {
            let x = t.offset_horizontal() as f64 * HALF_INCH + HALF_INCH;
            let y = t.offset_vertical() as f64 * HALF_INCH + HALF_INCH / 2.0;
            let mut flow = Flow { x, y, width: 600.0, text: String::new(), font_px: 20.0 * 96.0 / 72.0, bold: false, cursor: y };
            for outline in t.contents() {
                for item in outline.items() {
                    self.item(item, &mut flow, 0);
                }
            }
            self.finish(&mut flow);
        }

        for content in page.contents() {
            match content {
                PageContent::Outline(o) => {
                    let x = o.offset_horizontal().unwrap_or(0.0) as f64 * HALF_INCH;
                    let y = o.offset_vertical().unwrap_or(0.0) as f64 * HALF_INCH;
                    let width = o.layout_max_width().map(|w| w as f64 * HALF_INCH).unwrap_or(600.0);
                    let mut flow = Flow { x, y, width, text: String::new(), font_px: BODY_PX, bold: false, cursor: y };
                    for item in o.items() {
                        self.item(item, &mut flow, 0);
                    }
                    self.finish(&mut flow);
                }
                PageContent::Image(img) => {
                    let x = img.offset_horizontal().unwrap_or(0.0) as f64 * HALF_INCH;
                    let y = img.offset_vertical().unwrap_or(0.0) as f64 * HALF_INCH;
                    self.image(img, x, y);
                }
                PageContent::Ink(ink) => {
                    self.ink(ink, (0.0, 0.0), None);
                }
                PageContent::EmbeddedFile(f) => self.skipped.push(format!("attachment {}", f.filename())),
                _ => {}
            }
        }
    }

    fn item(&mut self, item: &OutlineItem, flow: &mut Flow, level: usize) {
        match item {
            OutlineItem::Element(e) => self.element(e, flow, level),
            OutlineItem::Group(g) => {
                for child in g.outlines() {
                    self.item(child, flow, level + 1);
                }
            }
        }
    }

    fn element(&mut self, e: &OutlineElement, flow: &mut Flow, level: usize) {
        let bullet = e.list_contents().first().map(|list| {
            let marker: String = list.list_format().iter().filter(|c| !c.is_control()).collect();
            let marker = marker.trim();
            if marker.chars().count() == 1 && !marker.chars().all(char::is_alphanumeric) { format!("{marker} ") } else { "• ".to_string() }
        });
        let mut first = true;
        for content in e.contents() {
            match content {
                Content::RichText(rt) => {
                    let lead = format!("{}{}", "    ".repeat(level), if first { bullet.clone().unwrap_or_default() } else { String::new() });
                    self.text(rt, flow, &lead);
                }
                Content::Table(t) => {
                    self.finish(flow);
                    self.table(t, flow);
                }
                Content::Image(img) => {
                    self.finish(flow);
                    let y = flow.cursor;
                    let h = self.image(img, flow.x + level as f64 * 24.0, y);
                    flow.cursor = y + h + 8.0;
                    flow.y = flow.cursor;
                }
                Content::Ink(ink) => {
                    // Handwriting inside an outline sits in its flow.
                    self.finish(flow);
                    let top = flow.cursor;
                    let height = self.ink(ink, (flow.x + level as f64 * 24.0, top), Some(()));
                    flow.cursor = top + height + 8.0;
                    flow.y = flow.cursor;
                }
                Content::EmbeddedFile(f) => self.skipped.push(format!("attachment {}", f.filename())),
                _ => {}
            }
            first = false;
        }
        for child in e.children() {
            self.item(child, flow, level + 1);
        }
    }

    fn text(&mut self, rt: &RichText, flow: &mut Flow, lead: &str) {
        let text = visible_text(rt.text());
        let style = rt.paragraph_style();
        if flow.text.is_empty() {
            if let Some(size) = style.font_size().or_else(|| rt.text_run_formatting().iter().find_map(|f| f.font_size())) {
                flow.font_px = size as f64 / 2.0 * 96.0 / 72.0;
            }
            flow.bold = style.bold();
        }
        if !flow.text.is_empty() {
            flow.text.push('\n');
        }
        flow.text.push_str(lead);
        flow.text.push_str(text.trim_end());
        let lines = text.trim_end().lines().count().max(1) as f64;
        flow.cursor += lines * flow.font_px * 1.4;
    }

    /// Writes the flow's text so far as a text box.
    fn finish(&mut self, flow: &mut Flow) {
        let text = flow.text.trim_matches('\n').to_string();
        flow.text.clear();
        flow.y = flow.cursor;
        if text.trim().is_empty() {
            return;
        }
        let lines = text.lines().count() as f64;
        self.doc.text_boxes.push(TextBox {
            id: new_id(),
            x: round2(flow.x),
            y: round2(flow.cursor - lines * flow.font_px * 1.4),
            width: round2(flow.width.max(40.0)),
            text,
            font_family: "Calibri".into(),
            font_size: round2(flow.font_px),
            bold: flow.bold,
            ..TextBox::default()
        });
    }

    fn table(&mut self, t: &OneTable, flow: &mut Flow) {
        let rows: Vec<Vec<String>> = t
            .contents()
            .iter()
            .map(|row| {
                row.contents()
                    .iter()
                    .map(|cell| {
                        cell.contents()
                            .iter()
                            .flat_map(|e| e.contents().iter().filter_map(|c| c.rich_text().map(|rt| visible_text(rt.text()).trim().to_string())))
                            .filter(|s| !s.is_empty())
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .collect()
            })
            .collect();
        if rows.is_empty() {
            return;
        }
        let widths: Vec<f64> = t.col_widths().iter().map(|w| round2(*w as f64 * HALF_INCH)).collect();
        let y = flow.cursor;
        let lines: usize = rows.iter().map(|r| r.iter().map(|c| c.lines().count().max(1)).max().unwrap_or(1)).sum();
        self.doc.tables.push(Table {
            id: new_id(),
            x: round2(flow.x),
            y: round2(y),
            rows,
            column_widths: if widths.is_empty() { None } else { Some(widths) },
            has_header: false,
            ..Table::default()
        });
        flow.cursor = y + lines as f64 * BODY_PX * 1.6 + 12.0;
        flow.y = flow.cursor;
    }

    /// Places a picture; returns its height.
    fn image(&mut self, img: &Image, x: f64, y: f64) -> f64 {
        let Some(mut reader) = img.read() else {
            self.skipped.push("a picture with no data".into());
            return 0.0;
        };
        let mut bytes = Vec::new();
        if reader.read_to_end(&mut bytes).is_err() || bytes.is_empty() {
            self.skipped.push("a picture that couldn't be read".into());
            return 0.0;
        }
        let ext = img.extension().map(|e| e.trim_start_matches('.').to_lowercase()).filter(|e| !e.is_empty()).unwrap_or_else(|| sniff(&bytes).into());
        let width = img.layout_max_width().or(img.picture_width()).map(|w| w as f64 * HALF_INCH).unwrap_or(320.0);
        let height = img.layout_max_height().or(img.picture_height()).map(|h| h as f64 * HALF_INCH).unwrap_or(width * 0.75);
        let Ok((path, rel)) = self.ws.new_asset_path(self.section, &ext) else { return 0.0 };
        if std::fs::write(&path, &bytes).is_err() {
            return 0.0;
        }
        self.doc.images.push(PageImage { id: new_id(), x: round2(x), y: round2(y), width: round2(width), height: round2(height), file: rel, extra: Default::default() });
        height
    }

    /// Adds an ink object's strokes. Top-level ink is placed by its own
    /// offset (half-inches) plus its points (himetric); ink inside an
    /// outline (`inline`) is moved so its top-left sits at `origin`.
    /// Returns the ink's height.
    fn ink(&mut self, ink: &Ink, origin: (f64, f64), inline: Option<()>) -> f64 {
        let mut strokes = Vec::new();
        collect_strokes(ink, (0.0, 0.0), &mut strokes);
        if strokes.is_empty() {
            return 0.0;
        }
        let (mut min_x, mut min_y, mut max_y) = (f64::MAX, f64::MAX, f64::MIN);
        for s in &strokes {
            for p in s.points.chunks(3) {
                min_x = min_x.min(p[0]);
                min_y = min_y.min(p[1]);
                max_y = max_y.max(p[1]);
            }
        }
        let (dx, dy) = if inline.is_some() { (origin.0 - min_x, origin.1 - min_y) } else { origin };
        for s in &mut strokes {
            for p in s.points.chunks_mut(3) {
                p[0] = round2(p[0] + dx);
                p[1] = round2(p[1] + dy);
            }
        }
        self.doc.strokes.extend(strokes);
        max_y - min_y
    }
}

/// An ink object's strokes in page units, its offset (or its parent's)
/// applied.
fn collect_strokes(ink: &Ink, parent_offset: (f64, f64), out: &mut Vec<Stroke>) {
    let offset = (
        ink.offset_horizontal().map(|v| v as f64 * HALF_INCH).unwrap_or(parent_offset.0),
        ink.offset_vertical().map(|v| v as f64 * HALF_INCH).unwrap_or(parent_offset.1),
    );
    for child in ink.child_groups() {
        collect_strokes(child, offset, out);
    }
    for s in ink.ink_strokes() {
        let mut points = Vec::with_capacity(s.path().len() * 3);
        for p in s.path() {
            points.extend([p.x() as f64 * HIMETRIC + offset.0, p.y() as f64 * HIMETRIC + offset.1, 0.6]);
        }
        if points.len() < 3 {
            continue;
        }
        let color = s.color().map(|v| format!("#{:02X}{:02X}{:02X}", v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF)).unwrap_or_else(|| "#000000".into());
        out.push(Stroke {
            color,
            width: round2(s.width() as f64 * HIMETRIC),
            height: round2(s.height() as f64 * HIMETRIC),
            tip: if s.pen_tip().unwrap_or(0) == 0 { "ellipse".into() } else { "rectangle".into() },
            highlighter: s.transparency().unwrap_or(0) > 0,
            fit: true,
            pressure_sensitive: false,
            points,
            ..Stroke::default()
        });
    }
}

/// Text as shown: OneNote keeps a link's address in the text itself, as a
/// hidden `\u{fddf}HYPERLINK "url"` run before the words shown.
pub fn visible_text(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find('\u{fddf}') {
        out.push_str(&rest[..start]);
        let after = &rest[start + '\u{fddf}'.len_utf8()..];
        // A field code: a word, then a quoted argument.
        let skip = after
            .find('"')
            .and_then(|q| after[q + 1..].find('"').map(|e| q + 1 + e + 1))
            .filter(|end| after[..*end].split_whitespace().next().is_some_and(|w| w.chars().all(|c| c.is_ascii_uppercase())))
            .unwrap_or(0);
        rest = &after[skip..];
    }
    out.push_str(rest);
    out.replace(['\u{b}', '\r'], "\n")
}

/// OneNote lets ink start a little above or left of the page's corner;
/// moves everything so nothing is cut off.
fn keep_on_page(doc: &mut PageDoc) {
    let mut min_x = f64::MAX;
    let mut min_y = f64::MAX;
    for s in &doc.strokes {
        for p in s.points.chunks(3) {
            min_x = min_x.min(p[0] - s.width / 2.0);
            min_y = min_y.min(p[1] - s.width / 2.0);
        }
    }
    for t in &doc.text_boxes {
        min_x = min_x.min(t.x);
        min_y = min_y.min(t.y);
    }
    for i in &doc.images {
        min_x = min_x.min(i.x);
        min_y = min_y.min(i.y);
    }
    let dx = if min_x < 0.0 { round2(-min_x + 8.0) } else { 0.0 };
    let dy = if min_y < 0.0 { round2(-min_y + 8.0) } else { 0.0 };
    if dx == 0.0 && dy == 0.0 {
        return;
    }
    for s in &mut doc.strokes {
        for p in s.points.chunks_mut(3) {
            p[0] = round2(p[0] + dx);
            p[1] = round2(p[1] + dy);
        }
    }
    for t in &mut doc.text_boxes {
        t.x += dx;
        t.y += dy;
    }
    for i in &mut doc.images {
        i.x += dx;
        i.y += dy;
    }
    for t in &mut doc.tables {
        t.x += dx;
        t.y += dy;
    }
}

fn sniff(bytes: &[u8]) -> &'static str {
    match bytes {
        [0x89, b'P', b'N', b'G', ..] => "png",
        [0xFF, 0xD8, ..] => "jpg",
        [b'G', b'I', b'F', ..] => "gif",
        [b'B', b'M', ..] => "bmp",
        _ => "png",
    }
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

use std::io::Read as _;
