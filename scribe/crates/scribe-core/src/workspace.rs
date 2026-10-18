//! The on-disk workspace: plain folders and JSON files.
//!
//! ```text
//! <root>/
//!   My Notebook/
//!     notebook.json
//!     Quick Notes/
//!       section.json
//!       Meeting 2026-08-11.json
//!       assets/ab12cd.png
//! ```
//!
//! Folder and file names follow the user-visible titles so the tree reads
//! naturally in Finder and syncs cleanly through iCloud Drive, Dropbox or git.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{de::DeserializeOwned, Deserialize, Serialize};

use crate::model::{self, NotebookDoc, PageDoc, SectionDoc, TextBox};

pub type Result<T> = std::result::Result<T, String>;

fn io_err(context: &str, path: &Path, e: std::io::Error) -> String {
    format!("{context} {}: {e}", path.display())
}

pub struct Workspace {
    pub root: PathBuf,
}

/// Sidebar entry for a notebook and its sections.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct NotebookInfo {
    pub id: String,
    pub name: String,
    pub color: String,
    pub path: String,
    pub sections: Vec<SectionInfo>,
    /// The latest `modified` of its sections.
    pub modified: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct SectionInfo {
    pub id: String,
    pub name: String,
    pub color: String,
    pub path: String,
    #[serde(rename = "notebookPath")]
    pub notebook_path: String,
    #[serde(rename = "pageCount")]
    pub page_count: usize,
    /// When a page in it last changed (file time, Unix seconds; 0 if empty).
    pub modified: f64,
    /// The page shown as the notebook's cover in the library: the first
    /// page, or the latest-edited one when the section's `cover` is
    /// "latest".
    pub cover: Option<PageInfo>,
    /// "first" or "latest".
    #[serde(rename = "coverChoice")]
    pub cover_choice: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PageInfo {
    pub title: String,
    pub path: String,
    #[serde(rename = "sectionPath")]
    pub section_path: String,
    /// Seconds since the Unix epoch, or 0 when the stamp is unreadable.
    pub modified: f64,
    /// The start of the page's typed text, for previews.
    pub snippet: String,
    /// The page's own `id` (empty for a page without one), for keying
    /// caches such as thumbnails.
    #[serde(rename = "pageId")]
    pub page_id: String,
    /// Starred, to find again in the page grid.
    pub bookmarked: bool,
}

/// Just enough of a page to list it, without building its ink in memory.
#[derive(Deserialize)]
struct PageHeader {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    bookmarked: Option<bool>,
    #[serde(default)]
    modified: Option<String>,
    #[serde(default, rename = "textBoxes")]
    text_boxes: Vec<SearchText>,
}

/// Length of the preview shown under a page's title.
const SNIPPET_CHARS: usize = 140;

/// The page's typed text as one line, cut at a word boundary.
fn snippet_of<'a>(texts: impl Iterator<Item = &'a str>) -> String {
    let joined = texts.flat_map(str::split_whitespace).collect::<Vec<_>>().join(" ");
    if joined.chars().count() <= SNIPPET_CHARS {
        return joined;
    }
    let cut: String = joined.chars().take(SNIPPET_CHARS).collect();
    let cut = cut.rsplit_once(' ').map(|(head, _)| head).unwrap_or(&cut);
    format!("{}…", cut.trim_end_matches([',', '.', ';', ':']))
}

/// Just enough of a page to search it.
#[derive(Deserialize)]
struct PageSearchView {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    modified: Option<String>,
    #[serde(default, rename = "textBoxes")]
    text_boxes: Vec<SearchText>,
    #[serde(default)]
    tables: Vec<SearchTable>,
    #[serde(default)]
    bookmarked: Option<bool>,
}

#[derive(Deserialize)]
struct SearchText {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
struct SearchTable {
    #[serde(default)]
    rows: Vec<Vec<String>>,
}

pub fn parse_stamp(stamp: Option<&str>) -> f64 {
    stamp
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s.trim()).ok())
        .map(|d| d.timestamp_millis() as f64 / 1000.0)
        .unwrap_or(0.0)
}

