//! Vault — the root folder of markdown notes, plus the in-memory index.

pub mod index;
pub mod index_cache;
pub mod tree;
pub mod watcher;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

use crate::error::{OnyxError, Result};

#[allow(unused_imports)]
pub use index::{NoteIndex, NoteMeta};
pub use tree::FileTree;
pub use watcher::VaultWatcher;

/// Owns the on-disk root, the file tree, and the link/tag index.
#[derive(Debug)]
pub struct Vault {
    pub root: PathBuf,
    pub tree: FileTree,
    pub index: NoteIndex,
}

impl Vault {
    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        let root = root.canonicalize().unwrap_or(root);
        if !root.exists() {
            return Err(OnyxError::VaultNotFound(root));
        }
        let tree = FileTree::scan(&root);
        let index = build_index(&root, &tree);
        Ok(Self { root, tree, index })
    }

    pub fn create(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        let welcome = root.join("Welcome.md");
        if !welcome.exists() {
            fs::write(
                &welcome,
                "# Welcome to your Onyx vault\n\n\
                This is a fresh markdown vault. A few things to try:\n\n\
                - Press `Ctrl-N` to make a new note.\n\
                - Type a [[Wikilink]] to connect notes.\n\
                - Add `#tags` to organize them.\n\
                - Press `Ctrl-P` for the command palette, `Ctrl-O` for quick switcher.\n\
                - Toggle the preview with `Ctrl-E` and graph view with `Ctrl-G`.\n\n\
                Happy writing!\n",
            )?;
        }
        Self::open(root)
    }

    pub fn refresh(&mut self) {
        self.tree = FileTree::scan(&self.root);
        self.index = build_index(&self.root, &self.tree);
    }

    /// Hidden per-vault data directory (`.onyx/`). The file-tree scanner skips
    /// hidden dirs, so these files never appear as notes or in the graph.
    pub fn data_dir(&self) -> PathBuf {
        self.root.join(".onyx")
    }

    pub fn quicknote_path(&self) -> PathBuf {
        self.data_dir().join("quicknote.md")
    }

    pub fn todos_path(&self) -> PathBuf {
        self.data_dir().join("todos.md")
    }

    pub fn read_note(&self, path: &Path) -> Result<String> {
        Ok(fs::read_to_string(path)?)
    }

    pub fn write_note(&mut self, path: &Path, content: &str) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        atomic_write(path, content.as_bytes())?;
        // Re-index just this note.
        self.index.update_note(&self.root, path, content);
        // Make sure file tree contains it.
        if !self.tree.contains(path) {
            self.tree = FileTree::scan(&self.root);
        }
        Ok(())
    }

    pub fn delete_note(&mut self, path: &Path) -> Result<()> {
        if path.exists() {
            fs::remove_file(path)?;
        }
        self.tree = FileTree::scan(&self.root);
        self.index.remove_note(path);
        Ok(())
    }

    /// Recursively delete a folder and everything in it, then re-index.
    pub fn delete_folder(&mut self, path: &Path) -> Result<()> {
        if path.exists() {
            fs::remove_dir_all(path)?;
        }
        self.refresh();
        Ok(())
    }

    pub fn rename_note(&mut self, from: &Path, to: &Path) -> Result<()> {
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::rename(from, to)?;
        self.refresh();
        Ok(())
    }

    /// Resolve a wikilink target (case-insensitive, optionally `folder/name`)
    /// to a concrete path on disk inside this vault. None if no match.
    pub fn resolve_link(&self, target: &str) -> Option<PathBuf> {
        self.index.resolve(&self.root, target)
    }

    /// Path for a new note. `title` may include `/` to place the note in a
    /// subfolder (`Projects/Idea` → `<vault>/Projects/Idea.md`); intermediate
    /// folders are created when the note is written.
    pub fn path_for_new_note(&self, title: &str) -> PathBuf {
        let rel = sanitize_relpath(title);
        let base = ensure_md_ext(self.root.join(&rel));
        if !base.exists() {
            return base;
        }
        // Append a counter, keeping the note in its folder.
        let parent = base
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| self.root.clone());
        let stem = base
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Untitled")
            .to_string();
        for n in 2..10_000 {
            let candidate = parent.join(format!("{stem} {n}.md"));
            if !candidate.exists() {
                return candidate;
            }
        }
        base
    }

    /// Create an (empty) folder at a vault-relative path, creating intermediate
    /// directories. Returns the created path.
    pub fn create_folder(&mut self, rel: &str) -> Result<PathBuf> {
        let path = self.root.join(sanitize_relpath(rel));
        fs::create_dir_all(&path)?;
        self.tree = FileTree::scan(&self.root);
        Ok(path)
    }
}

