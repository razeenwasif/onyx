//! Extract wikilinks and tags from raw markdown.
//!
//! Wikilinks: `[[Target]]`, `[[Target|Alias]]`, `[[Target#Heading]]`,
//!            `[[Target#Heading|Alias]]`, `[[Target^block]]`.
//! Tags: `#tag`, `#nested/tag`. Skipped inside code spans and fenced code blocks.

use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WikiLink {
    /// Full target with optional `#heading` and `^block` — without the alias.
    pub target: String,
    /// Optional display text after `|`.
    pub alias: Option<String>,
    /// Byte offset of the `[[` in the source.
    pub start: usize,
    /// Byte offset just past the `]]`.
    pub end: usize,
}

#[allow(dead_code)]
impl WikiLink {
    /// The note name (no `#` or `^` suffix).
    pub fn note_name(&self) -> &str {
        let s = self.target.as_str();
        let hash = s.find('#');
        let caret = s.find('^');
        let cut = match (hash, caret) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        };
        match cut {
            Some(i) => &s[..i],
            None => s,
        }
    }

    /// Best text to show in the rendered preview.
    pub fn display(&self) -> &str {
        self.alias.as_deref().unwrap_or(self.note_name())
    }
}

static WIKILINK_RE: OnceLock<Regex> = OnceLock::new();
static TAG_RE: OnceLock<Regex> = OnceLock::new();
static FENCE_RE: OnceLock<Regex> = OnceLock::new();
static MDLINK_RE: OnceLock<Regex> = OnceLock::new();

fn wikilink_re() -> &'static Regex {
    WIKILINK_RE.get_or_init(|| {
        // [[ ... ]] non-greedy, no newlines inside.
        Regex::new(r"\[\[([^\[\]\n]+?)\]\]").unwrap()
    })
}

fn mdlink_re() -> &'static Regex {
    MDLINK_RE.get_or_init(|| {
        // [label](dest) — label has no brackets/newlines, dest no ) or newline.
        // The label is allowed to be empty (e.g. image-ish `[](x)`).
        Regex::new(r"\[[^\]\n]*\]\(([^)\n]+)\)").unwrap()
    })
}

fn tag_re() -> &'static Regex {
    TAG_RE.get_or_init(|| {
        // #word, including nested/path tags. Must not be preceded by a word char
        // (so we don't pick up `id#anchor` or `<h1>`).
        Regex::new(r"(?:^|[^\w&])#([A-Za-z][\w/\-]*)").unwrap()
    })
}

fn fence_re() -> &'static Regex {
    FENCE_RE.get_or_init(|| Regex::new(r"(?m)^(?:```|~~~).*$").unwrap())
}

/// A list of (start, end) byte ranges inside `source` that should be ignored
/// (fenced code blocks and inline code spans).
fn excluded_ranges(source: &str) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();

    // Fenced code blocks: scan ``` lines, pair them up.
    let fences: Vec<_> = fence_re().find_iter(source).collect();
    let mut i = 0;
    while i + 1 < fences.len() {
        let open = &fences[i];
        let close = &fences[i + 1];
        ranges.push((open.start(), close.end()));
        i += 2;
    }
    if fences.len() % 2 == 1 {
        let open = &fences[fences.len() - 1];
        ranges.push((open.start(), source.len()));
    }

    // Inline code spans — naive: balanced backticks on a single line.
    let mut bytes = source.as_bytes().iter().enumerate();
    while let Some((idx, &b)) = bytes.next() {
        if b == b'`' && !in_range(idx, &ranges) {
            // Find matching closing backtick within the same line.
            let rest = &source[idx + 1..];
            if let Some(rel) = rest.find('`') {
                // Ensure no newline in between.
                if !rest[..rel].contains('\n') {
                    let end = idx + 1 + rel + 1;
                    ranges.push((idx, end));
                    // skip past it
                    for _ in 0..(end - idx - 1) {
                        bytes.next();
                    }
                }
            }
        }
    }

    ranges.sort_by_key(|r| r.0);
    ranges
}

fn in_range(pos: usize, ranges: &[(usize, usize)]) -> bool {
    ranges.iter().any(|&(a, b)| pos >= a && pos < b)
}

pub fn extract_links(source: &str) -> Vec<WikiLink> {
    let excluded = excluded_ranges(source);
    let mut out = Vec::new();
    for cap in wikilink_re().captures_iter(source) {
        let whole = cap.get(0).unwrap();
        if in_range(whole.start(), &excluded) {
            continue;
        }
        let inner = cap.get(1).unwrap().as_str();
        let (target, alias) = match inner.split_once('|') {
            Some((t, a)) => (t.trim().to_string(), Some(a.trim().to_string())),
            None => (inner.trim().to_string(), None),
        };
        if target.is_empty() {
            continue;
        }
        out.push(WikiLink {
            target,
            alias,
            start: whole.start(),
            end: whole.end(),
        });
    }
    out
}

