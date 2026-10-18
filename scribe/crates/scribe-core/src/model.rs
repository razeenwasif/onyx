//! On-disk shapes. This is the format contract described in docs/FORMAT.md.
//!
//! Every struct carries an `extra` map that captures fields this version does
//! not know about, and writes them back out unchanged. The format promises
//! that unknown fields survive a round trip, so a file touched by a newer
//! Scribe (or by another tool) is never quietly stripped.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub const PAGE_SCHEMA: &str = "scribe.page/1";
pub const NOTEBOOK_SCHEMA: &str = "scribe.notebook/1";
pub const SECTION_SCHEMA: &str = "scribe.section/1";

pub type Extra = Map<String, Value>;

pub fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

pub fn now_stamp() -> String {
    chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

fn default_page_schema() -> String {
    PAGE_SCHEMA.into()
}
fn default_notebook_schema() -> String {
    NOTEBOOK_SCHEMA.into()
}
fn default_section_schema() -> String {
    SECTION_SCHEMA.into()
}
fn default_title() -> String {
    "Untitled page".into()
}
fn default_ink() -> String {
    "#1A1A1A".into()
}
fn default_true() -> bool {
    true
}

// ------------------------------------------------------------------- page

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PageDoc {
    #[serde(default = "default_page_schema")]
    pub schema: String,
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default = "default_title")]
    pub title: String,
    #[serde(default = "now_stamp")]
    pub created: String,
    #[serde(default = "now_stamp")]
    pub modified: String,
    #[serde(default)]
    pub background: Background,
    #[serde(default)]
    pub strokes: Vec<Stroke>,
    #[serde(default, rename = "textBoxes")]
    pub text_boxes: Vec<TextBox>,
    #[serde(default)]
    pub images: Vec<Image>,
    #[serde(default, rename = "latexBlocks")]
    pub latex_blocks: Vec<Latex>,
    #[serde(default)]
    pub tables: Vec<Table>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(flatten)]
    pub extra: Extra,
}

impl Default for PageDoc {
    fn default() -> Self {
        Self {
            schema: default_page_schema(),
            id: new_id(),
            title: default_title(),
            created: now_stamp(),
            modified: now_stamp(),
            background: Background::default(),
            strokes: Vec::new(),
            text_boxes: Vec::new(),
            images: Vec::new(),
            latex_blocks: Vec::new(),
            tables: Vec::new(),
            source: None,
            extra: Extra::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Background {
    /// One of: blank, ruled, grid, dots.
    #[serde(default = "Background::default_kind")]
    pub kind: String,
    #[serde(default = "Background::default_spacing")]
    pub spacing: f64,
    /// Light-mode rule colour. Dark mode substitutes its own.
    #[serde(default = "Background::default_color")]
    pub color: String,
    #[serde(flatten)]
    pub extra: Extra,
}

impl Background {
    fn default_kind() -> String {
        "ruled".into()
    }
    fn default_spacing() -> f64 {
        32.0
    }
    fn default_color() -> String {
        "#E8EEF5".into()
    }
}

impl Default for Background {
    fn default() -> Self {
        Self {
            kind: Self::default_kind(),
            spacing: Self::default_spacing(),
            color: Self::default_color(),
            extra: Extra::new(),
        }
    }
}

/// One ink stroke. `points` is flat with stride 3: x, y, pressure.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Stroke {
    #[serde(default = "default_ink")]
    pub color: String,
    #[serde(default = "Stroke::default_width")]
    pub width: f64,
    #[serde(default = "Stroke::default_width")]
    pub height: f64,
    /// "ellipse" or "rectangle".
    #[serde(default = "Stroke::default_tip")]
    pub tip: String,
    #[serde(default)]
    pub highlighter: bool,
    #[serde(default = "default_true")]
    pub fit: bool,
    #[serde(default = "default_true", rename = "pressureSensitive")]
    pub pressure_sensitive: bool,
    #[serde(default)]
    pub points: Vec<f64>,
    #[serde(flatten)]
    pub extra: Extra,
}

impl Stroke {
    fn default_width() -> f64 {
        2.5
    }
    fn default_tip() -> String {
        "ellipse".into()
    }

    pub fn point_count(&self) -> usize {
        self.points.len() / 3
    }

    /// Nib size used for rendering: the larger of the two tip axes.
    pub fn nib(&self) -> f64 {
        self.width.max(self.height)
    }
}

impl Default for Stroke {
    fn default() -> Self {
        Self {
            color: default_ink(),
            width: Self::default_width(),
            height: Self::default_width(),
            tip: Self::default_tip(),
            highlighter: false,
            fit: true,
            pressure_sensitive: true,
            points: Vec::new(),
            extra: Extra::new(),
        }
    }
}

/// A formatted run inside a text box.
///
/// `start` and `length` count UTF-16 code units, which is what both AppKit
/// and .NET strings index by, so the offsets mean the same thing to either
/// app. Any attribute left out inherits from the text box.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct TextSpan {
    pub start: usize,
    pub length: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bold: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub italic: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub underline: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strikethrough: Option<bool>,
    #[serde(default, rename = "fontSize", skip_serializing_if = "Option::is_none")]
    pub font_size: Option<f64>,
    #[serde(default, rename = "fontFamily", skip_serializing_if = "Option::is_none")]
    pub font_family: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TextBox {
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default = "TextBox::default_width")]
    pub width: f64,
    /// None means size to content.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<f64>,
    #[serde(default)]
    pub text: String,
    #[serde(default = "TextBox::default_family", rename = "fontFamily")]
    pub font_family: String,
    #[serde(default = "TextBox::default_size", rename = "fontSize")]
    pub font_size: f64,
    #[serde(default = "default_ink")]
    pub color: String,
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
    #[serde(default)]
    pub underline: bool,
    #[serde(default)]
    pub strikethrough: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heading: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub spans: Vec<TextSpan>,
    /// Rich text written by the Windows app. Kept verbatim while the text is
    /// unchanged; dropped once the text is edited, since it would be stale.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xaml: Option<String>,
    #[serde(flatten)]
    pub extra: Extra,
}

