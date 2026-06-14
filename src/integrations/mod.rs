//! Cloud integrations (Google Calendar/Tasks/Drive, OneDrive).
//!
//! The data models, OAuth URL/token logic, and API response parsing are pure
//! (serde + std) and always compiled + unit-tested. The actual network calls
//! live behind the `cloud` cargo feature (`reqwest`); without it they return a
//! helpful "rebuild with --features cloud" error, so the default build pulls no
//! network/TLS stack and call sites need no `cfg` sprinkling.
//!
//! Much of this is used only under the `cloud` feature (or by tests), so the
//! default build sees it as unused — silence that here rather than `cfg`-tag
//! every item.
#![allow(dead_code, unused_imports, unused_variables)]

pub mod gtasks;
pub mod oauth;

/// Result type for integration code.
pub type IntResult<T> = std::result::Result<T, String>;

/// Open a URL in the user's browser (WSL-aware; detached).
pub fn open_url(url: &str) -> IntResult<()> {
    let candidates: &[&[&str]] = &[
        &["wslview"],
        &["xdg-open"],
        &["explorer.exe"],
        &["open"],
    ];
    for cmd in candidates {
        let mut c = std::process::Command::new(cmd[0]);
        c.args(&cmd[1..]).arg(url);
        c.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        if c.spawn().is_ok() {
            return Ok(());
        }
    }
    Err("couldn't open a browser (no wslview/xdg-open/explorer.exe)".into())
}
