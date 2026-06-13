//! Import a Notion "Export → Markdown & CSV" dump into the vault.
//!
//! Notion's markdown export is messy: every page/database/row file and folder
//! carries a ` <32-hex-id>` suffix, databases come as a `.csv` plus a sibling
//! folder of per-row `.md` pages, internal links are percent-encoded references
//! to those hash-suffixed filenames, and attachments live in per-page folders.
//!
//! This module cleans all of that into a tidy Obsidian/Onyx vault:
//! - strips the hash suffixes from every path component,
//! - rewrites internal `.md` links to `[[wikilinks]]` (attachment links keep a
//!   cleaned relative path),
//! - turns each CSV database into a folder with a `_schema.md` and injects the
//!   row's columns as YAML frontmatter on the matching row note (so Onyx's
//!   database views + properties block light up),
//! - copies attachments through with cleaned paths.
//!
//! Everything is create-only: a name collision keeps both (the incoming file is
//! suffixed ` (Notion)`), and nothing outside the destination folder is touched.
//!
//! Input is an **unzipped** export folder (Notion hands you a `.zip`; unzip it
//! first). The transformation helpers are pure and unit-tested; only
//! `import_export` touches the filesystem.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

use walkdir::WalkDir;

/// Summary of an import run.
#[derive(Debug, Default, Clone)]
pub struct ImportResult {
    pub notes: usize,
    pub databases: usize,
    pub attachments: usize,
    pub collisions: usize,
    pub dest: PathBuf,
}

// -----------------------------------------------------------------------------
// Filename cleaning
// -----------------------------------------------------------------------------

/// Strip a trailing ` <32 lowercase-hex>` Notion id from `s`, if present.
fn strip_trailing_hash(s: &str) -> &str {
    let bytes = s.as_bytes();
    if bytes.len() >= 33 && bytes[bytes.len() - 33] == b' ' {
        let tail = &s[s.len() - 32..];
        if tail
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return &s[..s.len() - 33];
        }
    }
    s
}

/// Clean one path component: drop the Notion id, preserving a file extension.
pub fn clean_component(comp: &str) -> String {
    // Treat the part after the last dot as an extension only if it's short and
    // space-free (so "My Notes" stays whole but "Page abc….md" loses the id).
    if let Some(dot) = comp.rfind('.') {
        let ext = &comp[dot + 1..];
        if !ext.is_empty() && ext.len() <= 8 && !ext.contains(' ') {
            return format!("{}.{}", strip_trailing_hash(&comp[..dot]), ext);
        }
    }
    strip_trailing_hash(comp).to_string()
}

/// Clean every component of a relative path.
fn clean_relpath(rel: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in rel.components() {
        out.push(clean_component(&comp.as_os_str().to_string_lossy()));
    }
    out
}

// -----------------------------------------------------------------------------
// Link rewriting
// -----------------------------------------------------------------------------

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn has_scheme(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    ["http://", "https://", "mailto:", "data:", "tel:", "ftp://"]
        .iter()
        .any(|p| lower.starts_with(p))
}

/// Rewrite Notion-export links in a markdown body:
/// - internal `.md` links → `[[CleanStem]]` (or `[[CleanStem|text]]`),
/// - other relative links/images → cleaned, decoded relative path,
/// - web/mailto links → unchanged.
pub fn rewrite_links(md: &str) -> String {
    let re = link_re();
    re.replace_all(md, |caps: &regex::Captures| {
        let bang = caps.get(1).map(|m| m.as_str()).unwrap_or("");
        let text = caps.get(2).map(|m| m.as_str()).unwrap_or("");
        let dest_raw = caps.get(3).map(|m| m.as_str()).unwrap_or("");
        if has_scheme(dest_raw) {
            return caps.get(0).unwrap().as_str().to_string();
        }
        let decoded = percent_decode(dest_raw);
        // Drop any #block-id anchor.
        let path_part = decoded.split('#').next().unwrap_or(&decoded);
        let is_md = path_part
            .rsplit('.')
            .next()
            .map(|e| e.eq_ignore_ascii_case("md"))
            .unwrap_or(false);

        if bang.is_empty() && is_md {
            // Internal page link → wikilink to the cleaned final stem.
            let last = path_part.rsplit('/').next().unwrap_or(path_part);
            let cleaned = clean_component(last);
            let stem = cleaned.strip_suffix(".md").unwrap_or(&cleaned);
            if text.is_empty() || text == stem {
                format!("[[{stem}]]")
            } else {
                format!("[[{stem}|{text}]]")
            }
        } else {
            // Attachment / image / other relative link → cleaned relative path.
            let cleaned = clean_relpath(Path::new(path_part));
            let cleaned = cleaned.to_string_lossy().replace('\\', "/");
            format!("{bang}[{text}]({cleaned})")
        }
    })
    .into_owned()
}

