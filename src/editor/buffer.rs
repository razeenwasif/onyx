//! Simple line-based text buffer.
//!
//! Notes are rarely huge (10s of KB at most), so we don't need a rope.
//! `Vec<String>` keeps mutations cheap to reason about and trivially serializable.
//! Lines never contain `\n`.

use std::fmt;

use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Cursor {
    pub line: usize,
    /// Column measured in *grapheme clusters*, not bytes.
    pub col: usize,
}

impl Cursor {
    pub fn origin() -> Self {
        Cursor { line: 0, col: 0 }
    }
}

#[derive(Debug, Clone)]
pub struct Buffer {
    pub lines: Vec<String>,
    pub cursor: Cursor,
    /// Preferred column for vertical motion (sticky).
    pub goal_col: usize,
}

#[allow(dead_code)]
impl Buffer {
    pub fn from_string(s: String) -> Self {
        let mut lines: Vec<String> = if s.is_empty() {
            vec![String::new()]
        } else {
            s.split('\n').map(|s| s.trim_end_matches('\r').to_string()).collect()
        };
        if lines.is_empty() {
            lines.push(String::new());
        }
        Self {
            lines,
            cursor: Cursor::origin(),
            goal_col: 0,
        }
    }

    pub fn line(&self, i: usize) -> &str {
        self.lines.get(i).map(|s| s.as_str()).unwrap_or("")
    }

    pub fn line_count(&self) -> usize {
        self.lines.len()
    }

    pub fn line_len_graphemes(&self, i: usize) -> usize {
        self.line(i).graphemes(true).count()
    }

    pub fn current_line(&self) -> &str {
        self.line(self.cursor.line)
    }

    /// Convert grapheme col index in `line` to a byte index.
    pub fn col_to_byte(&self, line: usize, col: usize) -> usize {
        let s = self.line(line);
        let mut bytes = 0;
        for (i, g) in s.graphemes(true).enumerate() {
            if i == col {
                return bytes;
            }
            bytes += g.len();
        }
        s.len()
    }

    pub fn byte_to_col(&self, line: usize, byte: usize) -> usize {
        let s = self.line(line);
        let mut bytes = 0;
        for (i, g) in s.graphemes(true).enumerate() {
            if bytes >= byte {
                return i;
            }
            bytes += g.len();
        }
        s.graphemes(true).count()
    }

    pub fn display_col(&self, line: usize, col: usize) -> usize {
        let s = self.line(line);
        let mut w = 0;
        for (i, g) in s.graphemes(true).enumerate() {
            if i == col {
                return w;
            }
            w += UnicodeWidthStr::width(g);
        }
        w
    }

    pub fn clamp_cursor(&mut self) {
        if self.lines.is_empty() {
            self.lines.push(String::new());
        }
        if self.cursor.line >= self.lines.len() {
            self.cursor.line = self.lines.len() - 1;
        }
        let max = self.line_len_graphemes(self.cursor.line);
        if self.cursor.col > max {
            self.cursor.col = max;
        }
    }

    // ------------------------ motions ------------------------

    pub fn move_left(&mut self) {
        if self.cursor.col > 0 {
            self.cursor.col -= 1;
        } else if self.cursor.line > 0 {
            self.cursor.line -= 1;
            self.cursor.col = self.line_len_graphemes(self.cursor.line);
        }
        self.goal_col = self.cursor.col;
    }

    pub fn move_right(&mut self) {
        let max = self.line_len_graphemes(self.cursor.line);
        if self.cursor.col < max {
            self.cursor.col += 1;
        } else if self.cursor.line + 1 < self.lines.len() {
            self.cursor.line += 1;
            self.cursor.col = 0;
        }
        self.goal_col = self.cursor.col;
    }

    pub fn move_up(&mut self) {
        if self.cursor.line > 0 {
            self.cursor.line -= 1;
            let max = self.line_len_graphemes(self.cursor.line);
            self.cursor.col = self.goal_col.min(max);
        }
    }

    pub fn move_down(&mut self) {
        if self.cursor.line + 1 < self.lines.len() {
            self.cursor.line += 1;
            let max = self.line_len_graphemes(self.cursor.line);
            self.cursor.col = self.goal_col.min(max);
        }
    }

    pub fn move_line_start(&mut self) {
        self.cursor.col = 0;
        self.goal_col = 0;
    }

    pub fn move_line_end(&mut self) {
        self.cursor.col = self.line_len_graphemes(self.cursor.line);
        self.goal_col = self.cursor.col;
    }

    pub fn move_doc_start(&mut self) {
        self.cursor = Cursor::origin();
        self.goal_col = 0;
    }

    pub fn move_doc_end(&mut self) {
        self.cursor.line = self.lines.len().saturating_sub(1);
        self.cursor.col = self.line_len_graphemes(self.cursor.line);
        self.goal_col = self.cursor.col;
    }

