//! Nested-structure navigation (Notion-hybrid Phase 3).
//!
//! Maps the vault's folder hierarchy onto a Notion-style *page tree*: a folder's
//! "page" is its namesake note (`Foo/Foo.md`), else its database page
//! (`Foo/_schema.md`), else its first contained note. From an open note we can
//! then offer a breadcrumb trail, jump to the parent page, and list the parent /
//! sibling / child pages for keyboard navigation (the "Pages" sidebar tab).
//!
//! Pure functions over `FileTree` + paths — no UI, fully unit-tested.

use std::path::{Path, PathBuf};

use crate::vault::tree::FileTree;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageKind {
    /// Leave the current folder for its parent page.
    Up,
    /// A child folder (opens that folder's representative page).
    Folder,
    /// A note in the current folder.
    Note,
}

/// One navigable row in the Pages tab.
#[derive(Debug, Clone)]
pub struct PageEntry {
    pub kind: PageKind,
    pub label: String,
    /// The note this row opens.
    pub target: PathBuf,
    /// True for the currently-open note (so the UI can mark "you are here").
    pub is_current: bool,
}

/// The note that represents a folder as a "page": its namesake (`Foo/Foo.md`),
/// else its database page (`Foo/_schema.md`), else the first note directly in it.
pub fn representative_note(tree: &FileTree, folder: &Path) -> Option<PathBuf> {
    let node = tree.node_at(folder)?;
    let name = folder.file_name()?.to_string_lossy().to_string();
    let namesake = folder.join(format!("{name}.md"));
    if node.children.iter().any(|c| !c.is_dir && c.path == namesake) {
        return Some(namesake);
    }
    let schema = folder.join("_schema.md");
    if node.children.iter().any(|c| !c.is_dir && c.path == schema) {
        return Some(schema);
    }
    node.children
        .iter()
        .find(|c| !c.is_dir)
        .map(|c| c.path.clone())
}

/// The page "above" `current`: from a folder's representative note this is the
/// grandparent folder's page; from any other note it's the note's own folder's
/// page. `None` at the top of the tree.
pub fn parent_page(tree: &FileTree, root: &Path, current: &Path) -> Option<PathBuf> {
    let dir = current.parent()?;
    let rep = representative_note(tree, dir);
    // If `current` already represents `dir`, go up another level.
    let target_dir = if rep.as_deref() == Some(current) {
        dir.parent()?
    } else {
        dir
    };
    if target_dir == root || tree.node_at(target_dir).is_none() {
        // Going up would land at the rootless vault — only valid if it has a page.
        if target_dir == root {
            return representative_note(tree, root).filter(|p| p != current);
        }
        return None;
    }
    representative_note(tree, target_dir).filter(|p| p != current)
}

/// Build the Pages-tab rows for `current`: an optional "↑ parent" entry, then the
/// child folders and notes of the current note's folder (folders first, matching
/// the tree's own ordering).
pub fn page_entries(tree: &FileTree, root: &Path, current: &Path) -> Vec<PageEntry> {
    let mut out = Vec::new();
    let Some(dir) = current.parent() else {
        return out;
    };

    // Up entry — only when the parent folder is a real folder with a page (i.e.
    // not the rootless vault).
    if let Some(pdir) = dir.parent() {
        if pdir != root && tree.node_at(pdir).is_some() {
            if let Some(target) = representative_note(tree, pdir) {
                let label = pdir
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| "..".to_string());
                out.push(PageEntry {
                    kind: PageKind::Up,
                    label: format!("↑ {label}"),
                    target,
                    is_current: false,
                });
            }
        }
    }

    let Some(node) = tree.node_at(dir) else {
        return out;
    };
    for child in &node.children {
        if child.is_dir {
            if let Some(target) = representative_note(tree, &child.path) {
                out.push(PageEntry {
                    kind: PageKind::Folder,
                    label: format!("{}/", child.name),
                    target,
                    is_current: false,
                });
            }
        } else {
            let stem = child
                .path
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| child.name.clone());
            out.push(PageEntry {
                kind: PageKind::Note,
                label: stem,
                target: child.path.clone(),
                is_current: child.path == current,
            });
        }
    }
    out
}

