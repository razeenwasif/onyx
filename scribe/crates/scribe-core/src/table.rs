//! Table clipboard formats: HTML, Markdown, TSV and CSV in; TSV, HTML and
//! Markdown out.

use std::sync::OnceLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ParsedTable {
    pub rows: Vec<Vec<String>>,
    #[serde(rename = "hasHeader")]
    pub has_header: bool,
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("static regex"))
}

/// Pulls the first table out of an HTML fragment, as spreadsheets and web
/// pages put on the pasteboard.
pub fn parse_html(html: &str) -> Option<ParsedTable> {
    static TR: OnceLock<Regex> = OnceLock::new();
    static CELL: OnceLock<Regex> = OnceLock::new();
    static TAG: OnceLock<Regex> = OnceLock::new();
    static BR: OnceLock<Regex> = OnceLock::new();

    let tr = re(&TR, r"(?is)<tr[^>]*>(.*?)</tr\s*>");
    let cell = re(&CELL, r"(?is)<(t[hd])(?:\s[^>]*)?>(.*?)</t[hd]\s*>");
    let tag = re(&TAG, r"(?s)<[^>]+>");
    let br = re(&BR, r"(?i)<br\s*/?>");

    let mut rows = Vec::new();
    let mut has_header = false;

    for (r, m) in tr.captures_iter(html).enumerate() {
        let mut row = Vec::new();
        for (c, cm) in cell.captures_iter(&m[1]).enumerate() {
            if r == 0 && c == 0 && cm[1].eq_ignore_ascii_case("th") {
                has_header = true;
            }
            let text = br.replace_all(&cm[2], " ");
            let text = tag.replace_all(&text, "");
            let text = decode_entities(&text);
            row.push(text.split_whitespace().collect::<Vec<_>>().join(" "));
        }
        if !row.is_empty() {
            rows.push(row);
        }
    }

    if rows.is_empty() {
        return None;
    }
    pad(&mut rows);
    Some(ParsedTable { rows, has_header })
}

/// Recognises a Markdown pipe table, TSV, or simple CSV. Plain prose returns
/// `None`, so pasting a paragraph still makes a text box.
pub fn parse_text(text: &str) -> Option<ParsedTable> {
    let lines: Vec<&str> = text.lines().map(|l| l.trim_end_matches('\r')).filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() {
        return None;
    }

    if lines.len() >= 2 && lines[0].contains('|') && is_markdown_rule(lines[1]) {
        let mut rows: Vec<Vec<String>> = lines
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != 1)
            .map(|(_, l)| split_markdown_row(l))
            .filter(|r| !r.is_empty())
            .collect();
        if !rows.is_empty() {
            pad(&mut rows);
            return Some(ParsedTable { rows, has_header: true });
        }
    }

    // Tab-separated: what Numbers, Excel and most tables copy as plain text.
    if lines.iter().all(|l| l.contains('\t')) {
        let mut rows: Vec<Vec<String>> =
            lines.iter().map(|l| l.split('\t').map(|c| c.trim().to_string()).collect()).collect();
        pad(&mut rows);
        return Some(ParsedTable { rows, has_header: true });
    }

    // CSV only when the shape is unambiguous: several lines, each with the
    // same number of commas. Otherwise a sentence with a comma would turn
    // into a table.
    if lines.len() >= 2 {
        let commas = split_csv(lines[0]).len();
        if commas >= 2 && lines.iter().all(|l| split_csv(l).len() == commas) {
            let rows = lines.iter().map(|l| split_csv(l)).collect();
            return Some(ParsedTable { rows, has_header: true });
        }
    }

    None
}

fn is_markdown_rule(line: &str) -> bool {
    let t = line.trim();
    t.contains("---") && t.chars().all(|c| matches!(c, '|' | '-' | ':' | ' ' | '\t'))
}

fn split_markdown_row(line: &str) -> Vec<String> {
    let mut t = line.trim();
    t = t.strip_prefix('|').unwrap_or(t);
    t = t.strip_suffix('|').unwrap_or(t);

    // Honour escaped pipes inside cells.
    let mut cells = Vec::new();
    let mut cur = String::new();
    let mut chars = t.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'|') => {
                cur.push('|');
                chars.next();
            }
            '|' => cells.push(std::mem::take(&mut cur).trim().to_string()),
            _ => cur.push(c),
        }
    }
    cells.push(cur.trim().to_string());
    cells
}

/// Minimal RFC 4180 field splitting: quoted fields with doubled quotes.
fn split_csv(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, quoted) {
            ('"', true) if chars.peek() == Some(&'"') => {
                cur.push('"');
                chars.next();
            }
            ('"', _) => quoted = !quoted,
            (',', false) => out.push(std::mem::take(&mut cur).trim().to_string()),
            _ => cur.push(c),
        }
    }
    out.push(cur.trim().to_string());
    out
}

