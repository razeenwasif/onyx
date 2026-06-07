//! In-memory index of wikilinks, tags, and backlinks across the vault.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use crate::markdown::parse::{extract_all_tags, extract_links, extract_md_links};

use super::tree::FileTree;

#[derive(Debug, Clone, Default)]
#[allow(dead_code)]
pub struct NoteMeta {
    pub title: String,
    /// Raw link targets as written (note name or `folder/name`), pre-resolution.
    /// Backlinks recompute from these so folder context isn't lost.
    pub targets: Vec<String>,
    pub outgoing: Vec<PathBuf>,
    pub unresolved: Vec<String>,
    pub tags: Vec<String>,
    pub mtime: Option<std::time::SystemTime>,
    pub size: u64,
    pub word_count: usize,
}

#[derive(Debug, Default)]
pub struct NoteIndex {
    /// path → metadata.
    pub notes: HashMap<PathBuf, NoteMeta>,
    /// note basename (lowercased, no extension) → all paths sharing that name.
    by_basename: HashMap<String, Vec<PathBuf>>,
    /// "folder/path/name" lowercased → exact path.
    by_relpath: HashMap<String, PathBuf>,
    /// path → notes linking *to* this path.
    backlinks: HashMap<PathBuf, Vec<PathBuf>>,
    /// tag → notes containing it.
    by_tag: BTreeMap<String, HashSet<PathBuf>>,
}

impl NoteIndex {
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

    fn ingest(&mut self, root: &Path, path: &Path, content: &str) {
        let links = extract_links(content);
        let tags = extract_all_tags(content);

        // Build basename/relpath lookups *for this note* before resolving its links.
        // (Other notes are added by their own ingest call — resolution may be
        // partial during initial build; we recompute backlinks once at the end.)
        let basename = super::note_basename(path).to_lowercase();
        self.by_basename
            .entry(basename.clone())
            .or_default()
            .push(path.to_path_buf());
        let relpath = super::note_relpath(root, path).to_lowercase();
        // Drop extension from the key so [[folder/note]] resolves.
        let relpath_no_ext = relpath
            .strip_suffix(".md")
            .or_else(|| relpath.strip_suffix(".markdown"))
            .or_else(|| relpath.strip_suffix(".mdx"))
            .unwrap_or(&relpath)
            .to_string();
        self.by_relpath.insert(relpath_no_ext, path.to_path_buf());

        // First pass — collect targets without resolution; we resolve below.
        // Both `[[wikilinks]]` and inline `[text](note.md)` links count as edges.
        let mut link_targets: Vec<String> = links.iter().map(|l| l.note_name().to_string()).collect();
        link_targets.extend(extract_md_links(content));

        let mtime = fs::metadata(path).ok().and_then(|m| m.modified().ok());
        let size = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        let word_count = content.split_whitespace().count();

        let title = first_heading_or_basename(content, path);

        // Store metadata with the raw targets; resolution happens below and in
        // recompute_backlinks (which re-resolves from `targets`).
        self.notes.insert(
            path.to_path_buf(),
            NoteMeta {
                title,
                targets: link_targets.clone(),
                outgoing: Vec::new(),
                unresolved: Vec::new(),
                tags: tags.clone(),
                mtime,
                size,
                word_count,
            },
        );

        // Resolve outgoing links (skip self-links, de-duplicate). May be partial
        // during the initial full build; recompute_backlinks fixes it up.
        let (outgoing, unresolved) = self.resolve_targets(path, &link_targets);

        // Tags.
        for t in &tags {
            self.by_tag
                .entry(t.clone())
                .or_default()
                .insert(path.to_path_buf());
        }

        if let Some(meta) = self.notes.get_mut(path) {
            meta.outgoing = outgoing;
            meta.unresolved = unresolved;
        }
    }