fn link_re() -> &'static regex::Regex {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(!?)\[([^\]]*)\]\(([^)\s]+)\)").unwrap())
}

// -----------------------------------------------------------------------------
// CSV
// -----------------------------------------------------------------------------

/// Minimal RFC-4180 CSV parser (quoted fields, `""` escapes, embedded
/// commas/newlines, CRLF). Returns rows of fields; the first row is the header.
pub fn parse_csv(content: &str) -> Vec<Vec<String>> {
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut field = String::new();
    let mut record: Vec<String> = Vec::new();
    let mut in_quotes = false;
    let mut chars = content.chars().peekable();

    while let Some(c) = chars.next() {
        if in_quotes {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    field.push('"');
                    chars.next();
                } else {
                    in_quotes = false;
                }
            } else {
                field.push(c);
            }
        } else {
            match c {
                '"' => in_quotes = true,
                ',' => record.push(std::mem::take(&mut field)),
                '\r' => {}
                '\n' => {
                    record.push(std::mem::take(&mut field));
                    rows.push(std::mem::take(&mut record));
                }
                _ => field.push(c),
            }
        }
    }
    // Trailing field/record (file without a final newline).
    if !field.is_empty() || !record.is_empty() {
        record.push(field);
        rows.push(record);
    }
    rows
}

/// YAML frontmatter for a database row: `source: notion` plus one key per
/// non-empty column (the title column is skipped — it's the note's heading).
/// Multi-value cells (`a, b`) become inline lists.
fn csv_row_frontmatter(headers: &[String], row: &[String], title_col: usize) -> String {
    let mut out = String::from("---\nsource: notion\n");
    for (i, h) in headers.iter().enumerate() {
        if i == title_col {
            continue;
        }
        let val = row.get(i).map(|s| s.trim()).unwrap_or("");
        if val.is_empty() || h.trim().is_empty() {
            continue;
        }
        let key = h.trim();
        if val.contains(", ") {
            let parts: Vec<String> = val.split(", ").map(yaml_scalar).collect();
            out.push_str(&format!("{key}: [{}]\n", parts.join(", ")));
        } else {
            out.push_str(&format!("{key}: {}\n", yaml_scalar(val)));
        }
    }
    out.push_str("---\n\n");
    out
}

/// Quote a YAML scalar when it contains characters that would confuse the parser.
fn yaml_scalar(s: &str) -> String {
    let s = s.trim();
    let needs_quote = s.is_empty()
        || s.contains([':', '#', '[', ']', '{', '}', ',', '"', '\''])
        || s.starts_with(['-', '?', '&', '*', '!', '|', '>', '@', '`'])
        || s.parse::<f64>().is_err() && (s == "true" || s == "false" || s == "null");
    if needs_quote {
        format!("\"{}\"", s.replace('"', "\\\""))
    } else {
        s.to_string()
    }
}

// -----------------------------------------------------------------------------
// Import driver
// -----------------------------------------------------------------------------

/// Return `dest`, or a ` (Notion)`-suffixed sibling if it already exists.
fn collision_free(dest: &Path) -> (PathBuf, bool) {
    if !dest.exists() {
        return (dest.to_path_buf(), false);
    }
    let stem = dest.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let ext = dest.extension().map(|s| format!(".{}", s.to_string_lossy())).unwrap_or_default();
    let parent = dest.parent().unwrap_or_else(|| Path::new("."));
    let mut n = 1;
    loop {
        let name = if n == 1 {
            format!("{stem} (Notion){ext}")
        } else {
            format!("{stem} (Notion {n}){ext}")
        };
        let cand = parent.join(name);
        if !cand.exists() {
            return (cand, true);
        }
        n += 1;
    }
}

