//! Onyx — a premium markdown notes TUI.

mod app;
mod config;
mod dispatch;
mod editor;
mod error;
mod external;
mod keymap;
mod markdown;
mod theme;
mod todo;
mod ui;
mod vault;

use std::io;
use std::path::PathBuf;
use std::time::{Duration, Instant};

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

    let mut app = App::new(vault, config);

    if app.doc.is_none() {
        let first = app
            .vault
            .index
            .recent_notes()
            .into_iter()
            .map(|(p, _)| p)
            .next();
        if let Some(p) = first {
            let _ = app.open_note(p);
        }
    }

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

fn event_loop(
    term: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
) -> anyhow::Result<()> {
    let tick = Duration::from_millis(150);
    let mut last_tick = Instant::now();

    loop {
        term.draw(|f| ui::draw(f, app))?;
        if app.should_quit {
            // Flush side-pane state on the way out.
            app.save_quicknote();
            app.save_todos();
            return Ok(());
        }

        let timeout = tick.saturating_sub(last_tick.elapsed());
        if crossterm::event::poll(timeout)? {
            match crossterm::event::read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => {
                    dispatch::on_key(app, key);
                }
                Event::Resize(_, _) => {}
                Event::Mouse(_) => {}
                _ => {}
            }
        }

        // A handler may have queued an external program (fzf/yazi). Run it with
        // the TUI suspended, then carry on.
        if let Some(ext) = app.pending_external.take() {
            external::handle(term, app, ext)?;
        }

        if last_tick.elapsed() >= tick {
            last_tick = Instant::now();
            // Periodically persist the quicknote scratch buffer if idle-dirty.
            app.save_quicknote();
        }
    }
}
