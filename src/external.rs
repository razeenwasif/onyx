//! Run external terminal programs (fzf, yazi) with the Onyx TUI suspended.
//!
//! The event loop owns the terminal, so this is the only place that tears the
//! alternate screen down and brings it back. `dispatch` merely sets
//! `App::pending_external`; the loop drains it here.

use std::io::{self, Stdout};
use std::path::{Path, PathBuf};
use std::process::Command;

use crossterm::event::{DisableMouseCapture, EnableMouseCapture};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use crate::app::{App, PendingExternal};

type Term = Terminal<CrosstermBackend<Stdout>>;

/// True if `prog` is found on `$PATH`.
pub fn exists(prog: &str) -> bool {
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            if !dir.is_empty() && Path::new(dir).join(prog).is_file() {
                return true;
            }
        }
    }
    false
}

/// Suspend the TUI, run the requested tool, restore the TUI, then act on the
/// result. Always restores the terminal even if the tool errors.
pub fn handle(term: &mut Term, app: &mut App, ext: PendingExternal) -> anyhow::Result<()> {
    // --- suspend ---
    disable_raw_mode()?;
    execute!(term.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;
    term.show_cursor()?;

    let selection = match ext {
        PendingExternal::Fzf => run_fzf(app),
        PendingExternal::FzfGrep => run_fzf_grep(app),
        PendingExternal::Yazi => run_yazi(app),
        PendingExternal::GoogleAuth => {
            run_google_auth(app);
            Ok(None)
        }
    };

    // --- resume ---
    enable_raw_mode()?;
    execute!(term.backend_mut(), EnterAlternateScreen, EnableMouseCapture)?;
    term.clear()?;
    // The external tool may leave stray bytes in the input buffer (trailing
    // keystrokes, terminal query responses). Discard anything pending so it
    // isn't misread as editor input.
    drain_pending_input();

    match selection {
        Ok(Some(path)) => open_selection(app, path),
        Ok(None) => {}
        Err(e) => app.set_status(format!("external tool failed: {e}")),
    }
    Ok(())
}

/// Run the interactive Google OAuth consent flow with the TUI suspended (so the
/// browser-open + "authorizing…" output is visible and stdin works).
fn run_google_auth(app: &mut App) {
    let g = app.config.google.clone();
    if !g.is_configured() {
        app.set_status("set [google] client_id/client_secret in config.toml first");
        return;
    }
    let path = crate::config::Config::google_token_path();
    use crate::integrations::oauth;
    match oauth::run_consent_flow(&g.client_id, &g.client_secret, oauth::SCOPES) {
        Ok(tok) => match oauth::save_token(&path, &tok) {
            Ok(()) => app.set_status("Google authorized ✓"),
            Err(e) => app.set_status(format!("auth: couldn't save token: {e}")),
        },
        Err(e) => app.set_status(format!("Google auth failed: {e}")),
    }
}

fn open_selection(app: &mut App, path: PathBuf) {
    if !path.exists() {
        app.set_status(format!("not found: {}", path.display()));
        return;
    }
    // Notes and other plain-text files open directly in the editor.
    if is_note(&path) || is_text(&path) {
        if let Err(e) = app.open_note(path) {
            app.set_status(format!("open failed: {e}"));
        }
        return;
    }
    // Binary (PDF, image, …) — hand off to the system opener.
    match open_external(&path) {
        Ok(opener) => app.set_status(format!("opened with {opener}: {}", path.display())),
        Err(e) => app.set_status(format!("no opener for {}: {e}", path.display())),
    }
}

fn is_note(path: &Path) -> bool {
    matches!(
        ext_lower(path).as_deref(),
        Some("md") | Some("markdown") | Some("mdx")
    )
}

/// Plain-text formats Onyx can show in the editor (read-only-ish; the buffer
/// is markdown-oriented but holds any UTF-8 lines fine).
fn is_text(path: &Path) -> bool {
    matches!(
        ext_lower(path).as_deref(),
        Some(
            "txt" | "text" | "org" | "rst" | "csv" | "tsv" | "log" | "json" | "jsonc"
                | "yaml" | "yml" | "toml" | "ini" | "conf" | "cfg" | "env"
                | "sh" | "bash" | "zsh" | "fish" | "ps1" | "bat"
                | "py" | "rs" | "go" | "c" | "h" | "cpp" | "hpp" | "js" | "ts"
                | "jsx" | "tsx" | "lua" | "vim" | "rb" | "java" | "kt" | "sql"
                | "html" | "css" | "scss" | "xml" | "tex"
        )
    )
}

fn ext_lower(path: &Path) -> Option<String> {
    path.extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase())
}

/// True if running under WSL.
fn is_wsl() -> bool {
    if std::env::var("WSL_DISTRO_NAME").is_ok() {
        return true;
    }
    std::fs::read_to_string("/proc/version")
        .map(|v| v.to_ascii_lowercase().contains("microsoft"))
        .unwrap_or(false)
}

/// Launch a non-text file in the system's default app, fully detached so its
/// output can never touch the Onyx alternate screen. Returns the opener used.
fn open_external(path: &Path) -> io::Result<&'static str> {
    use std::process::Stdio;

    // Candidate openers, in preference order. Under WSL, hand off to Windows.
    let mut candidates: Vec<&'static str> = Vec::new();
    if is_wsl() {
        candidates.extend(["wslview", "explorer.exe"]);
    }
    candidates.extend(["xdg-open", "open"]);

    for opener in candidates {
        if !exists(opener) {
            continue;
        }
        let spawned = Command::new(opener)
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        if spawned.is_ok() {
            return Ok(opener);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "no system opener found",
    ))
}