fn write_create_only(dest: &Path, content: &str, result: &mut ImportResult) -> io::Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let (target, collided) = collision_free(dest);
    if collided {
        result.collisions += 1;
    }
    std::fs::write(target, content)
}

/// Per-database info gathered in pass 1: the column headers, the title column
/// index, and a map from row title → that row's fields.
struct DbInfo {
    headers: Vec<String>,
    title_col: usize,
    rows: HashMap<String, Vec<String>>,
}

/// Import an unzipped Notion export at `src_root` into `dest_root`.
pub fn import_export(src_root: &Path, dest_root: &Path) -> io::Result<ImportResult> {
    let mut result = ImportResult {
        dest: dest_root.to_path_buf(),
        ..Default::default()
    };

    // Pass 1: CSV databases → schema files + a row→frontmatter map keyed by the
    // database's destination folder.
    let mut dbs: HashMap<PathBuf, DbInfo> = HashMap::new();
    for entry in WalkDir::new(src_root).into_iter().flatten() {
        let path = entry.path();
        if !path.is_file() || !has_ext(path, "csv") {
            continue;
        }
        let Ok(rel) = path.strip_prefix(src_root) else {
            continue;
        };
        let content = std::fs::read_to_string(path).unwrap_or_default();
        let rows = parse_csv(&content);
        if rows.len() < 2 {
            continue;
        }
        let headers = rows[0].clone();
        // The CSV's destination folder = sibling folder named like the CSV stem.
        let cleaned = clean_relpath(rel);
        let db_dir = dest_root.join(cleaned.with_extension(""));
        // Schema note.
        let mut schema = String::from("---\nsource: notion\n---\n\n# Schema\n\nColumns:\n");
        for h in &headers {
            if !h.trim().is_empty() {
                schema.push_str(&format!("- {}\n", h.trim()));
            }
        }
        schema.push_str(&format!("\n{} rows.\n", rows.len() - 1));
        write_create_only(&db_dir.join("_schema.md"), &schema, &mut result)?;

        let mut row_map = HashMap::new();
        for row in &rows[1..] {
            if let Some(title) = row.first() {
                if !title.trim().is_empty() {
                    row_map.insert(title.trim().to_string(), row.clone());
                }
            }
        }
        dbs.insert(
            db_dir,
            DbInfo {
                headers,
                title_col: 0,
                rows: row_map,
            },
        );
        result.databases += 1;
    }

    // Pass 2: markdown notes (link-rewritten, frontmatter-injected) + attachments.
    for entry in WalkDir::new(src_root).into_iter().flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Ok(rel) = path.strip_prefix(src_root) else {
            continue;
        };
        if has_ext(path, "csv") {
            continue; // handled in pass 1
        }
        let dest = dest_root.join(clean_relpath(rel));

        if has_ext(path, "md") {
            let raw = std::fs::read_to_string(path).unwrap_or_default();
            let mut body = rewrite_links(&raw);
            // If this note is a row of a known database, prepend its frontmatter.
            if let Some(parent) = dest.parent() {
                if let Some(db) = dbs.get(parent) {
                    let stem = dest
                        .file_stem()
                        .map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_default();
                    if let Some(row) = db.rows.get(&stem) {
                        let fm = csv_row_frontmatter(&db.headers, row, db.title_col);
                        body = format!("{fm}{body}");
                    }
                }
            }
            write_create_only(&dest, &body, &mut result)?;
            result.notes += 1;
        } else {
            // Attachment / other binary: copy through with the cleaned path.
            if let Some(parent) = dest.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let (target, collided) = collision_free(&dest);
            if collided {
                result.collisions += 1;
            }
            std::fs::copy(path, target)?;
            result.attachments += 1;
        }
    }

    Ok(result)
}

