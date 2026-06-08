//! Filesystem watcher. Notifies the app when external tools (Obsidian, an
//! editor, git, sync) modify vault files, so Onyx can keep the tree, index, and
//! open document in sync instead of silently going stale.
//!
//! The watcher runs on its own thread (inotify on Linux) and pushes the changed
//! *paths* over a channel; `App::handle_fs_events` drains them each loop tick,
//! filters out Onyx's own writes, and refreshes what actually changed.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

pub struct VaultWatcher {
    _watcher: RecommendedWatcher,
    rx: mpsc::Receiver<PathBuf>,
}

impl VaultWatcher {
    pub fn new(root: &Path) -> Option<Self> {
        let (tx, rx) = mpsc::channel::<PathBuf>();
        let mut watcher = match RecommendedWatcher::new(
            move |res: notify::Result<notify::Event>| {
                if let Ok(ev) = res {
                    if matches!(
                        ev.kind,
                        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
                    ) {
                        for p in ev.paths {
                            let _ = tx.send(p);
                        }
                    }
                }
            },
            Config::default().with_poll_interval(Duration::from_secs(2)),
        ) {
            Ok(w) => w,
            Err(_) => return None,
        };
        if watcher.watch(root, RecursiveMode::Recursive).is_err() {
            return None;
        }
        Some(Self {
            _watcher: watcher,
            rx,
        })
    }

    /// Drain all pending change events into a deduplicated list of paths.
    /// Empty when nothing changed since the last drain.
    pub fn drain(&self) -> Vec<PathBuf> {
        let mut out: Vec<PathBuf> = Vec::new();
        while let Ok(p) = self.rx.try_recv() {
            if !out.contains(&p) {
                out.push(p);
            }
        }
        out
    }
}