/// Build the note index for `root`, using the on-disk index cache to skip
/// re-parsing notes whose mtime is unchanged, then persist the refreshed cache.
/// The cache is a pure optimization — load/save failures are ignored and the
/// result is identical to an uncached `NoteIndex::build`.
fn build_index(root: &Path, tree: &FileTree) -> NoteIndex {
    let cache_path = root.join(".onyx").join("index-cache.json");
    let cache = index_cache::IndexCache::load(&cache_path);
    let index = NoteIndex::build_with_cache(root, tree, &cache);
    let _ = index.export_cache(root).write(&cache_path);
    index
}

/// Sanitize a possibly-nested title into a safe vault-relative path (without an
/// extension). Splits on `/` and `\`, drops `.`/`..`/empty components, and
/// strips illegal characters from each component.
pub fn sanitize_relpath(s: &str) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in s.split(['/', '\\']) {
        let c = comp.trim();
        if c.is_empty() || c == "." || c == ".." {
            continue;
        }
        out.push(sanitize_title(c));
    }
    if out.as_os_str().is_empty() {
        out.push("Untitled");
    }
    out
}

/// Ensure a path ends in a markdown extension (`.md` if it has none).
fn ensure_md_ext(path: PathBuf) -> PathBuf {
    let is_md = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| matches!(e, "md" | "markdown" | "mdx"))
        .unwrap_or(false);
    if is_md {
        return path;
    }
    let mut p = path;
    let name = p
        .file_name()
        .map(|n| format!("{}.md", n.to_string_lossy()))
        .unwrap_or_else(|| "Untitled.md".to_string());
    p.set_file_name(name);
    p
}

pub fn sanitize_title(s: &str) -> String {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return "Untitled".to_string();
    }
    let mut out = String::with_capacity(trimmed.len());
    for c in trimmed.chars() {
        match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0' => out.push('-'),
            _ => out.push(c),
        }
    }
    out
}

/// Convenience: filename without `.md` extension.
pub fn note_basename(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("untitled")
        .to_string()
}

/// Path relative to the vault root, using forward slashes.
pub fn note_relpath(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| path.to_string_lossy().to_string())
}

/// The on-disk modification time of a file, if it exists and is readable.
/// Used by the conflict guard to detect external edits.
pub fn file_mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// Write `data` to `path` atomically: write to a hidden sibling temp file in the
/// same directory, fsync it, then `rename` over the target. A crash mid-write
/// can never truncate or corrupt the real note — the rename either happens or it
/// doesn't. The temp name is dot-prefixed so the file-tree scanner ignores it,
/// and carries a per-process counter so concurrent writers don't collide.
pub fn atomic_write(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let stem = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "note".to_string());
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = parent.join(format!(".{stem}.{}.{n}.onyxtmp", std::process::id()));

    // Write + flush + fsync the temp file before swapping it in.
    let res = (|| -> std::io::Result<()> {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.flush()?;
        let _ = f.sync_all();
        Ok(())
    })();
    if let Err(e) = res {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir() -> PathBuf {
        let base =
            std::env::temp_dir().join(format!("onyx-vault-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&base);
        base
    }

    #[test]
    fn atomic_write_persists_content_and_overwrites() {
        let dir = tmp_dir();
        let target = dir.join("note.md");
        atomic_write(&target, b"first").unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), "first");
        // Overwriting replaces content wholesale.
        atomic_write(&target, b"second longer").unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), "second longer");
        let _ = fs::remove_file(&target);
    }

    #[test]
    fn atomic_write_leaves_no_temp_files() {
        let dir = tmp_dir().join("notemp");
        let _ = fs::create_dir_all(&dir);
        let target = dir.join("clean.md");
        atomic_write(&target, b"body").unwrap();
        // The only entry in the dir should be the note itself — no .onyxtmp.
        let entries: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(entries, vec!["clean.md".to_string()]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn file_mtime_some_for_existing_none_for_missing() {
        let dir = tmp_dir();
        let target = dir.join("mt.md");
        atomic_write(&target, b"x").unwrap();
        assert!(file_mtime(&target).is_some());
        let _ = fs::remove_file(&target);
        assert!(file_mtime(&dir.join("does-not-exist.md")).is_none());
    }
}
