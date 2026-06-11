//! Persistent index cache. The `NoteIndex` is derived entirely from a small set
//! of per-note facts (title, raw link targets, tags, size, word count) plus each
//! note's mtime. We cache those facts to `<vault>/.onyx/index-cache.json` so a
//! relaunch only has to **re-parse the notes whose mtime changed** — unchanged
//! notes skip the `read_to_string` + regex extraction entirely. Everything else
//! (link resolution, backlinks, tag sets, interners) is rebuilt in memory, which
//! is fast; the expensive part was always touching the files.
//!
//! The cache lives inside the vault's hidden `.onyx/` dir (like quicknote/todos):
//! it travels with the vault, is excluded from the scanner and the file watcher,
//! and is naturally isolated for tests. It is purely an optimization — a missing,
//! stale, or corrupt cache just means more re-parsing, never wrong data.

use std::collections::HashMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Bump when the cached fields change shape, so old caches are ignored.
/// v2: added per-note `properties`.
const CACHE_VERSION: u32 = 2;

/// One note's content-derived facts, keyed in the cache by vault-relative path.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheEntry {
    pub mtime_secs: u64,
    pub mtime_nanos: u32,
    pub title: String,
    pub targets: Vec<String>,
    pub tags: Vec<String>,
    #[serde(default)]
    pub properties: Vec<(String, Vec<String>)>,
    pub size: u64,
    pub word_count: usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct IndexCache {
    pub version: u32,
    /// vault-relative path (forward slashes) → cached facts.
    pub entries: HashMap<String, CacheEntry>,
}

impl IndexCache {
    fn empty() -> Self {
        Self {
            version: CACHE_VERSION,
            entries: HashMap::new(),
        }
    }

    pub fn new(entries: HashMap<String, CacheEntry>) -> Self {
        Self {
            version: CACHE_VERSION,
            entries,
        }
    }

    /// Load a cache from disk. Any failure (missing, unreadable, malformed, or a
    /// version mismatch) yields an empty cache so indexing simply re-parses.
    pub fn load(path: &Path) -> Self {
        let Ok(data) = std::fs::read(path) else {
            return Self::empty();
        };
        match serde_json::from_slice::<IndexCache>(&data) {
            Ok(c) if c.version == CACHE_VERSION => c,
            _ => Self::empty(),
        }
    }

    /// The cached entry for `relpath`, but only if its stored mtime matches the
    /// note's current mtime (i.e. the note hasn't changed since we cached it).
    pub fn fresh(&self, relpath: &str, mtime: SystemTime) -> Option<&CacheEntry> {
        let entry = self.entries.get(relpath)?;
        let (secs, nanos) = decompose(mtime)?;
        if entry.mtime_secs == secs && entry.mtime_nanos == nanos {
            Some(entry)
        } else {
            None
        }
    }

    /// Serialize and write the cache, creating the parent dir as needed.
    /// Best-effort: errors are returned but callers may ignore them.
    pub fn write(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_vec(self).map_err(std::io::Error::other)?;
        // Write directly; the cache is disposable, so atomic-rename machinery is
        // overkill here (a torn write just looks like a corrupt cache → re-parse).
        std::fs::write(path, data)
    }
}

/// Split a `SystemTime` into (seconds, sub-second nanos) since the Unix epoch.
/// `None` for pre-epoch times, which we treat as "uncacheable".
pub fn decompose(t: SystemTime) -> Option<(u64, u32)> {
    t.duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| (d.as_secs(), d.subsec_nanos()))
}
