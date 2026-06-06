//! Optional filesystem watcher. Used to mark the index dirty when external
//! tools modify vault files; we re-scan on next idle.

#![allow(dead_code)]

use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

pub struct VaultWatcher {
    _watcher: RecommendedWatcher,
    rx: mpsc::Receiver<()>,
}

impl VaultWatcher {
    pub fn new(root: &Path) -> Option<Self> {
        let (tx, rx) = mpsc::channel::<()>();
        let mut watcher = match RecommendedWatcher::new(
            move |res: notify::Result<notify::Event>| {
                if let Ok(ev) = res {
                    if matches!(
                        ev.kind,
                        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
                    ) {
                        let _ = tx.send(());
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
        Some(Self { _watcher: watcher, rx })
    }

    /// Drains any pending change events. Returns true if something changed.
    pub fn drain(&self) -> bool {
        let mut any = false;
        while self.rx.try_recv().is_ok() {
            any = true;
        }
        any
    }
}