impl Workspace {
    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root).map_err(|e| io_err("Could not create", &root, e))?;
        Ok(Self { root })
    }

    pub fn default_root() -> PathBuf {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| ".".into());
        home.join("Documents").join("Scribe Notebooks")
    }

    // ------------------------------------------------------------ notebooks

    pub fn list_notebook_dirs(&self) -> Vec<PathBuf> {
        let mut dirs: Vec<PathBuf> = subdirs(&self.root)
            .into_iter()
            .filter(|d| d.join("notebook.json").is_file())
            .collect();
        dirs.sort_by_key(|d| file_name(d).to_lowercase());
        dirs
    }

    pub fn read_notebook(&self, dir: &Path) -> NotebookDoc {
        read_json(&dir.join("notebook.json")).unwrap_or_else(|| NotebookDoc::named(&file_name(dir)))
    }

    pub fn write_notebook(&self, dir: &Path, doc: &NotebookDoc) -> Result<()> {
        write_json(&dir.join("notebook.json"), doc)
    }

    pub fn create_notebook(&self, name: &str) -> Result<PathBuf> {
        let dir = unique_dir(&self.root, name);
        fs::create_dir_all(&dir).map_err(|e| io_err("Could not create", &dir, e))?;
        self.write_notebook(&dir, &NotebookDoc::named(name))?;
        Ok(dir)
    }

    pub fn rename_notebook(&self, dir: &Path, name: &str) -> Result<()> {
        let mut doc = self.read_notebook(dir);
        doc.name = name.to_string();
        self.write_notebook(dir, &doc)
    }

    // ------------------------------------------------------------- sections

    pub fn list_section_dirs(&self, notebook_dir: &Path) -> Vec<PathBuf> {
        let found: Vec<PathBuf> = subdirs(notebook_dir)
            .into_iter()
            .filter(|d| d.join("section.json").is_file())
            .collect();
        order_by_manifest(found, &self.read_notebook(notebook_dir).section_order)
    }

    pub fn read_section(&self, dir: &Path) -> SectionDoc {
        read_json(&dir.join("section.json")).unwrap_or_else(|| SectionDoc::named(&file_name(dir)))
    }

    pub fn write_section(&self, dir: &Path, doc: &SectionDoc) -> Result<()> {
        write_json(&dir.join("section.json"), doc)
    }

    pub fn create_section(&self, notebook_dir: &Path, name: &str) -> Result<PathBuf> {
        let dir = unique_dir(notebook_dir, name);
        fs::create_dir_all(&dir).map_err(|e| io_err("Could not create", &dir, e))?;
        self.write_section(&dir, &SectionDoc::named(name))?;

        let mut nb = self.read_notebook(notebook_dir);
        nb.section_order.push(file_name(&dir));
        self.write_notebook(notebook_dir, &nb)?;
        Ok(dir)
    }

    pub fn rename_section(&self, dir: &Path, name: &str) -> Result<()> {
        let mut doc = self.read_section(dir);
        doc.name = name.to_string();
        self.write_section(dir, &doc)
    }

    /// Drops a section folder that has already been removed (e.g. moved to
    /// the Trash by the app) from its notebook's manifest.
    pub fn forget_section(&self, notebook_dir: &Path, section_dir: &Path) -> Result<()> {
        let mut nb = self.read_notebook(notebook_dir);
        let name = file_name(section_dir).to_lowercase();
        nb.section_order.retain(|n| n.to_lowercase() != name);
        self.write_notebook(notebook_dir, &nb)
    }

    // ---------------------------------------------------------------- pages

    pub fn list_page_files(&self, section_dir: &Path) -> Vec<PathBuf> {
        let found: Vec<PathBuf> = fs::read_dir(section_dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.is_file()
                    && p.extension().is_some_and(|x| x.eq_ignore_ascii_case("json"))
                    && !file_name(p).eq_ignore_ascii_case("section.json")
            })
            .collect();

        let order: Vec<String> = self
            .read_section(section_dir)
            .page_order
            .into_iter()
            .map(|n| if n.to_lowercase().ends_with(".json") { n } else { format!("{n}.json") })
            .collect();

        order_by_manifest(found, &order)
    }

    pub fn list_pages(&self, section_dir: &Path) -> Vec<PageInfo> {
        self.list_page_files(section_dir).into_iter().map(|f| page_info(&f, section_dir)).collect()
    }

    /// The pages most recently changed anywhere in the workspace, newest
    /// first, for the library's Recent row. Ranked by file time, so only the
    /// pages returned are read.
    pub fn recent_pages(&self, limit: usize) -> Vec<PageInfo> {
        let mut all: Vec<(f64, PathBuf, PathBuf)> = Vec::new();
        for nb in self.list_notebook_dirs() {
            for sec in self.list_section_dirs(&nb) {
                for f in self.list_page_files(&sec) {
                    all.push((file_time(&f), f, sec.clone()));
                }
            }
        }
        all.sort_by(|a, b| b.0.total_cmp(&a.0));
        all.into_iter().take(limit).map(|(_, f, sec)| page_info(&f, &sec)).collect()
    }

    pub fn set_notebook_color(&self, dir: &Path, color: &str) -> Result<()> {
        let mut doc = self.read_notebook(dir);
        doc.color = color.to_string();
        self.write_notebook(dir, &doc)
    }

    pub fn set_section_color(&self, dir: &Path, color: &str) -> Result<()> {
        let mut doc = self.read_section(dir);
        doc.color = color.to_string();
        self.write_section(dir, &doc)
    }

    /// Which page a notebook (section) shows as its cover: "first" or "latest".
    pub fn set_section_cover(&self, dir: &Path, choice: &str) -> Result<()> {
        let mut doc = self.read_section(dir);
        if choice == "latest" {
            doc.extra.insert("cover".into(), serde_json::Value::String("latest".into()));
        } else {
            doc.extra.remove("cover");
        }
        self.write_section(dir, &doc)
    }
}