fn has_ext(path: &Path, ext: &str) -> bool {
    path.extension()
        .map(|e| e.to_string_lossy().eq_ignore_ascii_case(ext))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_hash_suffixes() {
        assert_eq!(
            clean_component("My Page 0123456789abcdef0123456789abcdef.md"),
            "My Page.md"
        );
        assert_eq!(
            clean_component("Some DB 0123456789abcdef0123456789abcdef"),
            "Some DB"
        );
        // No hash → unchanged.
        assert_eq!(clean_component("Plain Note.md"), "Plain Note.md");
        assert_eq!(clean_component("Folder Name"), "Folder Name");
        // Uppercase / wrong length is not a Notion id.
        assert_eq!(
            clean_component("Keep 0123456789ABCDEF0123456789abcdef.md"),
            "Keep 0123456789ABCDEF0123456789abcdef.md"
        );
    }

    #[test]
    fn rewrites_internal_links_to_wikilinks() {
        let md = "See [Meeting Notes](Meeting%20Notes%200123456789abcdef0123456789abcdef.md) today.";
        assert_eq!(rewrite_links(md), "See [[Meeting Notes]] today.");

        // Aliased link (text differs from target).
        let md = "[click here](Page%20Title%200123456789abcdef0123456789abcdef.md)";
        assert_eq!(rewrite_links(md), "[[Page Title|click here]]");

        // Web link untouched.
        let md = "[site](https://example.com/x)";
        assert_eq!(rewrite_links(md), "[site](https://example.com/x)");

        // Image attachment → cleaned relative path, kept as an image.
        let md = "![](Page%200123456789abcdef0123456789abcdef/photo.png)";
        assert_eq!(rewrite_links(md), "![](Page/photo.png)");
    }

    #[test]
    fn parses_quoted_csv() {
        let csv = "Name,Type,Notes\nClaude,Wants,\"a, b\"\n\"Quote \"\"x\"\"\",Needs,\n";
        let rows = parse_csv(csv);
        assert_eq!(rows[0], vec!["Name", "Type", "Notes"]);
        assert_eq!(rows[1], vec!["Claude", "Wants", "a, b"]);
        assert_eq!(rows[2], vec!["Quote \"x\"", "Needs", ""]);
    }

    #[test]
    fn builds_frontmatter_skipping_title_and_empties() {
        let headers = vec!["Name".into(), "Type".into(), "Amount".into(), "Tags".into()];
        let row = vec!["Claude".into(), "Wants".into(), "20".into(), "a, b".into()];
        let fm = csv_row_frontmatter(&headers, &row, 0);
        assert!(fm.starts_with("---\nsource: notion\n"));
        assert!(fm.contains("Type: Wants\n"));
        assert!(fm.contains("Amount: 20\n"));
        assert!(fm.contains("Tags: [a, b]\n"));
        assert!(!fm.contains("Name:"), "title column excluded: {fm}");
    }

    #[test]
    fn end_to_end_import(/* filesystem */) {
        let root = std::env::temp_dir().join(format!("onyx-nimport-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let src = root.join("export");
        let dest = root.join("vault/Notion Import");
        let hash = "0123456789abcdef0123456789abcdef";
        let hash2 = "abcdef0123456789abcdef0123456789";

        // A plain page that links to a database row.
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(
            src.join(format!("Home {hash}.md")),
            format!("# Home\n\nBudget: [Claude](Expenses%20{hash}/Claude%20{hash2}.md)\n"),
        )
        .unwrap();
        // A database: CSV + a folder of row pages.
        std::fs::write(
            src.join(format!("Expenses {hash}.csv")),
            "Name,Type,Amount\nClaude,Wants,20\n",
        )
        .unwrap();
        let db_dir = src.join(format!("Expenses {hash}"));
        std::fs::create_dir_all(&db_dir).unwrap();
        std::fs::write(db_dir.join(format!("Claude {hash2}.md")), "# Claude\n\nsubscription\n").unwrap();

        let res = import_export(&src, &dest).unwrap();
        assert_eq!(res.databases, 1);
        assert!(res.notes >= 2);

        // Home note: link rewritten to a wikilink.
        let home = std::fs::read_to_string(dest.join("Home.md")).unwrap();
        assert!(home.contains("[[Claude]]"), "link rewritten: {home}");

        // Row note: frontmatter injected from the CSV, body preserved.
        let claude = std::fs::read_to_string(dest.join("Expenses/Claude.md")).unwrap();
        assert!(claude.contains("source: notion"), "frontmatter: {claude}");
        assert!(claude.contains("Type: Wants"));
        assert!(claude.contains("Amount: 20"));
        assert!(claude.contains("subscription"), "body kept: {claude}");

        // Schema written.
        assert!(dest.join("Expenses/_schema.md").exists());

        let _ = std::fs::remove_dir_all(&root);
    }
}