/// Breadcrumb string for `current`, e.g. `Entertainment › Animes › Oshi no Ko`.
/// Trailing segments are kept whole; older ancestors are elided with `…` to fit
/// `max` display columns.
pub fn breadcrumb(root: &Path, current: &Path, max: usize) -> String {
    let parts: Vec<String> = match current.strip_prefix(root) {
        Ok(rel) => rel
            .components()
            .map(|c| c.as_os_str().to_string_lossy().to_string())
            .collect(),
        Err(_) => current
            .file_name()
            .map(|s| vec![s.to_string_lossy().to_string()])
            .unwrap_or_default(),
    };
    let mut parts = parts;
    if let Some(last) = parts.last_mut() {
        for ext in [".md", ".markdown", ".mdx"] {
            if let Some(stripped) = last.strip_suffix(ext) {
                *last = stripped.to_string();
                break;
            }
        }
    }
    join_breadcrumb(&parts, max)
}

const SEP: &str = " › ";

fn join_breadcrumb(parts: &[String], max: usize) -> String {
    if parts.is_empty() {
        return String::new();
    }
    let full = parts.join(SEP);
    if full.chars().count() <= max {
        return full;
    }
    // Single huge segment: hard-truncate with a trailing ellipsis.
    if parts.len() == 1 {
        let keep = max.saturating_sub(1).max(1);
        let t: String = parts[0].chars().take(keep).collect();
        return format!("{t}…");
    }
    // Keep the last segment whole, then prepend earlier segments while they fit;
    // mark the elision with a leading "… › ".
    let mut shown = parts[parts.len() - 1].clone();
    let mut i = parts.len() as i64 - 2;
    while i >= 0 {
        let cand = format!("{}{SEP}{shown}", parts[i as usize]);
        let prefix_cost = if i > 0 { SEP.chars().count() + 1 } else { 0 };
        if cand.chars().count() + prefix_cost <= max {
            shown = cand;
            i -= 1;
        } else {
            break;
        }
    }
    if i >= 0 {
        format!("…{SEP}{shown}")
    } else {
        shown
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn write(p: &Path, s: &str) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, s).unwrap();
    }

    /// Build a small vault mirroring the migrated Notion layout. `tag` makes the
    /// temp dir unique per test so parallel tests don't race on a shared path.
    fn sample_tree(tag: &str) -> (PathBuf, FileTree) {
        let root =
            std::env::temp_dir().join(format!("onyx-pagenav-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        // Entertainment/ (namesake page) with a sub-page-folder and a DB folder.
        write(&root.join("Entertainment/Entertainment.md"), "# Entertainment\n");
        write(&root.join("Entertainment/Pokemon Teams.md"), "# Pokemon\n");
        write(
            &root.join("Entertainment/Anime Watchlist - Tracker/Anime Watchlist - Tracker.md"),
            "# Anime\n",
        );
        write(
            &root.join("Entertainment/Anime Watchlist - Tracker/Animes/_schema.md"),
            "# schema\n",
        );
        write(
            &root.join("Entertainment/Anime Watchlist - Tracker/Animes/Oshi no Ko.md"),
            "# Oshi\n",
        );
        write(
            &root.join("Entertainment/Anime Watchlist - Tracker/Animes/One Piece.md"),
            "# OP\n",
        );
        let tree = FileTree::scan(&root);
        (root, tree)
    }

    #[test]
    fn representative_prefers_namesake_then_schema_then_first() {
        let (root, tree) = sample_tree("rep");
        // namesake
        assert_eq!(
            representative_note(&tree, &root.join("Entertainment")),
            Some(root.join("Entertainment/Entertainment.md"))
        );
        // _schema (Animes has no namesake note)
        assert_eq!(
            representative_note(
                &tree,
                &root.join("Entertainment/Anime Watchlist - Tracker/Animes")
            ),
            Some(root.join("Entertainment/Anime Watchlist - Tracker/Animes/_schema.md"))
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn page_entries_lists_up_folders_and_notes() {
        let (root, tree) = sample_tree("entries");
        let current = root.join("Entertainment/Anime Watchlist - Tracker/Animes/Oshi no Ko.md");
        let entries = page_entries(&tree, &root, &current);

        // First row is the Up entry to the parent page (Anime Watchlist - Tracker).
        assert_eq!(entries[0].kind, PageKind::Up);
        assert_eq!(
            entries[0].target,
            root.join("Entertainment/Anime Watchlist - Tracker/Anime Watchlist - Tracker.md")
        );
        // Then the notes in Animes/ (no subfolders here): _schema, One Piece, Oshi no Ko.
        let notes: Vec<&str> = entries
            .iter()
            .filter(|e| e.kind == PageKind::Note)
            .map(|e| e.label.as_str())
            .collect();
        assert_eq!(notes, vec!["_schema", "One Piece", "Oshi no Ko"]);
        // The current note is marked.
        assert!(entries.iter().any(|e| e.is_current && e.label == "Oshi no Ko"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn page_entries_shows_folders_for_a_parent_page() {
        let (root, tree) = sample_tree("folders");
        let current = root.join("Entertainment/Anime Watchlist - Tracker/Anime Watchlist - Tracker.md");
        let entries = page_entries(&tree, &root, &current);
        // Up → Entertainment page.
        assert_eq!(entries[0].kind, PageKind::Up);
        assert_eq!(
            entries[0].target,
            root.join("Entertainment/Entertainment.md")
        );
        // The Animes subfolder shows as a Folder entry opening its _schema page.
        let folder = entries.iter().find(|e| e.kind == PageKind::Folder).unwrap();
        assert_eq!(folder.label, "Animes/");
        assert_eq!(
            folder.target,
            root.join("Entertainment/Anime Watchlist - Tracker/Animes/_schema.md")
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn no_up_entry_for_a_top_level_folder() {
        let (root, tree) = sample_tree("topfolder");
        // A note whose folder (Entertainment) sits directly under the vault root
        // has no meaningful parent page → no Up entry.
        let current = root.join("Entertainment/Pokemon Teams.md");
        let entries = page_entries(&tree, &root, &current);
        assert!(entries.iter().all(|e| e.kind != PageKind::Up));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn parent_page_walks_up_through_representatives() {
        let (root, tree) = sample_tree("parent");
        // From a leaf note → its folder's page.
        let oshi = root.join("Entertainment/Anime Watchlist - Tracker/Animes/Oshi no Ko.md");
        assert_eq!(
            parent_page(&tree, &root, &oshi),
            Some(root.join("Entertainment/Anime Watchlist - Tracker/Animes/_schema.md"))
        );
        // From a folder's own page → the grandparent's page.
        let anime_page =
            root.join("Entertainment/Anime Watchlist - Tracker/Anime Watchlist - Tracker.md");
        assert_eq!(
            parent_page(&tree, &root, &anime_page),
            Some(root.join("Entertainment/Entertainment.md"))
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn breadcrumb_full_when_it_fits() {
        let parts = vec!["A".to_string(), "B".to_string(), "Note".to_string()];
        assert_eq!(join_breadcrumb(&parts, 80), "A › B › Note");
    }

    #[test]
    fn breadcrumb_elides_leading_segments_when_too_long() {
        let parts = vec![
            "Entertainment".to_string(),
            "Anime Watchlist - Tracker".to_string(),
            "Animes".to_string(),
            "Oshi no Ko".to_string(),
        ];
        let out = join_breadcrumb(&parts, 24);
        assert!(out.starts_with('…'), "expected elision, got {out:?}");
        assert!(out.ends_with("Oshi no Ko"), "tail kept whole, got {out:?}");
        assert!(out.chars().count() <= 24, "fits width, got {out:?}");
    }
}
