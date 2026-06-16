//! A single editable todo/reminder checklist, persisted to `.onyx/todos.md`
//! as an ordinary markdown checklist so it stays human-readable and portable.
//!
//! Completed items carry the date they were ticked in a trailing HTML comment
//! (`<!--done:YYYY-MM-DD-->`) — invisible in rendered markdown but enough to
//! group finished todos at the bottom and sweep them away a week later.

use std::fs;
use std::path::Path;

use chrono::{Local, NaiveDate};

/// How long a completed todo lingers (in the "done" group) before it's pruned.
pub const DONE_RETENTION_DAYS: i64 = 7;

#[derive(Debug, Clone)]
pub struct TodoItem {
    pub text: String,
    pub done: bool,
    /// The day this item was completed (used to expire it after a week). `None`
    /// while the item is open.
    pub done_on: Option<NaiveDate>,
}

#[derive(Debug, Default)]
pub struct TodoList {
    pub items: Vec<TodoItem>,
    pub selected: usize,
}

/// Pull a trailing `<!--done:YYYY-MM-DD-->` marker off a checklist line,
/// returning the cleaned text and the parsed date (if present and valid).
fn extract_done_date(text: &str) -> (String, Option<NaiveDate>) {
    if let Some(start) = text.rfind("<!--done:") {
        let after = &text[start + "<!--done:".len()..];
        if let Some(end) = after.find("-->") {
            if let Ok(d) = NaiveDate::parse_from_str(after[..end].trim(), "%Y-%m-%d") {
                return (text[..start].trim_end().to_string(), Some(d));
            }
        }
    }
    (text.trim().to_string(), None)
}

impl TodoList {
    pub fn load(path: &Path) -> Self {
        let today = Local::now().date_naive();
        let mut items = Vec::new();
        if let Ok(content) = fs::read_to_string(path) {
            for line in content.lines() {
                let t = line.trim_start();
                let (done, rest) = if let Some(r) = t
                    .strip_prefix("- [x] ")
                    .or_else(|| t.strip_prefix("- [X] "))
                {
                    (true, r)
                } else if let Some(r) = t.strip_prefix("- [ ] ") {
                    (false, r)
                } else {
                    continue;
                };
                if done {
                    let (text, date) = extract_done_date(rest);
                    items.push(TodoItem {
                        text,
                        done: true,
                        // Items ticked elsewhere (no marker) start their week now.
                        done_on: Some(date.unwrap_or(today)),
                    });
                } else {
                    items.push(TodoItem {
                        text: rest.trim().to_string(),
                        done: false,
                        done_on: None,
                    });
                }
            }
        }
        TodoList { items, selected: 0 }
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut out = String::from("# Todos\n\n");
        for it in &self.items {
            let mark = if it.done { "x" } else { " " };
            let suffix = match (it.done, it.done_on) {
                (true, Some(d)) => format!(" <!--done:{}-->", d.format("%Y-%m-%d")),
                _ => String::new(),
            };
            out.push_str(&format!("- [{mark}] {}{suffix}\n", it.text));
        }
        fs::write(path, out)
    }

    pub fn clamp(&mut self) {
        if self.selected >= self.items.len() {
            self.selected = self.items.len().saturating_sub(1);
        }
    }

    pub fn toggle(&mut self) {
        self.toggle_on(Local::now().date_naive());
    }

    /// Flip the selected item's done state, stamping/clearing its completion
    /// date. Unchecking returns it to the open group.
    pub fn toggle_on(&mut self, today: NaiveDate) {
        if let Some(it) = self.items.get_mut(self.selected) {
            it.done = !it.done;
            it.done_on = if it.done { Some(today) } else { None };
        }
    }

    /// Drop completed items finished more than [`DONE_RETENTION_DAYS`] ago.
    /// Returns true if anything was removed.
    pub fn prune_expired(&mut self, today: NaiveDate) -> bool {
        let before = self.items.len();
        self.items.retain(|it| match (it.done, it.done_on) {
            (true, Some(d)) => today.signed_duration_since(d).num_days() < DONE_RETENTION_DAYS,
            _ => true,
        });
        self.clamp();
        self.items.len() != before
    }

    pub fn add(&mut self, text: String) {
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        self.items.push(TodoItem {
            text,
            done: false,
            done_on: None,
        });
        self.selected = self.items.len() - 1;
    }

    pub fn edit_selected(&mut self, text: String) {
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        if let Some(it) = self.items.get_mut(self.selected) {
            it.text = text;
        }
    }

    pub fn delete_selected(&mut self) {
        if self.selected < self.items.len() {
            self.items.remove(self.selected);
            self.clamp();
        }
    }

    pub fn selected_text(&self) -> Option<&str> {
        self.items.get(self.selected).map(|i| i.text.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn extracts_done_marker_and_cleans_text() {
        let (text, date) = extract_done_date("Buy milk <!--done:2026-06-16-->");
        assert_eq!(text, "Buy milk");
        assert_eq!(date, Some(d("2026-06-16")));

        let (text, date) = extract_done_date("plain text");
        assert_eq!(text, "plain text");
        assert_eq!(date, None);
    }

    #[test]
    fn toggle_stamps_then_clears_completion_date() {
        let mut list = TodoList::default();
        list.add("task".into());
        list.toggle_on(d("2026-06-16"));
        assert!(list.items[0].done);
        assert_eq!(list.items[0].done_on, Some(d("2026-06-16")));
        // Unchecking clears the date so it rejoins the open group.
        list.toggle_on(d("2026-06-17"));
        assert!(!list.items[0].done);
        assert_eq!(list.items[0].done_on, None);
    }

    #[test]
    fn prune_removes_only_week_old_completions() {
        let mut list = TodoList::default();
        list.items = vec![
            TodoItem { text: "open".into(), done: false, done_on: None },
            TodoItem { text: "fresh".into(), done: true, done_on: Some(d("2026-06-15")) },
            TodoItem { text: "stale".into(), done: true, done_on: Some(d("2026-06-01")) },
        ];
        let removed = list.prune_expired(d("2026-06-16"));
        assert!(removed);
        let texts: Vec<_> = list.items.iter().map(|i| i.text.as_str()).collect();
        assert_eq!(texts, vec!["open", "fresh"]);
    }

    #[test]
    fn exactly_a_week_old_is_pruned() {
        let mut list = TodoList::default();
        list.items = vec![TodoItem {
            text: "x".into(),
            done: true,
            done_on: Some(d("2026-06-09")),
        }];
        // 2026-06-16 is 7 days later → not < 7 → pruned.
        assert!(list.prune_expired(d("2026-06-16")));
        assert!(list.items.is_empty());
    }
}