/// Extract inline-markdown link targets `[text](dest)` that point at local
/// notes. Returns note targets (URL-decoded, extension and `#anchor` stripped)
/// suitable for `NoteIndex::resolve`. Web URLs, mailto:, and pure anchors are
/// skipped, as are links inside code.
pub fn extract_md_links(source: &str) -> Vec<String> {
    let excluded = excluded_ranges(source);
    let mut out = Vec::new();
    for cap in mdlink_re().captures_iter(source) {
        let whole = cap.get(0).unwrap();
        if in_range(whole.start(), &excluded) {
            continue;
        }
        let raw = cap.get(1).unwrap().as_str().trim();
        if let Some(target) = normalize_md_dest(raw) {
            out.push(target);
        }
    }
    out
}

/// Turn a raw markdown link destination into a resolvable note target, or
/// `None` if it isn't a local note link.
fn normalize_md_dest(raw: &str) -> Option<String> {
    // Markdown allows `(dest "title")` and `(<dest>)`.
    let mut dest = raw.split_whitespace().next().unwrap_or(raw);
    dest = dest.trim_start_matches('<').trim_end_matches('>');
    if dest.is_empty() {
        return None;
    }
    // Pure anchor (same-page) — not a note link.
    if dest.starts_with('#') {
        return None;
    }
    // Absolute URLs / non-file schemes (http:, https:, mailto:, tel:, ftp:, …).
    if has_uri_scheme(dest) {
        return None;
    }
    // Drop any `#heading` / `^block` suffix.
    let dest = dest
        .split('#')
        .next()
        .unwrap_or(dest)
        .split('^')
        .next()
        .unwrap_or(dest);
    let dest = percent_decode(dest);
    let dest = dest.trim();
    if dest.is_empty() {
        return None;
    }
    // Only treat markdown files as note links (skip images, PDFs, etc.),
    // and strip the extension so the result matches wikilink note names.
    let lower = dest.to_ascii_lowercase();
    let stem = if let Some(s) = lower.strip_suffix(".md") {
        &dest[..s.len()]
    } else if let Some(s) = lower.strip_suffix(".markdown") {
        &dest[..s.len()]
    } else if let Some(s) = lower.strip_suffix(".mdx") {
        &dest[..s.len()]
    } else {
        return None;
    };
    if stem.is_empty() {
        return None;
    }
    Some(stem.to_string())
}

/// True if `s` begins with a URI scheme like `http:`, `https:`, `mailto:`.
/// (A bare `C:` drive letter or a relative path with a colon won't match
/// because we require `scheme://` or a known prefix.)
fn has_uri_scheme(s: &str) -> bool {
    if let Some(idx) = s.find(':') {
        let scheme = &s[..idx];
        let is_scheme = !scheme.is_empty()
            && scheme.chars().next().unwrap().is_ascii_alphabetic()
            && scheme.chars().all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.');
        // Require it to look like a real scheme (length > 1) to avoid matching
        // a Windows drive letter "C:".
        return is_scheme && scheme.len() > 1;
    }
    false
}

/// Minimal percent-decoding (`%20` → space, etc.). Leaves malformed escapes
/// as-is.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
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

