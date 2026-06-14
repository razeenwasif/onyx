pub mod buffer;
pub mod history;
pub mod modes;

pub use buffer::{Buffer, Cursor};
pub use history::History;
pub use modes::Mode;

use std::path::PathBuf;
use std::time::SystemTime;

/// A single open document.
#[derive(Debug)]
#[allow(dead_code)]
pub struct Document {
    pub path: Option<PathBuf>,
    pub buffer: Buffer,
    pub history: History,
    pub mode: Mode,
    pub dirty: bool,
    pub scroll: usize,
    /// Selection anchor (start of selection); cursor is the live end.
    pub anchor: Option<Cursor>,
    /// Pending operator (e.g. "d" awaiting a motion).
    pub pending_op: Option<char>,
    /// Last search query (used for n/N).
    pub last_search: Option<String>,
    /// On-disk modification time when this document was last read or written by
    /// Onyx. Used to detect external edits (conflict guard / live reload).
    pub disk_mtime: Option<SystemTime>,
    /// When set, this buffer is a Google Drive file (its id + display name);
    /// saving uploads back to Drive instead of writing to the vault.
    pub drive_id: Option<String>,
    pub drive_name: Option<String>,
}

impl Document {
    #[allow(dead_code)]
    pub fn new() -> Self {
        Self {
            path: None,
            buffer: Buffer::from_string(String::new()),
            history: History::default(),
            mode: Mode::Normal,
            dirty: false,
            scroll: 0,
            anchor: None,
            pending_op: None,
            last_search: None,
            disk_mtime: None,
            drive_id: None,
            drive_name: None,
        }
    }

    pub fn from_text(path: Option<PathBuf>, text: String) -> Self {
        Self {
            path,
            buffer: Buffer::from_string(text),
            history: History::default(),
            mode: Mode::Normal,
            dirty: false,
            scroll: 0,
            anchor: None,
            pending_op: None,
            last_search: None,
            disk_mtime: None,
            drive_id: None,
            drive_name: None,
        }
    }

    pub fn title(&self) -> String {
        if let Some(name) = &self.drive_name {
            return format!("⇪ {name}");
        }
        match &self.path {
            Some(p) => p
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("Untitled")
                .to_string(),
            None => "Untitled".to_string(),
        }
    }
}