fn pad(rows: &mut [Vec<String>]) {
    let cols = rows.iter().map(|r| r.len()).max().unwrap_or(0);
    for r in rows.iter_mut() {
        r.resize(cols, String::new());
    }
}

pub fn to_tsv(rows: &[Vec<String>]) -> String {
    rows.iter()
        .map(|r| r.iter().map(|c| c.replace(['\t', '\n'], " ")).collect::<Vec<_>>().join("\t"))
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn to_html(rows: &[Vec<String>], has_header: bool) -> String {
    let mut s = String::from("<table>\n");
    for (i, r) in rows.iter().enumerate() {
        let tag = if i == 0 && has_header { "th" } else { "td" };
        s.push_str("  <tr>");
        for c in r {
            s.push_str(&format!("<{tag}>{}</{tag}>", encode_entities(c)));
        }
        s.push_str("</tr>\n");
    }
    s.push_str("</table>");
    s
}

pub fn to_markdown(rows: &[Vec<String>]) -> String {
    let Some(first) = rows.first() else { return String::new() };
    let cell = |c: &String| c.replace('|', "\\|").replace('\n', " ");
    let line = |r: &Vec<String>| format!("| {} |", r.iter().map(cell).collect::<Vec<_>>().join(" | "));

    let mut out = vec![line(first), format!("|{}|", vec![" --- "; first.len()].join("|"))];
    out.extend(rows.iter().skip(1).map(line));
    out.join("\n")
}

fn encode_entities(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn decode_entities(s: &str) -> String {
    static ENT: OnceLock<Regex> = OnceLock::new();
    let ent = re(&ENT, r"&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);");
    ent.replace_all(s, |c: &regex::Captures| {
        let name = &c[1];
        let decoded = if let Some(hex) = name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
            u32::from_str_radix(hex, 16).ok().and_then(char::from_u32)
        } else if let Some(dec) = name.strip_prefix('#') {
            dec.parse().ok().and_then(char::from_u32)
        } else {
            match name {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some(' '),
                _ => None,
            }
        };
        decoded.map(String::from).unwrap_or_else(|| c[0].to_string())
    })
    .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_table() {
        let md = "| Header 1 | Header 2 |\n| --- | --- |\n| Row 1 Col 1 | Row 1 Col 2 |\n| Row 2 Col 1 | Row 2 Col 2 |";
        let t = parse_text(md).unwrap();
        assert_eq!(t.rows.len(), 3);
        assert_eq!(t.rows[0][0], "Header 1");
        assert_eq!(t.rows[0][1], "Header 2");
        assert_eq!(t.rows[1][0], "Row 1 Col 1");
        assert_eq!(t.rows[2][1], "Row 2 Col 2");
        assert!(t.has_header);
    }

    #[test]
    fn tsv_table() {
        let t = parse_text("Name\tAge\tCity\r\nAlice\t30\tLondon\r\nBob\t25\tNew York").unwrap();
        assert_eq!(t.rows.len(), 3);
        assert_eq!(t.rows[1][1], "30");
        assert_eq!(t.rows[2][2], "New York");
    }

    #[test]
    fn csv_needs_a_consistent_shape() {
        assert!(parse_text("a,b,c\n1,2,3").is_some());
        assert!(parse_text("Hello, world.\nThis is prose").is_none());
        let t = parse_text("name,quote\nBob,\"Hi, there\"").unwrap();
        assert_eq!(t.rows[1][1], "Hi, there");
    }

    #[test]
    fn prose_is_not_a_table() {
        assert!(parse_text("Just a line of text").is_none());
        assert!(parse_text("").is_none());
    }

    #[test]
    fn html_table_with_header_and_entities() {
        let html = "<meta charset=utf-8><table><tr><th>Item</th><th>Price</th></tr>\
                    <tr><td><b>Fish &amp; chips</b></td><td>&#36;5</td></tr><tr><td>Tea</td></tr></table>";
        let t = parse_html(html).unwrap();
        assert!(t.has_header);
        assert_eq!(t.rows[1], vec!["Fish & chips", "$5"]);
        // Short rows are padded to the widest.
        assert_eq!(t.rows[2], vec!["Tea", ""]);
    }

    #[test]
    fn exports_round_trip() {
        let rows = vec![vec!["A|B".to_string(), "C".into()], vec!["1".into(), "2".into()]];
        assert_eq!(parse_text(&to_markdown(&rows)).unwrap().rows, rows);
        assert_eq!(parse_text(&to_tsv(&rows)).unwrap().rows, rows);
        assert_eq!(parse_html(&to_html(&rows, true)).unwrap().rows, rows);
    }
}
