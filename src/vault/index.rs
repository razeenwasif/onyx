//! In-memory index of wikilinks, tags, and backlinks across the vault.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::markdown::parse::{
    extract_all_tags, extract_frontmatter_properties, extract_links, extract_md_links,
};

use super::index_cache::{self, CacheEntry, IndexCache};
use super::tree::FileTree;

/// A note's content-derived facts, extracted once from its text. This is the
/// only thing the index needs from a note's bytes — caching it (see
/// `index_cache`) lets a relaunch skip re-reading unchanged files.
#[derive(Debug, Clone)]
pub(crate) struct ParsedNote {
    pub title: String,
    pub targets: Vec<String>,
    pub tags: Vec<String>,
    pub properties: Vec<(String, Vec<String>)>,
    pub size: u64,
    pub word_count: usize,
}

impl ParsedNote {
    /// Extract the index-relevant facts from a note's raw content.
    fn from_content(content: &str, path: &Path) -> Self {
        let links = extract_links(content);
        let mut targets: Vec<String> = links.iter().map(|l| l.note_name().to_string()).collect();
        targets.extend(extract_md_links(content));
        // Page properties, minus `tags`/`tag` (surfaced separately as tags).
        let properties = extract_frontmatter_properties(content)
            .into_iter()
            .filter(|(k, _)| {
                let lk = k.to_ascii_lowercase();
                lk != "tags" && lk != "tag"
            })
            .collect();
        Self {
            title: first_heading_or_basename(content, path),
            targets,
            tags: extract_all_tags(content),
            properties,
            size: content.len() as u64,
            word_count: content.split_whitespace().count(),
        }
    }

    fn from_cache_entry(entry: &CacheEntry) -> Self {
        Self {
            title: entry.title.clone(),
            targets: entry.targets.clone(),
            tags: entry.tags.clone(),
            properties: entry.properties.clone(),
            size: entry.size,
            word_count: entry.word_count,
        }
    }
}

#[derive(Debug, Clone, Default)]
#[allow(dead_code)]
pub struct NoteMeta {
    pub title: String,
    /// Raw link targets as written (note name or `folder/name`), pre-resolution.
    /// Backlinks recompute from these so folder context isn't lost.
    pub targets: Vec<String>,
    pub outgoing: Vec<Arc<Path>>,
    pub unresolved: Vec<String>,
    pub tags: Vec<Arc<str>>,
    /// Notion-style page properties from YAML frontmatter, in document order
    /// (`tags`/`tag` excluded — those live in `tags`). Each value is a list
    /// (scalars are single-element).
    pub properties: Vec<(String, Vec<String>)>,
    pub mtime: Option<std::time::SystemTime>,
    pub size: u64,
    pub word_count: usize,
}

/// Paths and tags are *interned* as `Arc<Path>` / `Arc<str>`: each unique value
/// is allocated once and shared across every map by cheap refcount-bump clones,
/// instead of duplicating `PathBuf`/`String` heap copies in each map. Public
/// methods still return owned `PathBuf`/`String` so callers are unaffected.
#[derive(Debug, Default)]
pub struct NoteIndex {
    /// path → metadata.
    pub notes: HashMap<Arc<Path>, NoteMeta>,
    /// note basename (lowercased, no extension) → all paths sharing that name.
    by_basename: HashMap<String, Vec<Arc<Path>>>,
    /// "folder/path/name" lowercased → exact path.
    by_relpath: HashMap<String, Arc<Path>>,
    /// path → notes linking *to* this path.
    backlinks: HashMap<Arc<Path>, Vec<Arc<Path>>>,
    /// tag → notes containing it.
    by_tag: BTreeMap<Arc<str>, HashSet<Arc<Path>>>,
    /// Interners: one shared `Arc` per unique path / tag.
    path_interner: HashMap<Arc<Path>, ()>,
    tag_interner: HashMap<Arc<str>, ()>,
}

impl NoteIndex {
    /// Uncached full build (reads + parses every note). The app goes through
    /// `build_with_cache`; this is kept as the simple reference builder used by
    /// tests.
    #[allow(dead_code)]
    pub fn build(root: &Path, tree: &FileTree) -> Self {
        let mut idx = NoteIndex::default();
        for note in &tree.notes {
            if let Ok(content) = fs::read_to_string(note) {
                idx.ingest(root, note, &content);
            }
        }
        idx.recompute_backlinks();
        idx
    }