impl TextBox {
    fn default_width() -> f64 {
        320.0
    }
    fn default_family() -> String {
        "Segoe UI".into()
    }
    fn default_size() -> f64 {
        15.0
    }
}

impl Default for TextBox {
    fn default() -> Self {
        Self {
            id: new_id(),
            x: 0.0,
            y: 0.0,
            width: Self::default_width(),
            height: None,
            text: String::new(),
            font_family: Self::default_family(),
            font_size: Self::default_size(),
            color: default_ink(),
            bold: false,
            italic: false,
            underline: false,
            strikethrough: false,
            heading: None,
            spans: Vec::new(),
            xaml: None,
            extra: Extra::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Image {
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default)]
    pub width: f64,
    #[serde(default)]
    pub height: f64,
    /// Relative to the section folder, forward slashes.
    #[serde(default)]
    pub file: String,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Latex {
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default)]
    pub latex: String,
    #[serde(default = "Latex::default_scale")]
    pub scale: f64,
    #[serde(default = "default_ink")]
    pub color: String,
    #[serde(flatten)]
    pub extra: Extra,
}

impl Latex {
    fn default_scale() -> f64 {
        20.0
    }
}

impl Default for Latex {
    fn default() -> Self {
        Self {
            id: new_id(),
            x: 0.0,
            y: 0.0,
            latex: String::new(),
            scale: Self::default_scale(),
            color: default_ink(),
            extra: Extra::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Table {
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default)]
    pub rows: Vec<Vec<String>>,
    #[serde(default, rename = "columnWidths", skip_serializing_if = "Option::is_none")]
    pub column_widths: Option<Vec<f64>>,
    #[serde(default = "default_true", rename = "hasHeader")]
    pub has_header: bool,
    #[serde(flatten)]
    pub extra: Extra,
}

impl Default for Table {
    fn default() -> Self {
        Self {
            id: new_id(),
            x: 0.0,
            y: 0.0,
            rows: Vec::new(),
            column_widths: None,
            has_header: true,
            extra: Extra::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Source {
    #[serde(default = "Source::default_app")]
    pub app: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default = "now_stamp", rename = "importedAt")]
    pub imported_at: String,
    #[serde(flatten)]
    pub extra: Extra,
}

impl Source {
    fn default_app() -> String {
        "onenote".into()
    }
}

// --------------------------------------------------------------- manifests

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NotebookDoc {
    #[serde(default = "default_notebook_schema")]
    pub schema: String,
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "NotebookDoc::default_color")]
    pub color: String,
    /// Section folder names in display order.
    #[serde(default, rename = "sectionOrder")]
    pub section_order: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(flatten)]
    pub extra: Extra,
}

