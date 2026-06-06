//! A single editable todo/reminder checklist, persisted to `.onyx/todos.md`
//! as an ordinary markdown checklist so it stays human-readable and portable.

use std::fs;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct TodoItem {
    pub text: String,
    pub done: bool,
}

#[derive(Debug, Default)]
pub struct TodoList {
    pub items: Vec<TodoItem>,
    pub selected: usize,
}

impl TodoList {
    pub fn load(path: &Path) -> Self {
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
                items.push(TodoItem {
                    text: rest.trim().to_string(),
                    done,
                });
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
            out.push_str(&format!("- [{mark}] {}\n", it.text));
        }
        fs::write(path, out)
    }

    pub fn clamp(&mut self) {
        if self.selected >= self.items.len() {
            self.selected = self.items.len().saturating_sub(1);
        }
    }

    pub fn toggle(&mut self) {
        if let Some(it) = self.items.get_mut(self.selected) {
            it.done = !it.done;
        }
    }

    pub fn add(&mut self, text: String) {
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        self.items.push(TodoItem { text, done: false });
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

    pub fn up(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }

    pub fn down(&mut self) {
        if self.selected + 1 < self.items.len() {
            self.selected += 1;
        }
    }

    pub fn remaining(&self) -> usize {
        self.items.iter().filter(|i| !i.done).count()
    }
}