    /// Like `build`, but reuse `cache` for any note whose mtime is unchanged —
    /// those skip the `read_to_string` + parse. Changed/new notes (and notes not
    /// in the cache) are read and parsed fresh. The result is identical to
    /// `build`; only the work to get there is smaller.
    pub fn build_with_cache(root: &Path, tree: &FileTree, cache: &IndexCache) -> Self {
        let mut idx = NoteIndex::default();
        for note in &tree.notes {
            let mtime = fs::metadata(note).ok().and_then(|m| m.modified().ok());
            let relpath = super::note_relpath(root, note);
            let parsed = match mtime.and_then(|mt| cache.fresh(&relpath, mt)) {
                Some(entry) => ParsedNote::from_cache_entry(entry),
                None => match fs::read_to_string(note) {
                    Ok(content) => ParsedNote::from_content(&content, note),
                    Err(_) => continue,
                },
            };
            idx.ingest_parsed(root, note, &parsed, mtime);
        }
        idx.recompute_backlinks();
        idx
    }

    /// Snapshot the index's per-note facts into a cache, keyed by vault-relative
    /// path. Notes without a usable mtime are skipped (can't be validated later).
    pub fn export_cache(&self, root: &Path) -> IndexCache {
        let mut entries = HashMap::with_capacity(self.notes.len());
        for (path, meta) in &self.notes {
            let Some((mtime_secs, mtime_nanos)) = meta.mtime.and_then(index_cache::decompose)
            else {
                continue;
            };
            let relpath = super::note_relpath(root, path);
            entries.insert(
                relpath,
                CacheEntry {
                    mtime_secs,
                    mtime_nanos,
                    title: meta.title.clone(),
                    targets: meta.targets.clone(),
                    tags: meta.tags.iter().map(|t| t.to_string()).collect(),
                    properties: meta.properties.clone(),
                    size: meta.size,
                    word_count: meta.word_count,
                },
            );
        }
        IndexCache::new(entries)
    }

    /// Return the shared `Arc<Path>` for `p`, allocating once on first sight.
    fn intern_path(&mut self, p: &Path) -> Arc<Path> {
        if let Some((k, _)) = self.path_interner.get_key_value(p) {
            return k.clone();
        }
        let a: Arc<Path> = Arc::from(p);
        self.path_interner.insert(a.clone(), ());
        a
    }

    /// Return the shared `Arc<str>` for tag `s`, allocating once on first sight.
    fn intern_tag(&mut self, s: &str) -> Arc<str> {
        if let Some((k, _)) = self.tag_interner.get_key_value(s) {
            return k.clone();
        }
        let a: Arc<str> = Arc::from(s);
        self.tag_interner.insert(a.clone(), ());
        a
    }

    fn ingest(&mut self, root: &Path, path: &Path, content: &str) {
        let parsed = ParsedNote::from_content(content, path);
        let mtime = fs::metadata(path).ok().and_then(|m| m.modified().ok());
        self.ingest_parsed(root, path, &parsed, mtime);
    }

    /// Insert a note into the index from its already-extracted facts. Shared by
    /// the fresh-parse path (`ingest`) and the cache path (`build_with_cache`):
    /// the input `parsed` is identical either way, so the index is too.
    fn ingest_parsed(
        &mut self,
        root: &Path,
        path: &Path,
        parsed: &ParsedNote,
        mtime: Option<std::time::SystemTime>,
    ) {
        let id = self.intern_path(path); // canonical Arc<Path> for this note

        // Build basename/relpath lookups *for this note* before resolving its links.
        let basename = super::note_basename(path).to_lowercase();
        self.by_basename.entry(basename).or_default().push(id.clone());
        let relpath = super::note_relpath(root, path).to_lowercase();
        // Drop extension from the key so [[folder/note]] resolves.
        let relpath_no_ext = relpath
            .strip_suffix(".md")
            .or_else(|| relpath.strip_suffix(".markdown"))
            .or_else(|| relpath.strip_suffix(".mdx"))
            .unwrap_or(&relpath)
            .to_string();
        self.by_relpath.insert(relpath_no_ext, id.clone());

        let tags: Vec<Arc<str>> = parsed.tags.iter().map(|t| self.intern_tag(t)).collect();

        self.notes.insert(
            id.clone(),
            NoteMeta {
                title: parsed.title.clone(),
                targets: parsed.targets.clone(),
                outgoing: Vec::new(),
                unresolved: Vec::new(),
                tags: tags.clone(),
                properties: parsed.properties.clone(),
                mtime,
                size: parsed.size,
                word_count: parsed.word_count,
            },
        );

        let (outgoing, unresolved) = self.resolve_targets(path, &parsed.targets);

        for t in &tags {
            self.by_tag.entry(t.clone()).or_default().insert(id.clone());
        }

        if let Some(meta) = self.notes.get_mut(&id) {
            meta.outgoing = outgoing;
            meta.unresolved = unresolved;
        }
    }

