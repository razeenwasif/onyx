//! Onyx — a premium markdown notes TUI.

mod app;
mod config;
mod db_view;
mod dispatch;
mod editor;
mod error;
mod external;
mod graph_sim;
mod integrations;
mod keymap;
mod markdown;
mod notion_import;
mod page_nav;
mod rag;
mod theme;
mod todo;
mod ui;
mod vault;

use std::io;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::Context;
use crossterm::event::{DisableMouseCapture, EnableMouseCapture, Event, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use crate::app::App;
use crate::config::Config;
use crate::vault::Vault;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cli = parse_args(&args);

    if cli.help {
        print_help();
        return Ok(());
    }
    if cli.version {
        println!("onyx {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }

    let mut config = Config::load();
    let vault_path = resolve_vault_path(&cli, &config)?;

    if config.last_vault.as_deref() != Some(vault_path.as_path()) {
        config.last_vault = Some(vault_path.clone());
        let _ = config.save();
    }

    let vault = if vault_path.exists() {
        Vault::open(&vault_path)
            .with_context(|| format!("opening vault at {}", vault_path.display()))?
    } else {
        Vault::create(&vault_path)
            .with_context(|| format!("creating vault at {}", vault_path.display()))?
    };

    // Onyx opens on the Home start page (App::new sets Focus::Home with no doc),
    // so the user lands on a menu of actions + recent notes rather than whatever
    // note happened to be open last.
    let mut app = App::new(vault, config);

    run(&mut app)?;
    Ok(())
}

struct Cli {
    vault: Option<PathBuf>,
    help: bool,
    version: bool,
}

fn parse_args(args: &[String]) -> Cli {
    let mut cli = Cli {
        vault: None,
        help: false,
        version: false,
    };
    for a in args {
        match a.as_str() {
            "-h" | "--help" => cli.help = true,
            "-V" | "--version" => cli.version = true,
            other if other.starts_with("--") => {}
            other => {
                if cli.vault.is_none() {
                    cli.vault = Some(PathBuf::from(other));
                }
            }
        }
    }
    cli
}

fn print_help() {
    println!(
        "Onyx — a premium markdown notes TUI\n\
\n\
USAGE:\n\
    onyx [VAULT]\n\
\n\
ARGS:\n\
    VAULT    Path to a vault folder. Will be created if missing.\n\
             Defaults to the last-opened vault, or ~/OnyxVault.\n\
\n\
OPTIONS:\n\
    -h, --help       Print this help.\n\
    -V, --version    Print version.\n\
\n\
Configuration lives at {}.\n",
        Config::config_path().display()
    );
}

fn resolve_vault_path(cli: &Cli, config: &Config) -> anyhow::Result<PathBuf> {
    if let Some(p) = &cli.vault {
        return Ok(p.clone());
    }
    if let Some(p) = &config.last_vault {
        if p.exists() {
            return Ok(p.clone());
        }
    }
    if let Some(home) = dirs::home_dir() {
        return Ok(home.join("OnyxVault"));
    }
    Ok(PathBuf::from("./onyx-vault"))
}

fn run(app: &mut App) -> anyhow::Result<()> {
    install_panic_hook();
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut term = Terminal::new(backend)?;
    term.clear()?;

    let res = event_loop(&mut term, app);

    disable_raw_mode()?;
    execute!(
        term.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    term.show_cursor()?;
    res
}

/// Restore the terminal before printing a panic, so a crash doesn't leave the
/// user stuck in raw mode / the alternate screen.
fn install_panic_hook() {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen, DisableMouseCapture);
        default(info);
    }));
}

fn event_loop(
    term: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
) -> anyhow::Result<()> {
    // Frame interval while the graph is animating (≈14 fps).
    let anim_frame = Duration::from_millis(70);
    // While a transient status toast is showing, wake often enough to clear it.
    let toast_poll = Duration::from_millis(200);
    // With the filesystem watcher active, wake about once a second so external
    // edits are picked up promptly (crossterm's poll only watches stdin, not the
    // watcher channel). Still ~no CPU: a per-second empty channel drain.
    let watch_poll = Duration::from_millis(1000);
    // Truly idle (no watcher): block on input so Onyx uses ~no CPU.
    let idle_poll = Duration::from_secs(3600);

    let mut status_was_visible = false;

    loop {
        // Advance the force-directed graph one frame when it's on screen
        // (sets needs_redraw when it actually moves).
        app.tick_graph();
        // Apply any results from the background search / Google workers.
        app.drain_search();
        app.drain_gtasks();
        app.drain_calendar();
        app.drain_drive();
        app.maybe_autosync_calendar();
        app.maybe_refresh_unlinked();
        app.drain_unlinked();
        app.drain_ai();
        app.drain_rag();
        app.drain_rewrite();
        app.maybe_request_ghost();
        app.drain_ghost();
        // React to external edits (Obsidian, git, sync) noticed by the watcher.
        app.handle_fs_events();

        // Redraw once when a status toast expires, to clear it.
        let status_visible = app.current_status().is_some();
        if status_was_visible && !status_visible {
            app.needs_redraw = true;
        }
        status_was_visible = status_visible;

        if app.needs_redraw {
            term.draw(|f| ui::draw(f, app))?;
            app.needs_redraw = false;
        }
        if app.should_quit {
            // Flush side-pane state on the way out.
            app.save_quicknote();
            app.save_todos();
            return Ok(());
        }

        // Choose how long to block: animating → fast; a toast is up → medium;
        // otherwise sleep until input arrives.
        let timeout = if app.graph_should_step()
            || app.search_in_flight()
            || app.gtasks_syncing()
            || app.calendar_syncing()
            || app.drive_loading()
            || app.unlinked_loading()
            || app.ai_streaming()
            || app.rag_building()
            || app.rewrite_active()
            || app.ghost_armed()
            || app.ghost_pending()
        {
            anim_frame
        } else if status_visible {
            toast_poll
        } else if app.watcher.is_some() {
            watch_poll
        } else {
            idle_poll
        };

        if crossterm::event::poll(timeout)? {
            match crossterm::event::read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => {
                    dispatch::on_key(app, key);
                    app.needs_redraw = true;
                    // Persist the scratch buffer opportunistically (cheap no-op
                    // when it isn't dirty).
                    app.save_quicknote();
                }
                Event::Resize(_, _) => app.needs_redraw = true,
                Event::Mouse(_) => {}
                _ => {}
            }
        }

        // A handler may have queued an external program (fzf/yazi). Run it with
        // the TUI suspended, then carry on.
        if let Some(ext) = app.pending_external.take() {
            external::handle(term, app, ext)?;
            app.needs_redraw = true;
        }
    }
}