/// Extract tags from YAML frontmatter at the top of a note. Handles the common
/// Obsidian styles:
///
/// ```text
/// ---
/// tags:
///   - a
///   - b/c
/// ---
/// ```
/// and inline forms `tags: [a, b]`, `tags: a, b`, `tag: a`.
pub fn extract_frontmatter_tags(source: &str) -> Vec<String> {
    let mut out = Vec::new();
    let src = source.strip_prefix('\u{feff}').unwrap_or(source);
    let mut lines = src.lines();
    // Frontmatter must open with `---` on the very first line.
    if lines.next().map(|l| l.trim()) != Some("---") {
        return out;
    }
    // Collect frontmatter body up to the closing `---` / `...`.
    let mut fm: Vec<&str> = Vec::new();
    let mut closed = false;
    for line in lines {
        let t = line.trim();
        if t == "---" || t == "..." {
            closed = true;
            break;
        }
        fm.push(line);
    }
    if !closed {
        return out;
    }

    let mut i = 0;
    while i < fm.len() {
        let trimmed = fm[i].trim_start();
        let lower = trimmed.to_ascii_lowercase();
        let is_tags_key = lower.starts_with("tags:") || lower.starts_with("tag:");
        if is_tags_key {
            let colon = trimmed.find(':').unwrap();
            let value = trimmed[colon + 1..].trim();
            if !value.is_empty() {
                // Inline: `[a, b]`, `a, b`, or `a`.
                let cleaned = value.trim_start_matches('[').trim_end_matches(']');
                for part in cleaned.split(',') {
                    let t = clean_tag(part);
                    if !t.is_empty() {
                        out.push(t);
                    }
                }
            } else {
                // Block list: following indented `- value` lines.
                let mut j = i + 1;
                while j < fm.len() {
                    let lt = fm[j].trim_start();
                    if let Some(rest) = lt.strip_prefix('-') {
                        let t = clean_tag(rest);
                        if !t.is_empty() {
                            out.push(t);
                        }
                        j += 1;
                    } else {
                        break;
                    }
                }
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out.sort();
    out.dedup();
    out
}

/// All tags for a note: inline `#tags` plus YAML frontmatter `tags:`.
pub fn extract_all_tags(source: &str) -> Vec<String> {
    let mut t = extract_tags(source);
    t.extend(extract_frontmatter_tags(source));
    t.sort();
    t.dedup();
    t
}

fn clean_tag(s: &str) -> String {
    s.trim()
        .trim_matches('"')
        .trim_matches('\'')
        .trim_start_matches('#')
        .trim()
        .to_string()
}

pub fn extract_tags(source: &str) -> Vec<String> {
    let excluded = excluded_ranges(source);
    let mut out = Vec::new();
    for cap in tag_re().captures_iter(source) {
        let whole = cap.get(0).unwrap();
        if in_range(whole.start(), &excluded) {
            continue;
        }
        if let Some(m) = cap.get(1) {
            out.push(m.as_str().to_string());
        }
    }
    out.sort();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_wikilink() {
        let links = extract_links("see [[Foo Bar]] please");
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].target, "Foo Bar");
        assert_eq!(links[0].alias, None);
    }

    #[test]
    fn parses_aliased_link() {
        let links = extract_links("[[Foo|the foo]]");
        assert_eq!(links[0].target, "Foo");
        assert_eq!(links[0].alias.as_deref(), Some("the foo"));
    }

    #[test]
    fn note_name_strips_heading() {
        let links = extract_links("[[Note#Heading]]");
        assert_eq!(links[0].note_name(), "Note");
    }

    #[test]
    fn ignores_links_in_code_blocks() {
        let src = "```\n[[Foo]]\n```\n[[Bar]]";
        let links = extract_links(src);
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].target, "Bar");
    }

    #[test]
    fn extracts_tags() {
        let tags = extract_tags("#one some #two/nested then #three not-a-tag #");
        assert_eq!(tags, vec!["one", "three", "two/nested"]);
    }

    #[test]
    fn skips_tags_in_code() {
        let tags = extract_tags("`#nope` and #yes");
        assert_eq!(tags, vec!["yes"]);
    }

    #[test]
    fn md_link_simple() {
        let links = extract_md_links("see [the note](Foo.md) here");
        assert_eq!(links, vec!["Foo"]);
    }

    #[test]
    fn md_link_percent_decoded_and_subpath() {
        let links = extract_md_links("[x](Sub/My%20Note.md)");
        assert_eq!(links, vec!["Sub/My Note"]);
    }

    #[test]
    fn md_link_strips_anchor() {
        let links = extract_md_links("[x](Note.md#Heading)");
        assert_eq!(links, vec!["Note"]);
    }

    #[test]
    fn md_link_skips_web_and_anchors() {
        let links = extract_md_links(
            "[a](https://example.com/x.md) [b](#section) [c](mailto:a@b.md)",
        );
        assert!(links.is_empty());
    }

    #[test]
    fn md_link_skips_non_markdown() {
        let links = extract_md_links("[img](pic.png) [pdf](doc.pdf)");
        assert!(links.is_empty());
    }

    #[test]
    fn md_link_ignored_in_code() {
        let links = extract_md_links("```\n[x](Foo.md)\n```\n[y](Bar.md)");
        assert_eq!(links, vec!["Bar"]);
    }

    #[test]
    fn frontmatter_block_list_tags() {
        let src = "---\ntags:\n  - ML/quantization\n  - physics/gw\n---\n# Body\n";
        let tags = extract_frontmatter_tags(src);
        assert_eq!(tags, vec!["ML/quantization", "physics/gw"]);
    }

    #[test]
    fn frontmatter_inline_array_tags() {
        let src = "---\ntags: [a, b/c, d]\n---\n";
        let tags = extract_frontmatter_tags(src);
        assert_eq!(tags, vec!["a", "b/c", "d"]);
    }

    #[test]
    fn frontmatter_single_tag_and_quotes() {
        let src = "---\ntag: \"alpha\"\n---\n";
        assert_eq!(extract_frontmatter_tags(src), vec!["alpha"]);
    }

    #[test]
    fn no_frontmatter_no_tags() {
        assert!(extract_frontmatter_tags("# just a note\ntags: not-frontmatter").is_empty());
    }

    #[test]
    fn all_tags_combines_inline_and_frontmatter() {
        let src = "---\ntags:\n  - fm\n---\nbody with #inline tag";
        let tags = extract_all_tags(src);
        assert!(tags.contains(&"fm".to_string()));
        assert!(tags.contains(&"inline".to_string()));
    }

    #[test]
    fn md_link_not_confused_by_wikilink() {
        // `[[Foo]]` should not be parsed as a markdown link.
        let links = extract_md_links("[[Foo]] and [real](Bar.md)");
        assert_eq!(links, vec!["Bar"]);
    }
}