    /// Resolve a note's raw link targets into (outgoing paths, unresolved names),
    /// skipping self-links and duplicates. Folder context is preserved (a
    /// `Folder/B` target won't collapse to a bare `B`).
    fn resolve_targets(&self, src: &Path, targets: &[String]) -> (Vec<Arc<Path>>, Vec<String>) {
        let mut resolved: Vec<Arc<Path>> = Vec::new();
        let mut unresolved: Vec<String> = Vec::new();
        for target in targets {
            if let Some(p) = self.resolve_arc(target) {
                if p.as_ref() != src && !resolved.contains(&p) {
                    resolved.push(p);
                }
            } else if !unresolved.contains(target) {
                unresolved.push(target.clone());
            }
        }
        (resolved, unresolved)
    }

    fn recompute_backlinks(&mut self) {
        self.backlinks.clear();
        let ids: Vec<Arc<Path>> = self.notes.keys().cloned().collect();
        for src in &ids {
            let targets = match self.notes.get(src) {
                Some(m) => m.targets.clone(),
                None => continue,
            };
            let (resolved, unresolved) = self.resolve_targets(src, &targets);
            if let Some(m) = self.notes.get_mut(src) {
                m.outgoing = resolved.clone();
                m.unresolved = unresolved;
            }
            for dst in resolved {
                self.backlinks.entry(dst).or_default().push(src.clone());
            }
        }
        for v in self.backlinks.values_mut() {
            v.sort();
            v.dedup();
        }
    }

    fn resolve_internal(&self, target: &str) -> Option<Arc<Path>> {
        let lc = target.to_lowercase();
        if let Some(p) = self.by_relpath.get(&lc) {
            return Some(p.clone());
        }
        if let Some(matches) = self.by_basename.get(&lc) {
            return matches.first().cloned();
        }
        // Fall back to the last path component as a basename, so relative
        // markdown links like `Sub/Note` or `../Foo/Note` still resolve.
        if let Some(base) = lc.rsplit('/').next() {
            if base != lc {
                if let Some(matches) = self.by_basename.get(base) {
                    return matches.first().cloned();
                }
            }
        }
        None
    }

    /// Resolve a target to its interned `Arc<Path>` (extension-insensitive).
    fn resolve_arc(&self, target: &str) -> Option<Arc<Path>> {
        let cleaned = target
            .trim()
            .trim_end_matches(".md")
            .trim_end_matches(".markdown")
            .trim_end_matches(".mdx");
        self.resolve_internal(cleaned)
    }

    /// Resolve a wikilink target to a concrete path inside the vault.
    /// Accepts `Name`, `Folder/Name`, with optional `.md` extension.
    pub fn resolve(&self, _root: &Path, target: &str) -> Option<PathBuf> {
        self.resolve_arc(target).map(|a| a.to_path_buf())
    }

    pub fn backlinks_for(&self, path: &Path) -> Vec<PathBuf> {
        self.backlinks
            .get(path)
            .map(|v| v.iter().map(|p| p.to_path_buf()).collect())
            .unwrap_or_default()
    }

    pub fn all_tags(&self) -> Vec<(String, usize)> {
        self.by_tag
            .iter()
            .map(|(t, set)| (t.to_string(), set.len()))
            .collect()
    }