/// What laying out a notebook's pages one under another needs to know about
/// each page, without the app loading them all.
#[derive(Debug, Clone, Serialize)]
pub struct PageLayout {
    pub path: String,
    #[serde(rename = "pageId")]
    pub page_id: String,
    pub background: crate::model::Background,
    /// How far right and down the page's content reaches, in page units.
    #[serde(rename = "contentWidth")]
    pub content_width: f64,
    #[serde(rename = "contentHeight")]
    pub content_height: f64,
    /// Nothing on it: no ink, text, pictures, tables, formulas or PDF.
    pub blank: bool,
}

impl Workspace {
    /// Every page of a section, in order, with its extent (see PageLayout).
    pub fn page_layouts(&self, section_dir: &Path) -> Vec<PageLayout> {
        self.list_page_files(section_dir)
            .into_iter()
            .map(|f| {
                let doc = self.read_page_lenient(&f);
                let (w, h) = content_extent(&doc);
                let blank = doc.strokes.is_empty()
                    && doc.text_boxes.is_empty()
                    && doc.images.is_empty()
                    && doc.tables.is_empty()
                    && doc.latex_blocks.is_empty()
                    && !doc.background.kind.eq_ignore_ascii_case("pdf");
                PageLayout {
                    path: path_str(&f),
                    page_id: doc.id.clone(),
                    background: doc.background.clone(),
                    content_width: w,
                    content_height: h,
                    blank,
                }
            })
            .collect()
    }
}

/// The furthest right and down anything on the page reaches.
fn content_extent(doc: &PageDoc) -> (f64, f64) {
    let (mut w, mut h) = (0.0_f64, 0.0_f64);
    let mut reach = |x: f64, y: f64| {
        w = w.max(x);
        h = h.max(y);
    };
    for s in &doc.strokes {
        let r = s.width.max(s.height) / 2.0;
        for p in s.points.chunks_exact(3) {
            reach(p[0] + r, p[1] + r);
        }
    }
    for t in &doc.text_boxes {
        reach(t.x + t.width, t.y + t.height.unwrap_or(40.0));
    }
    for i in &doc.images {
        reach(i.x + i.width, i.y + i.height);
    }
    for t in &doc.tables {
        let columns = t.rows.iter().map(Vec::len).max().unwrap_or(0);
        let width: f64 = (0..columns)
            .map(|c| t.column_widths.as_ref().and_then(|w| w.get(c)).copied().unwrap_or(140.0))
            .sum();
        reach(t.x + width, t.y + t.rows.len() as f64 * 30.0);
    }
    for l in &doc.latex_blocks {
        reach(l.x + l.latex.len() as f64 * l.scale * 0.5, l.y + l.scale * 1.5);
    }
    (w, h)
}

