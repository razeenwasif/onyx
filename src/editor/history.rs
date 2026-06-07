//! Simple snapshot-based undo/redo.
//!
//! Each entry is a full buffer snapshot. Notes are small enough that this is
//! cheap and trivially correct; per-keystroke coalescing keeps memory in check,
//! and a byte budget bounds memory even for very large notes.

use std::time::{Duration, Instant};

use super::buffer::{Buffer, Cursor};

/// Cap on number of undo snapshots.
const MAX_SNAPSHOTS: usize = 200;
/// Cap on total bytes held across all undo snapshots (~4 MiB).
const MAX_BYTES: usize = 4 * 1024 * 1024;

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
        buf.touch();
    }

    fn bytes(&self) -> usize {
        // Approximate heap footprint: line contents + 1 for the newline.
        self.lines.iter().map(|l| l.len() + 1).sum()
    }
}

#[derive(Debug, Default)]
pub struct History {
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    last_push: Option<Instant>,
    /// Running total of `undo` snapshot bytes (kept in sync on push/trim).
    undo_bytes: usize,
}

impl History {
    /// Push onto the undo stack and trim to the size/byte caps (keeps ≥1).
    /// Does *not* touch the redo stack — callers that represent a new edit
    /// clear redo explicitly.
    fn push_undo(&mut self, snap: Snapshot) {
        self.undo_bytes += snap.bytes();
        self.undo.push(snap);
        while self.undo.len() > MAX_SNAPSHOTS
            || (self.undo_bytes > MAX_BYTES && self.undo.len() > 1)
        {
            let removed = self.undo.remove(0);
            self.undo_bytes = self.undo_bytes.saturating_sub(removed.bytes());
        }
    }

    /// Record a snapshot if enough time has passed since the last one.
    pub fn record(&mut self, buf: &Buffer) {
        let now = Instant::now();
        let push = match self.last_push {
            None => true,
            Some(t) => now.duration_since(t) > Duration::from_millis(400),
        };
        if push {
            self.push_undo(Snapshot::of(buf));
            self.redo.clear(); // a fresh edit invalidates the redo stack
            self.last_push = Some(now);
        }
    }

    /// Force a snapshot, ignoring coalescing.
    #[allow(dead_code)]
    pub fn checkpoint(&mut self, buf: &Buffer) {
        self.push_undo(Snapshot::of(buf));
        self.redo.clear();
        self.last_push = Some(Instant::now());
    }

    pub fn undo(&mut self, buf: &mut Buffer) -> bool {
        if let Some(snap) = self.undo.pop() {
            self.undo_bytes = self.undo_bytes.saturating_sub(snap.bytes());
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
            self.push_undo(Snapshot::of(buf));
            snap.apply(buf);
            true
        } else {
            false
        }
    }
}