    pub fn notes_with_tag(&self, tag: &str) -> Vec<PathBuf> {
        self.by_tag
            .get(tag)
            .map(|s| {
                let mut v: Vec<PathBuf> = s.iter().map(|p| p.to_path_buf()).collect();
                v.sort();
                v
            })
            .unwrap_or_default()
    }

    /// Notes that share at least one tag with `path` (excluding itself),
    /// ordered by how many tags they share (most first), capped at `limit`.
    pub fn shared_tag_notes(&self, path: &Path, limit: usize) -> Vec<PathBuf> {
        let Some(meta) = self.notes.get(path) else {
            return Vec::new();
        };
        let mut counts: HashMap<Arc<Path>, usize> = HashMap::new();
        for t in &meta.tags {
            if let Some(members) = self.by_tag.get(t) {
                for m in members {
                    if m.as_ref() != path {
                        *counts.entry(m.clone()).or_insert(0) += 1;
                    }
                }
            }
        }
        let mut ranked: Vec<(Arc<Path>, usize)> = counts.into_iter().collect();
        // Most shared tags first; stable tiebreak by path for determinism.
        ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        ranked
            .into_iter()
            .take(limit)
            .map(|(p, _)| p.to_path_buf())
            .collect()
    }

    pub fn update_note(&mut self, root: &Path, path: &Path, content: &str) {
        // A brand-new note may satisfy *other* notes' previously-unresolved
        // links, so it needs a full backlink recompute. Editing an existing
        // note can't change how others resolve to it (same path), so we update
        // only the edges that this note owns — O(this note) instead of O(vault).
        if !self.notes.contains_key(path) {
            self.ingest(root, path, content);
            self.recompute_backlinks();
            return;
        }

        // 1. Drop the note's old outgoing edges from the backlink map.
        let old_out = self
            .notes
            .get(path)
            .map(|m| m.outgoing.clone())
            .unwrap_or_default();
        for dst in &old_out {
            if let Some(v) = self.backlinks.get_mut(dst) {
                v.retain(|s| s.as_ref() != path);
            }
        }

        // 2. Re-index the note's own metadata (tags/basename/relpath/outgoing),
        //    leaving its *inbound* backlinks (other notes → this note) intact.
        self.unindex_note_meta(path);
        self.ingest(root, path, content);

        // 3. Add the note's new outgoing edges back into the backlink map.
        let id = self.intern_path(path);
        let new_out = self
            .notes
            .get(&id)
            .map(|m| m.outgoing.clone())
            .unwrap_or_default();
        for dst in &new_out {
            let v = self.backlinks.entry(dst.clone()).or_default();
            v.push(id.clone());
            v.sort();
            v.dedup();
        }
    }

    /// Remove a note's own metadata from the index (notes/tags/basename/relpath)
    /// *without* touching the backlink graph. Used by both `remove_note` and the
    /// incremental `update_note`.
    fn unindex_note_meta(&mut self, path: &Path) {
        if let Some(meta) = self.notes.remove(path) {
            for t in &meta.tags {
                if let Some(set) = self.by_tag.get_mut(t) {
                    set.remove(path);
                    if set.is_empty() {
                        self.by_tag.remove(t);
                    }
                }
            }
        }
        let basename = crate::vault::note_basename(path).to_lowercase();
        if let Some(v) = self.by_basename.get_mut(&basename) {
            v.retain(|p| p.as_ref() != path);
            if v.is_empty() {
                self.by_basename.remove(&basename);
            }
        }
        // Clear from by_relpath the matching entry (linear scan, vault not huge).
        let to_remove: Vec<String> = self
            .by_relpath
            .iter()
            .filter(|(_, v)| v.as_ref() == path)
            .map(|(k, _)| k.clone())
            .collect();
        for k in to_remove {
            self.by_relpath.remove(&k);
        }
    }

    pub fn remove_note(&mut self, path: &Path) {
        self.unindex_note_meta(path);
        // Remove this note's inbound list and scrub it from every other list.
        self.backlinks.remove(path);
        for v in self.backlinks.values_mut() {
            v.retain(|p| p.as_ref() != path);
        }
    }

    /// All note paths in the vault, sorted by recency (most recent first).
    pub fn recent_notes(&self) -> Vec<(PathBuf, &NoteMeta)> {
        let mut all: Vec<_> = self.notes.iter().map(|(p, m)| (p.to_path_buf(), m)).collect();
        all.sort_by_key(|x| std::cmp::Reverse(x.1.mtime));
        all
    }