    pub fn move_word_forward(&mut self) {
        let line = self.cursor.line;
        let s = self.line(line);
        let bytes = self.col_to_byte(line, self.cursor.col);
        let rest = &s[bytes..];
        // Skip current word, then skip whitespace.
        let mut idx = 0;
        let mut in_word = false;
        for (i, ch) in rest.char_indices() {
            if !in_word {
                if !ch.is_whitespace() {
                    in_word = true;
                }
            } else if ch.is_whitespace() {
                idx = i;
                break;
            }
            idx = i + ch.len_utf8();
        }
        // Skip trailing whitespace.
        let rest2 = &rest[idx..];
        let mut ws = 0;
        for (i, ch) in rest2.char_indices() {
            if !ch.is_whitespace() {
                ws = i;
                break;
            }
            ws = i + ch.len_utf8();
        }
        let new_byte = bytes + idx + ws;
        if new_byte >= s.len() && line + 1 < self.lines.len() {
            self.cursor.line += 1;
            self.cursor.col = 0;
        } else {
            self.cursor.col = self.byte_to_col(line, new_byte);
        }
        self.goal_col = self.cursor.col;
    }

    pub fn move_word_back(&mut self) {
        let line = self.cursor.line;
        let bytes = self.col_to_byte(line, self.cursor.col);
        let s = self.line(line);
        if bytes == 0 {
            if line > 0 {
                self.cursor.line -= 1;
                self.cursor.col = self.line_len_graphemes(self.cursor.line);
            }
            self.goal_col = self.cursor.col;
            return;
        }
        // Walk backward over whitespace, then over a word.
        let prefix = &s[..bytes];
        let chars: Vec<(usize, char)> = prefix.char_indices().collect();
        let mut i = chars.len();
        // skip trailing whitespace
        while i > 0 && chars[i - 1].1.is_whitespace() {
            i -= 1;
        }
        // skip word
        while i > 0 && !chars[i - 1].1.is_whitespace() {
            i -= 1;
        }
        let new_byte = if i == 0 { 0 } else { chars[i].0 };
        self.cursor.col = self.byte_to_col(line, new_byte);
        self.goal_col = self.cursor.col;
    }

    // ------------------------ editing ------------------------

    pub fn insert_char(&mut self, c: char) {
        let line = &mut self.lines[self.cursor.line];
        let byte = grapheme_to_byte(line, self.cursor.col);
        line.insert(byte, c);
        self.cursor.col += 1;
        self.goal_col = self.cursor.col;
    }

    pub fn insert_str(&mut self, s: &str) {
        for ch in s.chars() {
            if ch == '\n' {
                self.insert_newline();
            } else {
                self.insert_char(ch);
            }
        }
    }

    pub fn insert_newline(&mut self) {
        let line = self.lines[self.cursor.line].clone();
        let byte = grapheme_to_byte(&line, self.cursor.col);
        let (left, right) = line.split_at(byte);
        self.lines[self.cursor.line] = left.to_string();
        self.lines.insert(self.cursor.line + 1, right.to_string());
        self.cursor.line += 1;
        self.cursor.col = 0;
        self.goal_col = 0;
    }

    pub fn backspace(&mut self) {
        if self.cursor.col > 0 {
            let line = &mut self.lines[self.cursor.line];
            let byte_end = grapheme_to_byte(line, self.cursor.col);
            let byte_start = grapheme_to_byte(line, self.cursor.col - 1);
            line.replace_range(byte_start..byte_end, "");
            self.cursor.col -= 1;
        } else if self.cursor.line > 0 {
            let removed = self.lines.remove(self.cursor.line);
            self.cursor.line -= 1;
            self.cursor.col = self.line_len_graphemes(self.cursor.line);
            self.lines[self.cursor.line].push_str(&removed);
        }
        self.goal_col = self.cursor.col;
    }

    pub fn delete_forward(&mut self) {
        let line_len = self.line_len_graphemes(self.cursor.line);
        if self.cursor.col < line_len {
            let line = &mut self.lines[self.cursor.line];
            let bs = grapheme_to_byte(line, self.cursor.col);
            let be = grapheme_to_byte(line, self.cursor.col + 1);
            line.replace_range(bs..be, "");
        } else if self.cursor.line + 1 < self.lines.len() {
            let next = self.lines.remove(self.cursor.line + 1);
            self.lines[self.cursor.line].push_str(&next);
        }
    }

    pub fn delete_line(&mut self) -> String {
        if self.lines.is_empty() {
            return String::new();
        }
        if self.lines.len() == 1 {
            let removed = std::mem::take(&mut self.lines[0]);
            self.cursor.col = 0;
            return removed;
        }
        let removed = self.lines.remove(self.cursor.line);
        if self.cursor.line >= self.lines.len() {
            self.cursor.line = self.lines.len() - 1;
        }
        self.cursor.col = self.cursor.col.min(self.line_len_graphemes(self.cursor.line));
        removed
    }

    pub fn delete_to_eol(&mut self) -> String {
        let line = &mut self.lines[self.cursor.line];
        let bs = grapheme_to_byte(line, self.cursor.col);
        let removed = line[bs..].to_string();
        line.truncate(bs);
        removed
    }
}

impl fmt::Display for Buffer {
    /// Render the buffer back to a single string (lines joined by `\n`).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut first = true;
        for line in &self.lines {
            if !first {
                f.write_str("\n")?;
            }
            f.write_str(line)?;
            first = false;
        }
        Ok(())
    }
}

/// Convert grapheme column to byte index in a string slice.
pub fn grapheme_to_byte(s: &str, col: usize) -> usize {
    let mut bytes = 0;
    for (i, g) in s.graphemes(true).enumerate() {
        if i == col {
            return bytes;
        }
        bytes += g.len();
    }
    s.len()
}