/// fzf over the vault's files, with a bat-powered preview.
fn run_fzf(app: &App) -> io::Result<Option<PathBuf>> {
    let root = app.vault.root.clone();
    // Scope to markdown notes — this is a notes app; use `:yazi` to browse
    // other file types (PDFs, images, scripts, …).
    let lister = if exists("rg") {
        "rg --files -t markdown"
    } else {
        r"find . -type f \( -name '*.md' -o -name '*.markdown' -o -name '*.mdx' \) -not -path '*/.git/*'"
    };
    let preview = if exists("bat") {
        "bat --color=always --style=numbers {} 2>/dev/null | head -400"
    } else {
        "cat {} 2>/dev/null | head -400"
    };
    // No --height: fzf takes its own fullscreen alternate screen, so it renders
    // cleanly instead of inline over the suspended Onyx terminal.
    let script = format!(
        "cd {root} && ({lister}) | fzf \
         --prompt='onyx ❯ ' --border=rounded \
         --preview {preview:?} --preview-window=right,60%",
        root = shell_quote(&root.to_string_lossy()),
    );
    run_capture(&script).map(|sel| sel.map(|s| root.join(s)))
}

/// True live-grep: fzf in `--disabled` mode re-runs ripgrep on every keystroke
/// (Telescope-style), so ripgrep does the matching across file contents. Returns
/// the file of the chosen `file:line:text` row.
fn run_fzf_grep(app: &App) -> io::Result<Option<PathBuf>> {
    let root = app.vault.root.clone();
    if !exists("rg") {
        return run_fzf(app); // graceful fallback
    }
    let preview = if exists("bat") {
        "bat --color=always --style=numbers --highlight-line {2} {1} 2>/dev/null"
    } else {
        "sed -n {2}p {1} 2>/dev/null"
    };
    // `-t markdown` avoids single-quoted globs (which would collide with the
    // single-quoted --bind strings below). `{q}` is fzf's live query.
    let rg = "rg --line-number --no-heading --color=never --smart-case -t markdown";
    let script = format!(
        "cd {root} && fzf --disabled --prompt='grep ❯ ' --border=rounded \
         --bind 'start:reload:{rg} {{q}}' \
         --bind 'change:reload:sleep 0.05; {rg} {{q}} || true' \
         --delimiter=: \
         --preview {preview:?} --preview-window='right,60%,+{{2}}+3/3' \
         | cut -d: -f1",
        root = shell_quote(&root.to_string_lossy()),
    );
    run_capture(&script).map(|sel| sel.map(|s| root.join(s)))
}

/// yazi file manager rooted at the vault; returns the chosen path (if any).
fn run_yazi(app: &App) -> io::Result<Option<PathBuf>> {
    let root = app.vault.root.clone();
    let chooser = std::env::temp_dir().join(format!("onyx-yazi-{}.path", std::process::id()));
    let _ = std::fs::remove_file(&chooser);

    let status = Command::new("yazi")
        .arg(&root)
        .arg(format!("--chooser-file={}", chooser.display()))
        .status()?;
    let _ = status;

    let result = std::fs::read_to_string(&chooser).ok();
    let _ = std::fs::remove_file(&chooser);
    match result {
        Some(s) => {
            let line = s.lines().next().unwrap_or("").trim().to_string();
            if line.is_empty() {
                Ok(None)
            } else {
                Ok(Some(PathBuf::from(line)))
            }
        }
        None => Ok(None),
    }
}

/// Run a shell pipeline whose stdout is the selection, redirecting that stdout
/// to a temp file so we can inherit the real terminal for the child.
///
/// This mirrors the yazi approach: `Command::status()` inherits Onyx's stdin/
/// stdout/stderr (the actual terminal), which fzf needs to render and read keys.
/// `Command::output()` would pipe stdout and null stdin, leaving fzf without a
/// usable terminal — it then fails to draw (you just see the bare shell). The
/// `> file` redirect peels off only the final selection line; fzf still draws
/// on /dev/tty.
fn run_capture(script: &str) -> io::Result<Option<PathBuf>> {
    let out = std::env::temp_dir().join(format!("onyx-pick-{}.sel", std::process::id()));
    let _ = std::fs::remove_file(&out);

    let wrapped = format!(
        "{{ {script} ; }} > {out}",
        out = shell_quote(&out.to_string_lossy())
    );
    let status = Command::new("bash").arg("-c").arg(&wrapped).status()?;
    let _ = status;

    let sel = std::fs::read_to_string(&out).ok();
    let _ = std::fs::remove_file(&out);
    match sel {
        Some(s) => {
            let line = s.lines().next().unwrap_or("").trim().to_string();
            if line.is_empty() {
                Ok(None)
            } else {
                Ok(Some(PathBuf::from(line)))
            }
        }
        None => Ok(None),
    }
}

/// Minimal single-quote shell escaping for embedding a path in a bash `-c`.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Discard any input events buffered while the external program ran.
fn drain_pending_input() {
    use crossterm::event::{poll, read};
    use std::time::Duration;
    // A short settle window catches terminal responses that arrive just after
    // the tool exits, then we stop as soon as the buffer is empty.
    let deadline = std::time::Instant::now() + Duration::from_millis(60);
    while std::time::Instant::now() < deadline {
        match poll(Duration::from_millis(5)) {
            Ok(true) => {
                let _ = read();
            }
            _ => break,
        }
    }
}