    /// All note paths sorted alphabetically.
    pub fn all_notes(&self) -> Vec<(PathBuf, &NoteMeta)> {
        let mut all: Vec<_> = self.notes.iter().map(|(p, m)| (p.to_path_buf(), m)).collect();
        all.sort_by(|a, b| a.0.cmp(&b.0));
        all
    }

    /// Total counts for the status bar.
    pub fn stats(&self) -> IndexStats {
        let mut total_links = 0;
        let mut unresolved = 0;
        for m in self.notes.values() {
            total_links += m.outgoing.len();
            unresolved += m.unresolved.len();
        }
        IndexStats {
            notes: self.notes.len(),
            links: total_links,
            unresolved_links: unresolved,
            tags: self.by_tag.len(),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct IndexStats {
    pub notes: usize,
    pub links: usize,
    pub unresolved_links: usize,
    pub tags: usize,
}

fn first_heading_or_basename(content: &str, path: &Path) -> String {
    for line in content.lines().take(40) {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix('#') {
            let rest = rest.trim_start_matches('#').trim();
            if !rest.is_empty() {
                return rest.to_string();
            }
        }
    }
    crate::vault::note_basename(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::tree::FileTree;
    use std::fs;

    fn write(p: &Path, s: &str) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, s).unwrap();
    }

    /// Incremental update_note keeps backlinks correct when a note's links change.
    #[test]
    fn incremental_update_fixes_backlinks() {
        let root = std::env::temp_dir().join(format!("onyx-inc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        write(&root.join("A.md"), "see [[B]]\n");
        write(&root.join("B.md"), "b\n");
        write(&root.join("C.md"), "c\n");

        let tree = FileTree::scan(&root);
        let mut idx = NoteIndex::build(&root, &tree);
        let (a, b, c) = (root.join("A.md"), root.join("B.md"), root.join("C.md"));
        assert_eq!(idx.backlinks_for(&b), vec![a.clone()]);
        assert!(idx.backlinks_for(&c).is_empty());

        // Edit A to point at C instead of B (existing-note → incremental path).
        idx.update_note(&root, &a, "see [[C]]\n");
        assert!(
            idx.backlinks_for(&b).is_empty(),
            "old backlink A→B should be gone"
        );
        assert_eq!(
            idx.backlinks_for(&c),
            vec![a.clone()],
            "new backlink A→C should exist"
        );
        // A's own inbound backlinks (none) stay intact; outgoing updated.
        let out: Vec<PathBuf> = idx
            .notes
            .get(&a as &Path)
            .unwrap()
            .outgoing
            .iter()
            .map(|p| p.to_path_buf())
            .collect();
        assert_eq!(out, vec![c.clone()]);

        let _ = fs::remove_dir_all(&root);
    }

    /// The cache round-trips: an index built from a freshly-exported cache is
    /// identical (stats + backlinks) to one built by reading every file.
    #[test]
    fn index_cache_roundtrip_matches_full_build() {
        let root = std::env::temp_dir().join(format!("onyx-cache-rt-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        write(&root.join("A.md"), "# Alpha\nsee [[B]] #x\n");
        write(&root.join("B.md"), "# Bravo\n#x #y\n");
        write(&root.join("Sub/C.md"), "see [Folder B](../B.md)\n");

        let tree = FileTree::scan(&root);
        let full = NoteIndex::build(&root, &tree);
        let cache = full.export_cache(&root);
        let cached = NoteIndex::build_with_cache(&root, &tree, &cache);

        let (sf, sc) = (full.stats(), cached.stats());
        assert_eq!(sf.notes, sc.notes);
        assert_eq!(sf.links, sc.links);
        assert_eq!(sf.unresolved_links, sc.unresolved_links);
        assert_eq!(sf.tags, sc.tags);
        let b = root.join("B.md");
        assert_eq!(full.backlinks_for(&b), cached.backlinks_for(&b));
        assert!(!cached.backlinks_for(&b).is_empty());

        let _ = fs::remove_dir_all(&root);
    }

    /// A note whose mtime no longer matches the cache is a cache miss and gets
    /// re-parsed, so the rebuilt index reflects the on-disk content, not the
    /// stale cached facts. (We force the mismatch by stamping the cached entry's
    /// mtime, so the test is independent of filesystem timestamp granularity.)
    #[test]
    fn index_cache_stale_entry_is_reparsed() {
        let root = std::env::temp_dir().join(format!("onyx-cache-stale-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let a = root.join("A.md");
        write(&a, "see [[B]]\n");
        write(&root.join("B.md"), "b\n");
        write(&root.join("C.md"), "c\n");

        let tree = FileTree::scan(&root);
        let mut cache = NoteIndex::build(&root, &tree).export_cache(&root);
        // Make A's cached entry deliberately stale (epoch mtime never matches).
        if let Some(e) = cache.entries.get_mut("A.md") {
            e.mtime_secs = 0;
            e.mtime_nanos = 0;
        }

        // Rewrite A to link C instead of B; this must win over the stale cache.
        write(&a, "see [[C]]\n");

        let rebuilt = NoteIndex::build_with_cache(&root, &tree, &cache);
        let (b, c) = (root.join("B.md"), root.join("C.md"));
        assert!(
            rebuilt.backlinks_for(&b).is_empty(),
            "stale A→B backlink must be dropped after re-parse"
        );
        assert_eq!(
            rebuilt.backlinks_for(&c),
            vec![a.clone()],
            "fresh A→C backlink must appear after re-parse"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// Manual benchmark: `ONYX_BENCH_VAULT=/path cargo test bench_cache -- --nocapture`.
    /// Self-skips when the env var is unset, so it never runs in CI.
    #[test]
    fn bench_cache() {
        let Some(dir) = std::env::var_os("ONYX_BENCH_VAULT") else {
            return;
        };
        let root = PathBuf::from(dir);
        let tree = FileTree::scan(&root);
        let t0 = std::time::Instant::now();
        let full = NoteIndex::build(&root, &tree);
        let cold = t0.elapsed();
        let cache = full.export_cache(&root);
        let t1 = std::time::Instant::now();
        let warm = NoteIndex::build_with_cache(&root, &tree, &cache);
        let warm_dur = t1.elapsed();
        eprintln!(
            "bench: {} notes | cold build {:?} | warm (cached) build {:?} | {:.1}x",
            full.stats().notes,
            cold,
            warm_dur,
            cold.as_secs_f64() / warm_dur.as_secs_f64().max(1e-9)
        );
        assert_eq!(full.stats().notes, warm.stats().notes);
    }

    /// Subfolder-aware note paths: `Projects/Idea` → `<root>/Projects/Idea.md`.
    #[test]
    fn new_note_path_supports_subfolders() {
        let root = std::env::temp_dir().join(format!("onyx-mk-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let vault = crate::vault::Vault::open(&root).unwrap();

        let p = vault.path_for_new_note("Projects/Idea");
        assert_eq!(p, root.join("Projects").join("Idea.md"));

        // Plain titles still land in the root.
        let q = vault.path_for_new_note("Scratch");
        assert_eq!(q, root.join("Scratch.md"));

        // `..` / extra slashes are stripped, can't escape the vault.
        let r = vault.path_for_new_note("../../etc/passwd");
        assert!(r.starts_with(&root));

        let _ = fs::remove_dir_all(&root);
    }

    /// Finding #2: a folder-qualified link must resolve to the note in that
    /// folder, not collapse to a same-named note elsewhere after recompute.
    #[test]
    fn folder_qualified_link_keeps_context() {
        let root = std::env::temp_dir().join(format!("onyx-idx-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        write(&root.join("B.md"), "top-level B");
        write(&root.join("Folder/B.md"), "nested B");
        write(&root.join("A.md"), "see [Folder/B](Folder/B.md)\n");

        let tree = FileTree::scan(&root);
        let idx = NoteIndex::build(&root, &tree);

        let a = root.join("A.md");
        let meta = idx.notes.get(a.as_path()).expect("A indexed");
        let out: Vec<PathBuf> = meta.outgoing.iter().map(|p| p.to_path_buf()).collect();
        assert_eq!(
            out,
            vec![root.join("Folder/B.md")],
            "link to Folder/B should resolve to the nested note, not top-level B.md"
        );

        let _ = fs::remove_dir_all(&root);
    }
}