/// One page's listing entry, read from just its header.
fn page_info(f: &Path, section_dir: &Path) -> PageInfo {
    let header: Option<PageHeader> = read_json(f);
    let (title, modified, snippet, id, bookmarked) = match header {
        Some(h) => (
            h.title,
            h.modified,
            snippet_of(h.text_boxes.iter().map(|t| t.text.as_str())),
            h.id.unwrap_or_default(),
            h.bookmarked.unwrap_or(false),
        ),
        None => (None, None, String::new(), String::new(), false),
    };
    PageInfo {
        title: title.unwrap_or_else(|| file_stem(f)),
        modified: parse_stamp(modified.as_deref()),
        path: path_str(f),
        section_path: path_str(section_dir),
        snippet,
        page_id: id,
        bookmarked,
    }
}

/// A file's modification time in Unix seconds, or 0.
fn file_time(f: &Path) -> f64 {
    fs::metadata(f)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64())
}

impl Workspace {

    pub fn read_page(&self, file: &Path) -> Result<PageDoc> {
        let text = fs::read_to_string(file).map_err(|e| io_err("Could not read", file, e))?;
        let doc: PageDoc = serde_json::from_str(&text)
            .map_err(|e| format!("{} is not a readable page: {e}", file.display()))?;
        check_schema(&doc.schema, "scribe.page")?;
        Ok(doc)
    }

    /// Reads a page, falling back to an empty one titled after the file when
    /// it is missing or damaged. Used where failing loudly would only get in
    /// the way, such as opening the app on a half-synced folder.
    pub fn read_page_lenient(&self, file: &Path) -> PageDoc {
        self.read_page(file).unwrap_or_else(|_| PageDoc { title: file_stem(file), ..PageDoc::default() })
    }

    /// Writes a page. Stamps `modified`, rounds ink, and carries over any
    /// fields the copy on disk has that this version does not understand.
    pub fn write_page(&self, file: &Path, doc: &mut PageDoc) -> Result<()> {
        if let Some(on_disk) = read_json::<PageDoc>(file) {
            model::carry_extras(doc, &on_disk);
        }
        model::normalise_strokes(doc);
        doc.text_boxes.retain(|t| !t.text.trim().is_empty());
        doc.modified = model::now_stamp();
        write_json(file, doc)
    }

    pub fn create_page(&self, section_dir: &Path, title: &str) -> Result<PathBuf> {
        let file = unique_file(section_dir, title, ".json");
        let doc = PageDoc { title: title.to_string(), ..PageDoc::default() };
        write_json(&file, &doc)?;

        let mut sec = self.read_section(section_dir);
        sec.page_order.push(file_name(&file));
        self.write_section(section_dir, &sec)?;
        Ok(file)
    }

    /// Renames a page file to follow its title and keeps the manifest in step.
    /// Returns the (possibly unchanged) path.
    pub fn rename_page_file(&self, section_dir: &Path, file: &Path, new_title: &str) -> Result<PathBuf> {
        let desired = sanitize_name(new_title);
        if file_stem(file) == desired {
            return Ok(file.to_path_buf());
        }

        // Only a change of case: on a case-insensitive volume the unique-name
        // probe would see the file itself and append " (2)".
        let target = if file_stem(file).to_lowercase() == desired.to_lowercase() {
            section_dir.join(format!("{desired}.json"))
        } else {
            unique_file(section_dir, new_title, ".json")
        };

        fs::rename(file, &target).map_err(|e| io_err("Could not rename", file, e))?;

        let mut sec = self.read_section(section_dir);
        let old = file_name(file).to_lowercase();
        let new = file_name(&target);
        match sec.page_order.iter().position(|n| n.to_lowercase() == old) {
            Some(i) => sec.page_order[i] = new,
            None => sec.page_order.push(new),
        }
        self.write_section(section_dir, &sec)?;
        Ok(target)
    }

