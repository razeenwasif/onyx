//! Simple snapshot-based undo/redo.
//!
//! Each entry is a full buffer snapshot. Notes are small enough that this is
//! cheap and trivially correct; per-keystroke coalescing keeps memory in check.

use std::time::{Duration, Instant};

use super::buffer::{Buffer, Cursor};

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub lines: Vec<String>,
    pub cursor: Cursor,
}

impl Snapshot {
    pub fn of(buf: &Buffer) -> Self {
        Self {
            lines: buf.lines.clone(),
            cursor: buf.cursor,
        }
    }

    pub fn apply(&self, buf: &mut Buffer) {
        buf.lines = self.lines.clone();
        buf.cursor = self.cursor;
        buf.goal_col = self.cursor.col;
        buf.clamp_cursor();
    }
}

#[derive(Debug, Default)]
pub struct History {
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    last_push: Option<Instant>,
}

impl History {
    /// Record a snapshot if enough time has passed since the last one.
    pub fn record(&mut self, buf: &Buffer) {
        let now = Instant::now();
        let push = match self.last_push {
            None => true,
            Some(t) => now.duration_since(t) > Duration::from_millis(400),
        };
        if push {
            self.undo.push(Snapshot::of(buf));
            self.redo.clear();
            self.last_push = Some(now);
            if self.undo.len() > 200 {
                self.undo.remove(0);
            }
        }
    }

    /// Force a snapshot, ignoring coalescing.
    #[allow(dead_code)]
    pub fn checkpoint(&mut self, buf: &Buffer) {
        self.undo.push(Snapshot::of(buf));
        self.redo.clear();
        self.last_push = Some(Instant::now());
        if self.undo.len() > 200 {
            self.undo.remove(0);
        }
    }

    pub fn undo(&mut self, buf: &mut Buffer) -> bool {
        if let Some(snap) = self.undo.pop() {
            self.redo.push(Snapshot::of(buf));
            snap.apply(buf);
            true
        } else {
            false
        }
    }

    #[allow(dead_code)]
    pub fn redo(&mut self, buf: &mut Buffer) -> bool {
        if let Some(snap) = self.redo.pop() {
            self.undo.push(Snapshot::of(buf));
            snap.apply(buf);
            true
        } else {
            false
        }
    }
}