    /// Resolve a note's raw link targets into (outgoing paths, unresolved names),
    /// skipping self-links and duplicates. Folder context is preserved (a
    /// `Folder/B` target won't collapse to a bare `B`).
    fn resolve_targets(&self, src: &Path, targets: &[String]) -> (Vec<PathBuf>, Vec<String>) {
        let mut resolved: Vec<PathBuf> = Vec::new();
        let mut unresolved: Vec<String> = Vec::new();
        for target in targets {
            if let Some(p) = self.resolve(src, target) {
                if p.as_path() != src && !resolved.contains(&p) {
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
        let paths: Vec<PathBuf> = self.notes.keys().cloned().collect();
        for src in &paths {
            // Re-resolve from the raw targets now that every note is indexed.
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

    fn resolve_internal(&self, target: &str) -> Option<PathBuf> {
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

    /// Resolve a wikilink target to a concrete path inside the vault.
    /// Accepts `Name`, `Folder/Name`, with optional `.md` extension.
    pub fn resolve(&self, _root: &Path, target: &str) -> Option<PathBuf> {
        let cleaned = target
            .trim()
            .trim_end_matches(".md")
            .trim_end_matches(".markdown")
            .trim_end_matches(".mdx");
        self.resolve_internal(cleaned)
    }

    pub fn backlinks_for(&self, path: &Path) -> Vec<PathBuf> {
        self.backlinks.get(path).cloned().unwrap_or_default()
    }

    pub fn all_tags(&self) -> Vec<(String, usize)> {
        self.by_tag
            .iter()
            .map(|(t, set)| (t.clone(), set.len()))
            .collect()
    }

    pub fn notes_with_tag(&self, tag: &str) -> Vec<PathBuf> {
        self.by_tag
            .get(tag)
            .map(|s| {
                let mut v: Vec<_> = s.iter().cloned().collect();
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
        let mut counts: HashMap<PathBuf, usize> = HashMap::new();
        for t in &meta.tags {
            if let Some(members) = self.by_tag.get(t) {
                for m in members {
                    if m.as_path() != path {
                        *counts.entry(m.clone()).or_insert(0) += 1;
                    }
                }
            }
        }
        let mut ranked: Vec<(PathBuf, usize)> = counts.into_iter().collect();
        // Most shared tags first; stable tiebreak by path for determinism.
        ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        ranked.into_iter().take(limit).map(|(p, _)| p).collect()
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
                v.retain(|s| s != path);
            }
        }

        // 2. Re-index the note's own metadata (tags/basename/relpath/outgoing),
        //    leaving its *inbound* backlinks (other notes → this note) intact.
        self.unindex_note_meta(path);
        self.ingest(root, path, content);

        // 3. Add the note's new outgoing edges back into the backlink map.
        let new_out = self
            .notes
            .get(path)
            .map(|m| m.outgoing.clone())
            .unwrap_or_default();
        for dst in &new_out {
            let v = self.backlinks.entry(dst.clone()).or_default();
            v.push(path.to_path_buf());
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
            v.retain(|p| p != path);
            if v.is_empty() {
                self.by_basename.remove(&basename);
            }
        }
        // Clear from by_relpath the matching entry (linear scan, vault not huge).
        let to_remove: Vec<String> = self
            .by_relpath
            .iter()
            .filter(|(_, v)| v.as_path() == path)
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
            v.retain(|p| p != path);
        }
    }

    /// All note paths in the vault, sorted by recency (most recent first).
    pub fn recent_notes(&self) -> Vec<(PathBuf, &NoteMeta)> {
        let mut all: Vec<_> = self.notes.iter().map(|(p, m)| (p.clone(), m)).collect();
        all.sort_by_key(|x| std::cmp::Reverse(x.1.mtime));
        all
    }

    /// All note paths sorted alphabetically.
    pub fn all_notes(&self) -> Vec<(PathBuf, &NoteMeta)> {
        let mut all: Vec<_> = self.notes.iter().map(|(p, m)| (p.clone(), m)).collect();
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
        assert_eq!(idx.notes.get(&a).unwrap().outgoing, vec![c.clone()]);

        let _ = fs::remove_dir_all(&root);
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
        let meta = idx.notes.get(&a).expect("A indexed");
        assert_eq!(
            meta.outgoing,
            vec![root.join("Folder/B.md")],
            "link to Folder/B should resolve to the nested note, not top-level B.md"
        );

        let _ = fs::remove_dir_all(&root);
    }
}