    /// Removes a page from its section's manifest. The file itself is expected
    /// to have been moved to the Trash already, or to be deleted here.
    pub fn forget_page(&self, section_dir: &Path, file: &Path) -> Result<()> {
        let mut sec = self.read_section(section_dir);
        let name = file_name(file).to_lowercase();
        sec.page_order.retain(|n| n.to_lowercase() != name);
        self.write_section(section_dir, &sec)
    }

    pub fn delete_page(&self, section_dir: &Path, file: &Path) -> Result<()> {
        if file.exists() {
            fs::remove_file(file).map_err(|e| io_err("Could not delete", file, e))?;
        }
        self.forget_page(section_dir, file)
    }

    /// Stars or unstars a page. Only that one field changes: the page's
    /// `modified` stamp stays, since starring isn't an edit.
    pub fn set_bookmarked(&self, file: &Path, on: bool) -> Result<()> {
        let text = fs::read_to_string(file).map_err(|e| io_err("Could not read", file, e))?;
        let mut page: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let obj = page.as_object_mut().ok_or("Not a Scribe page")?;
        if on {
            obj.insert("bookmarked".into(), serde_json::Value::Bool(true));
        } else {
            obj.remove("bookmarked");
        }
        write_json(file, &page)
    }

    /// Replaces the section's page order, e.g. after a drag in the page list.
    pub fn set_page_order(&self, section_dir: &Path, files: &[PathBuf]) -> Result<()> {
        let mut sec = self.read_section(section_dir);
        sec.page_order = files.iter().map(|f| file_name(f)).collect();
        self.write_section(section_dir, &sec)
    }

    /// Moves a page into another section, appending it to that section's order.
    pub fn move_page(&self, file: &Path, to_section: &Path) -> Result<PathBuf> {
        let from_section = file.parent().ok_or("Page has no section")?.to_path_buf();
        if from_section == to_section {
            return Ok(file.to_path_buf());
        }

        let doc = self.read_page_lenient(file);
        let target = unique_file(to_section, &doc.title, ".json");

        // Images, and a PDF background, live beside the page in assets/, so
        // they travel with it.
        let background_asset = doc.background.extra.get("asset").and_then(|v| v.as_str()).map(str::to_string);
        for file in doc.images.iter().map(|i| i.file.clone()).chain(background_asset) {
            let src = from_section.join(&file);
            let dst = to_section.join(&file);
            if src.is_file() && !dst.exists() {
                if let Some(parent) = dst.parent() {
                    fs::create_dir_all(parent).map_err(|e| io_err("Could not create", parent, e))?;
                }
                fs::copy(&src, &dst).map_err(|e| io_err("Could not copy", &src, e))?;
            }
        }

        fs::rename(file, &target).map_err(|e| io_err("Could not move", file, e))?;
        self.forget_page(&from_section, file)?;

        let mut sec = self.read_section(to_section);
        sec.page_order.push(file_name(&target));
        self.write_section(to_section, &sec)?;
        Ok(target)
    }

    // --------------------------------------------------------------- assets

    /// Reserves a fresh asset name in the section. Returns the absolute path
    /// to write to and the section-relative path to store in the page.
    pub fn new_asset_path(&self, section_dir: &Path, extension: &str) -> Result<(PathBuf, String)> {
        let assets = section_dir.join("assets");
        fs::create_dir_all(&assets).map_err(|e| io_err("Could not create", &assets, e))?;

        let ext = extension.trim_start_matches('.').to_lowercase();
        let ext = if ext.is_empty() { "png".to_string() } else { ext };
        let name = format!("{}.{ext}", &model::new_id()[..12]);
        Ok((assets.join(&name), format!("assets/{name}")))
    }

    // ----------------------------------------------------------------- tree