impl NotebookDoc {
    fn default_color() -> String {
        "#7C5CE6".into()
    }

    pub fn named(name: &str) -> Self {
        Self {
            schema: default_notebook_schema(),
            id: new_id(),
            name: name.into(),
            color: Self::default_color(),
            section_order: Vec::new(),
            source: None,
            extra: Extra::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SectionDoc {
    #[serde(default = "default_section_schema")]
    pub schema: String,
    #[serde(default = "new_id")]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "SectionDoc::default_color")]
    pub color: String,
    /// Page file names in display order.
    #[serde(default, rename = "pageOrder")]
    pub page_order: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(flatten)]
    pub extra: Extra,
}

impl SectionDoc {
    fn default_color() -> String {
        "#4C9AFF".into()
    }

    pub fn named(name: &str) -> Self {
        Self {
            schema: default_section_schema(),
            id: new_id(),
            name: name.into(),
            color: Self::default_color(),
            page_order: Vec::new(),
            source: None,
            extra: Extra::new(),
        }
    }
}

// ----------------------------------------------------------- unknown fields

/// Carries unknown fields from the copy on disk into an edited page.
///
/// The UI layer only knows the documented fields, so a page it hands back has
/// empty `extra` maps. Objects are matched by `id`; strokes have no identity
/// and are matched by position only when their points are identical.
pub fn carry_extras(edited: &mut PageDoc, on_disk: &PageDoc) {
    fn fill(dst: &mut Extra, src: &Extra) {
        for (k, v) in src {
            dst.entry(k.clone()).or_insert_with(|| v.clone());
        }
    }

    fill(&mut edited.extra, &on_disk.extra);
    fill(&mut edited.background.extra, &on_disk.background.extra);

    if let (Some(e), Some(d)) = (edited.source.as_mut(), on_disk.source.as_ref()) {
        fill(&mut e.extra, &d.extra);
    }

    macro_rules! by_id {
        ($field:ident) => {
            for item in edited.$field.iter_mut() {
                if let Some(old) = on_disk.$field.iter().find(|o| o.id == item.id) {
                    fill(&mut item.extra, &old.extra);
                }
            }
        };
    }

    by_id!(text_boxes);
    by_id!(images);
    by_id!(latex_blocks);
    by_id!(tables);

    for (i, s) in edited.strokes.iter_mut().enumerate() {
        if let Some(old) = on_disk.strokes.get(i) {
            if old.points == s.points {
                fill(&mut s.extra, &old.extra);
            }
        }
    }
}

/// Thins a stroke's points (flat, stride 3: x, y, pressure) with
/// Ramer–Douglas–Peucker: drops points that lie within `tolerance` page
/// units of the line through their neighbours. Pressure counts as a third
/// dimension, scaled by `width`, so a change in thickness is kept. Imported
/// OneNote ink records a point every pixel or so; at a quarter of a unit
/// the stroke looks the same at any zoom and keeps a fraction of them.
pub fn simplify_points(points: &[f64], tolerance: f64, width: f64) -> Vec<f64> {
    let n = points.len() / 3;
    if n <= 2 {
        return points.to_vec();
    }
    let p = |i: usize| (points[i * 3], points[i * 3 + 1], points[i * 3 + 2] * width);
    let mut keep = vec![false; n];
    keep[0] = true;
    keep[n - 1] = true;
    let mut stack = vec![(0usize, n - 1)];
    let tol2 = tolerance * tolerance;
    while let Some((a, b)) = stack.pop() {
        if b <= a + 1 {
            continue;
        }
        let (ax, ay, ap) = p(a);
        let (bx, by, bp) = p(b);
        let (dx, dy, dp) = (bx - ax, by - ay, bp - ap);
        let len2 = dx * dx + dy * dy + dp * dp;
        let (mut far, mut far2) = (0usize, -1.0f64);
        for i in a + 1..b {
            let (x, y, q) = p(i);
            let d2 = if len2 == 0.0 {
                (x - ax).powi(2) + (y - ay).powi(2) + (q - ap).powi(2)
            } else {
                let t = (((x - ax) * dx + (y - ay) * dy + (q - ap) * dp) / len2).clamp(0.0, 1.0);
                (x - ax - t * dx).powi(2) + (y - ay - t * dy).powi(2) + (q - ap - t * dp).powi(2)
            };
            if d2 > far2 {
                far2 = d2;
                far = i;
            }
        }
        if far2 > tol2 {
            keep[far] = true;
            stack.push((a, far));
            stack.push((far, b));
        }
    }
    let mut out = Vec::with_capacity(points.len() / 2);
    for (i, k) in keep.iter().enumerate() {
        if *k {
            out.extend_from_slice(&points[i * 3..i * 3 + 3]);
        }
    }
    out
}

/// How far thinned ink may stray from what was recorded, in page units.
pub const THIN_TOLERANCE: f64 = 0.2;

/// Thins every stroke on an imported page (see `simplify_points`) and
/// marks the page so it's done once.
pub fn thin_ink(doc: &mut PageDoc) {
    for s in &mut doc.strokes {
        s.points = simplify_points(&s.points, THIN_TOLERANCE, s.width);
    }
    doc.extra.insert("inkThinned".into(), true.into());
}

impl PageDoc {
    /// The page without its ink, cheaply (the ink is most of a big page).
    pub fn clone_without_ink(&self) -> PageDoc {
        PageDoc {
            schema: self.schema.clone(),
            id: self.id.clone(),
            title: self.title.clone(),
            created: self.created.clone(),
            modified: self.modified.clone(),
            background: self.background.clone(),
            strokes: Vec::new(),
            text_boxes: self.text_boxes.clone(),
            images: self.images.clone(),
            latex_blocks: self.latex_blocks.clone(),
            tables: self.tables.clone(),
            source: self.source.clone(),
            extra: self.extra.clone(),
        }
    }
}

/// Ink for the apps: each stroke's points as base64 little-endian f32s in
/// `pointsPacked`, its `points` emptied. Decoding millions of JSON numbers
/// was most of the time (and memory) it took the apps to open a big page.
/// Files on disk keep plain `points`.
pub fn pack_points(doc: &mut PageDoc) {
    use base64::Engine as _;
    for s in &mut doc.strokes {
        let mut bytes = Vec::with_capacity(s.points.len() * 4);
        for v in &s.points {
            bytes.extend_from_slice(&(*v as f32).to_le_bytes());
        }
        s.extra.insert("pointsPacked".into(), base64::engine::general_purpose::STANDARD.encode(bytes).into());
        s.points.clear();
    }
}

/// Undoes `pack_points` for ink an app sends back, rounding as the format
/// does so unchanged strokes compare equal to what's on disk.
pub fn unpack_points(doc: &mut PageDoc) {
    use base64::Engine as _;
    for s in &mut doc.strokes {
        let Some(packed) = s.extra.remove("pointsPacked") else { continue };
        let Some(text) = packed.as_str() else { continue };
        let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(text) else { continue };
        s.points = bytes
            .chunks_exact(4)
            .enumerate()
            .map(|(i, b)| {
                let v = f32::from_le_bytes([b[0], b[1], b[2], b[3]]) as f64;
                if i % 3 == 2 { (v * 1000.0).round() / 1000.0 } else { (v * 100.0).round() / 100.0 }
            })
            .collect();
    }
}

/// Rounds stroke data the way the format specifies: positions to 2dp,
/// pressure to 3dp, clamping pressure into range.
pub fn normalise_strokes(doc: &mut PageDoc) {
    fn round(v: f64, digits: i32) -> f64 {
        let f = 10f64.powi(digits);
        (v * f).round() / f
    }

    doc.strokes.retain(|s| s.points.len() >= 3);

    for s in doc.strokes.iter_mut() {
        let n = s.points.len() / 3;
        s.points.truncate(n * 3);
        for i in 0..n {
            s.points[i * 3] = round(s.points[i * 3], 2);
            s.points[i * 3 + 1] = round(s.points[i * 3 + 1], 2);
            let p = s.points[i * 3 + 2];
            let p = if p.is_nan() || p < 0.0 { 0.5 } else { p.min(1.0) };
            s.points[i * 3 + 2] = round(p, 3);
        }
        s.width = round(s.width, 3);
        s.height = round(s.height, 3);
    }
}
