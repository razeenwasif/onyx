//! Text read out of handwriting, so search can find words that were written
//! rather than typed.
//!
//! Recognition itself happens in the app (macOS Vision); this module keeps
//! its results. They live in one index at `<workspace>/.scribe/ink-text.json`,
//! keyed by page id, rather than in the page files: the text is derived and
//! can always be rebuilt, page files stay exactly the documented format, and a
//! page save can never drop it. Each entry remembers the page's `modified`
//! stamp (as Unix seconds) at the time it was read, so an edited page shows up
//! as pending again.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{de::IgnoredAny, Deserialize, Serialize};

use crate::workspace::{parse_stamp, path_str, read_json, write_json, Result, Workspace};

pub const SCHEMA: &str = "scribe.inkText/1";

#[derive(Serialize, Deserialize, Default, Debug, Clone)]
pub struct InkIndex {
    #[serde(default)]
    pub schema: String,
    #[serde(default)]
    pub pages: BTreeMap<String, InkEntry>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct InkEntry {
    /// The recognised text, one line per line of writing.
    pub text: String,
    /// The page's `modified` stamp, in Unix seconds, when this was read.
    pub modified: f64,
}

/// A page whose handwriting hasn't been read since it last changed.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct PendingInk {
    pub id: String,
    pub path: String,
    pub modified: f64,
}

/// Just enough of a page to tell whether its ink needs reading: the id, the
/// stamp, and how many strokes (counted without building them).
#[derive(Deserialize)]
struct InkHeader {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    modified: Option<String>,
    #[serde(default)]
    strokes: Vec<IgnoredAny>,
    #[serde(default)]
    background: Option<BackgroundKind>,
}

#[derive(Deserialize)]
struct BackgroundKind {
    #[serde(default)]
    kind: String,
}

impl Workspace {
    pub fn ink_index_path(&self) -> PathBuf {
        self.root.join(".scribe").join("ink-text.json")
    }

    /// The index, or an empty one if it's missing or unreadable (it can
    /// always be rebuilt).
    pub fn ink_index(&self) -> InkIndex {
        read_json::<InkIndex>(&self.ink_index_path()).unwrap_or_default()
    }

    /// Pages with ink that has never been read or has changed since, and
    /// pages whose ink was erased but still have text on record. Ordered
    /// most recently edited first, so the pages people care about go first.
    pub fn ink_pending(&self) -> Vec<PendingInk> {
        let index = self.ink_index();
        let mut out = Vec::new();
        for nb in self.list_notebook_dirs() {
            for sec in self.list_section_dirs(&nb) {
                for file in self.list_page_files(&sec) {
                    let Some(page) = read_json::<InkHeader>(&file) else { continue };
                    let Some(id) = page.id else { continue };
                    let modified = parse_stamp(page.modified.as_deref());
                    let entry = index.pages.get(id.as_str());
                    let stale = match entry {
                        Some(e) => e.modified != modified,
                        // Imported PDF pages carry writing in their background.
                        None => {
                            !page.strokes.is_empty()
                                || page.background.as_ref().is_some_and(|b| b.kind.eq_ignore_ascii_case("pdf"))
                        }
                    };
                    if stale {
                        out.push(PendingInk { id, path: path_str(&file), modified });
                    }
                }
            }
        }
        out.sort_by(|a, b| b.modified.total_cmp(&a.modified));
        out
    }

    /// Records what the ink on page `id` says, as read from the version
    /// stamped `modified`. Keyed by id, so it survives the page being renamed
    /// (which moves its file) while it was being read. Empty text removes the
    /// entry.
    pub fn set_ink_text(&self, id: &str, text: &str, modified: f64) -> Result<()> {
        if id.is_empty() {
            return Err("A page id is required".into());
        }
        let id = id.to_string();
        let mut index = self.ink_index();
        index.schema = SCHEMA.to_string();
        let text = text.trim();
        if text.is_empty() {
            index.pages.remove(&id);
        } else {
            index.pages.insert(id, InkEntry { text: text.to_string(), modified });
        }
        write_json(&self.ink_index_path(), &index)
    }
}