    pub fn tree(&self) -> Vec<NotebookInfo> {
        self.list_notebook_dirs()
            .into_iter()
            .map(|nb_dir| {
                let nb = self.read_notebook(&nb_dir);
                let sections = self
                    .list_section_dirs(&nb_dir)
                    .into_iter()
                    .map(|s| {
                        let sec = self.read_section(&s);
                        let files = self.list_page_files(&s);
                        let times: Vec<f64> = files.iter().map(|f| file_time(f)).collect();
                        let modified = times.iter().copied().fold(0.0, f64::max);
                        let latest = sec.extra.get("cover").and_then(|v| v.as_str()) == Some("latest");
                        let cover_file = if latest {
                            files.iter().zip(&times).max_by(|a, b| a.1.total_cmp(b.1)).map(|(f, _)| f)
                        } else {
                            files.first()
                        };
                        SectionInfo {
                            id: sec.id,
                            name: sec.name,
                            color: sec.color,
                            page_count: files.len(),
                            modified,
                            cover: cover_file.map(|f| page_info(f, &s)),
                            cover_choice: if latest { "latest" } else { "first" }.into(),
                            path: path_str(&s),
                            notebook_path: path_str(&nb_dir),
                        }
                    })
                    .collect::<Vec<_>>();
                let modified = sections.iter().map(|s| s.modified).fold(0.0, f64::max);
                NotebookInfo { id: nb.id, name: nb.name, color: nb.color, path: path_str(&nb_dir), sections, modified }
            })
            .collect()
    }

    /// Case-insensitive search over page titles, typed text, table cells
    /// and handwriting (the text read out of it, see ink.rs), across every
    /// notebook. Ink itself is never parsed into memory.
    pub fn search(&self, query: &str) -> Vec<PageInfo> {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return Vec::new();
        }
        let ink = self.ink_index();

        let mut results = Vec::new();
        for nb in self.list_notebook_dirs() {
            for sec in self.list_section_dirs(&nb) {
                for file in self.list_page_files(&sec) {
                    let Some(view) = read_json::<PageSearchView>(&file) else { continue };
                    let title = view.title.clone().unwrap_or_else(|| file_stem(&file));

                    let typed = title.to_lowercase().contains(&q)
                        || view.text_boxes.iter().any(|t| t.text.to_lowercase().contains(&q))
                        || view
                            .tables
                            .iter()
                            .flat_map(|t| t.rows.iter().flatten())
                            .any(|c| c.to_lowercase().contains(&q));
                    let written = view
                        .id
                        .as_ref()
                        .and_then(|id| ink.pages.get(id))
                        .filter(|e| e.text.to_lowercase().contains(&q));

                    if typed || written.is_some() {
                        // A match only in handwriting previews the handwriting.
                        let snippet = match written {
                            Some(e) if !typed => snippet_of(std::iter::once(e.text.as_str())),
                            _ => snippet_of(view.text_boxes.iter().map(|t| t.text.as_str())),
                        };
                        results.push(PageInfo {
                            title,
                            path: path_str(&file),
                            section_path: path_str(&sec),
                            modified: parse_stamp(view.modified.as_deref()),
                            snippet,
                            page_id: view.id.clone().unwrap_or_default(),
                            bookmarked: view.bookmarked.unwrap_or(false),
                        });
                    }
                }
            }
        }
        results
    }

    /// Creates "My Notebook / Quick Notes / Welcome to Scribe" when the
    /// workspace has no notebooks. Returns the welcome page's path if made.
    pub fn ensure_starter(&self) -> Result<Option<PathBuf>> {
        if !self.list_notebook_dirs().is_empty() {
            return Ok(None);
        }

        let nb = self.create_notebook("My Notebook")?;
        let sec = self.create_section(&nb, "Quick Notes")?;
        let page = self.create_page(&sec, "Welcome to Scribe")?;

        let mut doc = self.read_page_lenient(&page);
        doc.text_boxes.push(TextBox {
            x: 90.0,
            y: 96.0,
            width: 620.0,
            font_size: 15.0,
            text: WELCOME.to_string(),
            ..TextBox::default()
        });
        self.write_page(&page, &mut doc)?;
        Ok(Some(page))
    }
}

const WELCOME: &str = "Welcome to Scribe.\n\n\
• Pick the Pen and write. With a drawing tablet, pressure shapes every stroke; \
the tablet pen's eraser end erases.\n\
• Two fingers on the trackpad scroll the page, a pinch zooms.\n\
• Press T, then click anywhere, to type. Paste images, tables and text with ⌘V.\n\
• ⌘Z undoes, ⌘N makes a new page.\n\n\
Everything lives in plain folders and JSON files on your disk. Right-click a \
notebook and choose Show in Finder any time, and it is all readable.";

