//! Links between Scribe pages and the Electron vault's Markdown notes.
//!
//! A note links to a page by the page's id, so the link survives the page
//! being renamed or moved: `[[scribe:<id>|Title]]`, or a lassoed area of it,
//! `[[scribe:<id>#x,y,w,h|Title]]` in page units. A page links to a note the
//! way a note does, by typing `[[Note]]` in a text box or a table cell.

use std::fs;
use std::path::Path;

use serde::Serialize;

/// The prefix that marks a wikilink as pointing at a Scribe page.
pub const SCHEME: &str = "scribe:";

/// The targets of the `[[…]]` links in `text`, as written (the part before
/// any `|alias`), in order and without repeats.
pub fn wikilinks(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find("[[") {
        let after = &rest[open + 2..];
        let Some(close) = after.find("]]") else { break };
        let inner = &after[..close];
        // `[[a [[b]]` links b, as Electron's parser does.
        if let Some(nested) = inner.rfind("[[") {
            rest = &after[nested..];
            continue;
        }
        if !inner.contains(['[', ']', '\n']) {
            let target = inner.split('|').next().unwrap_or("").trim();
            if !target.is_empty() && !out.iter().any(|t| t == target) {
                out.push(target.to_string());
            }
        }
        rest = &after[close + 2..];
    }
    out
}

/// A note in the vault, as a page's "linked from" list shows it.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct NoteRef {
    /// Vault-relative, with forward slashes.
    pub path: String,
    /// The file name without `.md`, as Electron's graph labels notes.
    pub title: String,
}

/// The Markdown notes in `vault` that link to the page with `page_id`,
/// sorted by path. Hidden folders (`.trash`, `.onyx`, …) are skipped.
pub fn notes_linking_to(vault: &Path, page_id: &str) -> Vec<NoteRef> {
    let needle = format!("{SCHEME}{page_id}");
    let mut out = Vec::new();
    let mut stack = vec![vault.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == "node_modules" {
                continue;
            }
            let path = entry.path();
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                stack.push(path);
                continue;
            }
            let lower = name.to_ascii_lowercase();
            if !(lower.ends_with(".md") || lower.ends_with(".markdown")) {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else { continue };
            if !text.contains(&needle) {
                continue;
            }
            let links = wikilinks(&text);
            let hit = links.iter().any(|t| {
                t.strip_prefix(SCHEME)
                    .map(|rest| rest.split('#').next().unwrap_or("").trim() == page_id)
                    .unwrap_or(false)
            });
            if hit {
                let rel = path.strip_prefix(vault).unwrap_or(&path).to_string_lossy().replace('\\', "/");
                let title = Path::new(&rel).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                out.push(NoteRef { path: rel, title });
            }
        }
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_targets_without_aliases_or_repeats() {
        let text = "See [[Eigenvalues]] and [[Linear maps|maps]], [[Eigenvalues]] again,\n\
                    [[scribe:abc#1,2,3,4|Tutorials]] and [[]] and [[a\nb]].";
        assert_eq!(wikilinks(text), vec!["Eigenvalues", "Linear maps", "scribe:abc#1,2,3,4"]);
    }

    #[test]
    fn a_stray_opening_takes_the_inner_link() {
        assert_eq!(wikilinks("[[a [[b]] c"), vec!["b"]);
        assert_eq!(wikilinks("no links [[here"), Vec::<String>::new());
    }
}