// ------------------------------------------------------------------- infra

fn check_schema(schema: &str, expected: &str) -> Result<()> {
    let (name, version) = schema.split_once('/').unwrap_or((schema, "1"));
    if name != expected {
        return Err(format!("Unexpected schema \"{schema}\""));
    }
    if version.split('.').next() != Some("1") {
        return Err(format!("This page uses {schema}, which needs a newer Scribe"));
    }
    Ok(())
}

pub fn read_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    // A corrupt or partially synced file must not take the app down; callers
    // fall back to a sensible default.
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Writes via a temporary file and an atomic rename, so a crash or a sync
/// client reading mid-write never sees half a file.
pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| io_err("Could not create", dir, e))?;
    }

    let mut text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    text.push('\n');

    let tmp = path.with_file_name(format!("{}.tmp", file_name(path)));
    {
        let mut f = fs::File::create(&tmp).map_err(|e| io_err("Could not write", &tmp, e))?;
        f.write_all(text.as_bytes()).map_err(|e| io_err("Could not write", &tmp, e))?;
        f.sync_all().map_err(|e| io_err("Could not write", &tmp, e))?;
    }
    fs::rename(&tmp, path).map_err(|e| io_err("Could not replace", path, e))
}

/// Orders paths by a manifest of file names, then appends anything the
/// manifest misses, alphabetically. Files dropped in by hand stay visible.
fn order_by_manifest(paths: Vec<PathBuf>, order: &[String]) -> Vec<PathBuf> {
    let mut by_name: HashMap<String, PathBuf> =
        paths.into_iter().map(|p| (file_name(&p).to_lowercase(), p)).collect();

    let mut result = Vec::with_capacity(by_name.len());
    for name in order {
        if let Some(p) = by_name.remove(&name.to_lowercase()) {
            result.push(p);
        }
    }

    let mut rest: Vec<PathBuf> = by_name.into_values().collect();
    rest.sort_by_key(|p| path_str(p).to_lowercase());
    result.extend(rest);
    result
}

fn subdirs(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect()
}

pub fn file_name(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

fn file_stem(p: &Path) -> String {
    p.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

pub fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

const RESERVED: &[&str] = &[
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// Makes a title safe as a file or folder name.
///
/// Applies Windows' rules as well as macOS's, because a notebook folder synced
/// to a Windows machine must still open there.
pub fn sanitize_name(name: &str) -> String {
    let replaced: String = name
        .chars()
        .map(|c| if c.is_control() || "<>:\"/\\|?*".contains(c) { ' ' } else { c })
        .collect();

    let mut cleaned = replaced.split_whitespace().collect::<Vec<_>>().join(" ");
    while cleaned.ends_with('.') {
        cleaned.pop();
    }
    let mut cleaned = cleaned.trim().to_string();

    // Hidden files on macOS; also confusing in every file manager.
    while cleaned.starts_with('.') {
        cleaned.remove(0);
    }

    if cleaned.is_empty() {
        cleaned = "Untitled".into();
    }
    if cleaned.chars().count() > 80 {
        cleaned = cleaned.chars().take(80).collect::<String>().trim().to_string();
    }
    if RESERVED.iter().any(|r| r.eq_ignore_ascii_case(&cleaned)) {
        cleaned.push('_');
    }
    cleaned
}

fn unique_dir(parent: &Path, name: &str) -> PathBuf {
    let base = sanitize_name(name);
    let mut candidate = parent.join(&base);
    let mut n = 2;
    while candidate.exists() {
        candidate = parent.join(format!("{base} ({n})"));
        n += 1;
    }
    candidate
}

fn unique_file(parent: &Path, name: &str, ext: &str) -> PathBuf {
    let base = sanitize_name(name);
    let mut candidate = parent.join(format!("{base}{ext}"));
    let mut n = 2;
    while candidate.exists() {
        candidate = parent.join(format!("{base} ({n}){ext}"));
        n += 1;
    }
    candidate
}
