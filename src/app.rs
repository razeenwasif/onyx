//! Top-level application state and event dispatch.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use chrono::{Datelike, Local, NaiveDate};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::config::Config;
use crate::editor::{Buffer, Document, Mode};
use crate::error::Result;
use crate::theme::Theme;
use crate::todo::TodoList;
use crate::vault::{self, Vault};

/// A small always-available scratch buffer persisted to `.onyx/quicknote.md`.
#[derive(Debug)]
pub struct QuicknoteState {
    pub buffer: Buffer,
    pub dirty: bool,
    pub scroll: usize,
}

impl QuicknoteState {
    pub fn new(text: String) -> Self {
        Self {
            buffer: Buffer::from_string(text),
            dirty: false,
            scroll: 0,
        }
    }
}

/// Which pane currently owns focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum Focus {
    FileTree,
    Quicknote,
    Todo,
    Editor,
    Preview,
    Sidebar,
    Palette,
    Switcher,
    Search,
    Graph,
    Calendar,
    Help,
    Settings,
    Prompt,
    /// Vim-style ex command line (`:q`, `:w`, `:e file`, …).
    CommandLine,
}

/// A pane currently expanded to fill the whole body area.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FullPane {
    Graph,
    Calendar,
}

/// What the upper-right sidebar shows. (The calendar is a separate docked
/// pane in the lower half — see `App::show_calendar` — not a tab.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SidebarTab {
    Backlinks,
    Outline,
    Tags,
}

impl SidebarTab {
    pub fn label(&self) -> &'static str {
        match self {
            SidebarTab::Backlinks => "Backlinks",
            SidebarTab::Outline => "Outline",
            SidebarTab::Tags => "Tags",
        }
    }

    pub fn next(self) -> Self {
        match self {
            SidebarTab::Backlinks => SidebarTab::Outline,
            SidebarTab::Outline => SidebarTab::Tags,
            SidebarTab::Tags => SidebarTab::Backlinks,
        }
    }

    pub fn prev(self) -> Self {
        match self {
            SidebarTab::Backlinks => SidebarTab::Tags,
            SidebarTab::Outline => SidebarTab::Backlinks,
            SidebarTab::Tags => SidebarTab::Outline,
        }
    }
}

/// Modal overlay state.
#[derive(Debug, Default)]
pub struct PaletteState {
    pub query: String,
    pub selected: usize,
}

#[derive(Debug, Default)]
pub struct PromptState {
    pub label: String,
    pub value: String,
    pub action: PromptAction,
    /// Optional subject of the prompt (e.g. the file-tree node being renamed).
    /// When `None`, actions fall back to the current document.
    pub target: Option<PathBuf>,
}

#[derive(Debug, Default, Clone, Copy)]
#[allow(dead_code)]
pub enum PromptAction {
    #[default]
    None,
    NewNote,
    Rename,
    Search,
    OpenVault,
    AddTodo,
    EditTodo,
}

/// A request to suspend the TUI, run an external terminal program, and resume.
/// Set by `dispatch`, drained by the event loop in `main` (which owns the
/// terminal). Handlers never touch the terminal directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PendingExternal {
    /// fzf fuzzy file finder over the vault.
    Fzf,
    /// fzf over file *contents* via ripgrep (live-grep style).
    FzfGrep,
    /// yazi file manager rooted at the vault (with image/PDF preview).
    Yazi,
}

/// Vim ex-command-line state. One-row prompt rendered at the bottom of the
/// screen when `Focus::CommandLine` is active.
#[derive(Debug, Default)]
pub struct CmdlineState {
    pub value: String,
    /// Most-recent ex commands first; navigated with Up/Down while typing.
    pub history: Vec<String>,
    /// `Some(i)` if the user is scrolling through history; `i` indexes
    /// `history` from the end (0 = most recent).
    pub history_idx: Option<usize>,
    /// The in-progress value the user had typed before they started scrolling
    /// history — restored when they scroll past the newest entry.
    pub draft: String,
}

#[derive(Debug, Default)]
pub struct SearchState {
    pub query: String,
    pub results: Vec<SearchHit>,
    pub selected: usize,
    pub editing_query: bool,
}

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub path: PathBuf,
    pub line: usize,
    pub preview: String,
}

#[derive(Debug)]
pub struct CalendarState {
    pub cursor: NaiveDate,
}

impl CalendarState {
    pub fn today() -> Self {
        Self {
            cursor: Local::now().date_naive(),
        }
    }
}

pub struct App {
    pub config: Config,
    pub theme: Theme,
    pub vault: Vault,
    pub doc: Option<Document>,
    pub focus: Focus,
    pub last_focus: Focus,

    // Layout toggles
    pub show_left: bool,
    pub show_right: bool,
    pub show_preview: bool,
    // Stacked side panes (default on).
    pub show_graph_pane: bool,
    pub show_calendar: bool,
    pub show_quicknote: bool,
    pub show_todo: bool,
    /// A pane expanded to fill the body, or None for the normal layout.
    pub fullscreen: Option<FullPane>,
    pub sidebar_tab: SidebarTab,

    // File tree state
    pub tree_selected: usize,
    pub expanded_dirs: HashSet<PathBuf>,

    // Overlays
    pub palette: PaletteState,
    pub switcher: PaletteState,
    pub search: SearchState,
    pub prompt: PromptState,
    pub cmdline: CmdlineState,
    pub help_open: bool,
    pub graph_focus: Option<PathBuf>,
    pub calendar: CalendarState,

    // Left-column side panes.
    pub quicknote: QuicknoteState,
    pub todos: TodoList,

    // Right sidebar lists
    pub sidebar_selected: usize,

    // Transient status message
    pub status_msg: Option<(String, std::time::Instant)>,

    // A queued external program for the event loop to run (TUI suspended).
    pub pending_external: Option<PendingExternal>,

    // Quit flag
    pub should_quit: bool,
}

impl App {
    pub fn new(vault: Vault, config: Config) -> Self {
        let theme = config.resolve_theme();
        let mut expanded = HashSet::new();
        expanded.insert(vault.root.clone());
        // Load side-pane data from the vault's `.onyx/` dir.
        let quicknote_text =
            std::fs::read_to_string(vault.quicknote_path()).unwrap_or_default();
        let todos = TodoList::load(&vault.todos_path());

        Self {
            theme,
            show_left: config.layout.show_left_sidebar,
            show_right: config.layout.show_right_sidebar,
            show_preview: config.layout.show_preview,
            show_graph_pane: config.layout.show_graph_pane,
            show_calendar: config.layout.show_calendar,
            show_quicknote: config.layout.show_quicknote,
            show_todo: config.layout.show_todo,
            fullscreen: None,
            sidebar_tab: SidebarTab::Backlinks,
            vault,
            doc: None,
            focus: Focus::FileTree,
            last_focus: Focus::FileTree,
            tree_selected: 0,
            expanded_dirs: expanded,
            palette: PaletteState::default(),
            switcher: PaletteState::default(),
            search: SearchState::default(),
            prompt: PromptState::default(),
            cmdline: CmdlineState::default(),
            help_open: false,
            graph_focus: None,
            calendar: CalendarState::today(),
            quicknote: QuicknoteState::new(quicknote_text),
            todos,
            sidebar_selected: 0,
            status_msg: None,
            pending_external: None,
            config,
            should_quit: false,
        }
    }

    /// Persist the quicknote buffer to `.onyx/quicknote.md` if dirty.
    pub fn save_quicknote(&mut self) {
        if !self.quicknote.dirty {
            return;
        }
        let path = self.vault.quicknote_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if std::fs::write(&path, self.quicknote.buffer.to_string()).is_ok() {
            self.quicknote.dirty = false;
        }
    }

    /// Persist the todo list to `.onyx/todos.md`.
    pub fn save_todos(&mut self) {
        let _ = self.todos.save(&self.vault.todos_path());
    }

    /// Swap to a different vault, resetting all vault-derived state (open doc,
    /// file-tree selection, expanded folders, graph focus, and the per-vault
    /// quicknote/todo side panes). Persists the new vault as `last_vault`.
    pub fn switch_vault(&mut self, new_vault: Vault, path: PathBuf) {
        // Flush the current vault's side-pane state before leaving it.
        self.save_quicknote();
        self.save_todos();

        self.vault = new_vault;
        self.config.last_vault = Some(path);
        let _ = self.config.save();

        self.doc = None;
        self.graph_focus = None;
        self.fullscreen = None;
        self.tree_selected = 0;
        self.sidebar_selected = 0;
        self.expanded_dirs.clear();
        self.expanded_dirs.insert(self.vault.root.clone());

        let qn = std::fs::read_to_string(self.vault.quicknote_path()).unwrap_or_default();
        self.quicknote = QuicknoteState::new(qn);
        self.todos = TodoList::load(&self.vault.todos_path());

        self.focus = Focus::FileTree;
        self.set_status(format!("vault: {}", self.vault.root.display()));
    }

    pub fn set_status<S: Into<String>>(&mut self, msg: S) {
        self.status_msg = Some((msg.into(), std::time::Instant::now()));
    }

    pub fn current_status(&self) -> Option<&str> {
        let (msg, when) = self.status_msg.as_ref()?;
        if when.elapsed() < std::time::Duration::from_secs(4) {
            Some(msg.as_str())
        } else {
            None
        }
    }

    pub fn open_note(&mut self, path: PathBuf) -> Result<()> {
        // Save current dirty doc silently first? No — let the user save explicitly.
        let text = self.vault.read_note(&path)?;
        let doc = Document::from_text(Some(path.clone()), text);
        self.doc = Some(doc);
        self.focus = Focus::Editor;
        self.set_status(format!("Opened {}", vault::note_relpath(&self.vault.root, &path)));
        self.graph_focus = Some(path);
        self.sidebar_selected = 0;
        Ok(())
    }

    pub fn save_current(&mut self) -> Result<()> {
        let Some(doc) = self.doc.as_mut() else {
            return Ok(());
        };
        let content = doc.buffer.to_string();
        let path = match doc.path.clone() {
            Some(p) => p,
            None => self.vault.path_for_new_note("Untitled"),
        };
        self.vault.write_note(&path, &content)?;
        if let Some(d) = self.doc.as_mut() {
            d.path = Some(path.clone());
            d.dirty = false;
        }
        self.set_status(format!("Saved {}", vault::note_relpath(&self.vault.root, &path)));
        Ok(())
    }

    pub fn create_note(&mut self, title: &str) -> Result<()> {
        let path = self.vault.path_for_new_note(title);
        let body = format!("# {}\n\n", title.trim());
        self.vault.write_note(&path, &body)?;
        self.open_note(path)?;
        // Place cursor at end and switch to insert mode for immediate writing.
        if let Some(doc) = self.doc.as_mut() {
            doc.buffer.move_doc_end();
            doc.mode = Mode::Insert;
        }
        Ok(())
    }

    pub fn open_daily_note(&mut self, date: NaiveDate) -> Result<()> {
        let folder = &self.config.daily_notes.folder;
        let filename = date.format(&self.config.daily_notes.format).to_string();
        let path = self.vault.root.join(folder).join(format!("{filename}.md"));
        if !path.exists() {
            let template = self.config.daily_notes.template.clone().unwrap_or_else(|| {
                format!(
                    "# {date}\n\n## Tasks\n- [ ] \n\n## Notes\n\n",
                    date = date.format("%A, %B %-d %Y")
                )
            });
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&path, template)?;
            self.vault.refresh();
        }
        self.open_note(path)
    }

    pub fn toggle_pane_focus(&mut self, forward: bool) {
        let order = self.focus_order();
        let pos = order.iter().position(|f| *f == self.focus).unwrap_or(0);
        let new = if forward {
            order[(pos + 1) % order.len()]
        } else {
            order[(pos + order.len() - 1) % order.len()]
        };
        self.focus = new;
    }

    fn focus_order(&self) -> Vec<Focus> {
        // While a pane is fullscreen, Tab stays within nothing — just that pane.
        if let Some(full) = self.fullscreen {
            return vec![match full {
                FullPane::Graph => Focus::Graph,
                FullPane::Calendar => Focus::Calendar,
            }];
        }
        let mut order = Vec::new();
        if self.show_left {
            order.push(Focus::FileTree);
            if self.show_quicknote {
                order.push(Focus::Quicknote);
            }
            if self.show_todo {
                order.push(Focus::Todo);
            }
        }
        order.push(Focus::Editor);
        if self.show_preview {
            order.push(Focus::Preview);
        }
        if self.show_right {
            order.push(Focus::Sidebar);
            if self.show_graph_pane {
                order.push(Focus::Graph);
            }
            if self.show_calendar {
                order.push(Focus::Calendar);
            }
        }
        if order.is_empty() {
            order.push(Focus::Editor);
        }
        order
    }

    pub fn open_palette(&mut self) {
        self.last_focus = self.focus;
        self.focus = Focus::Palette;
        self.palette = PaletteState::default();
    }

    pub fn open_switcher(&mut self) {
        self.last_focus = self.focus;
        self.focus = Focus::Switcher;
        self.switcher = PaletteState::default();
    }

    pub fn open_search(&mut self) {
        self.last_focus = self.focus;
        self.focus = Focus::Search;
        self.search.editing_query = true;
        if !self.search.query.is_empty() {
            self.run_search();
        }
    }

    pub fn open_help(&mut self) {
        self.last_focus = self.focus;
        self.focus = Focus::Help;
        self.help_open = true;
    }

    pub fn open_cmdline(&mut self) {
        self.last_focus = self.focus;
        self.focus = Focus::CommandLine;
        self.cmdline.value.clear();
        self.cmdline.draft.clear();
        self.cmdline.history_idx = None;
    }

    /// Focus the calendar pane (showing it if hidden).
    pub fn open_calendar(&mut self) {
        self.show_right = true;
        self.show_calendar = true;
        self.focus = Focus::Calendar;
    }

    /// Focus the graph pane (showing it if hidden).
    pub fn open_graph(&mut self) {
        self.show_right = true;
        self.show_graph_pane = true;
        self.focus = Focus::Graph;
        if self.graph_focus.is_none() {
            self.graph_focus = self.doc.as_ref().and_then(|d| d.path.clone());
        }
    }

    pub fn focus_quicknote(&mut self) {
        self.show_left = true;
        self.show_quicknote = true;
        self.focus = Focus::Quicknote;
    }

    pub fn focus_todo(&mut self) {
        self.show_left = true;
        self.show_todo = true;
        self.focus = Focus::Todo;
    }

    /// Expand the focused graph/calendar pane to fill the body (or collapse it).
    pub fn toggle_fullscreen(&mut self) {
        match self.focus {
            Focus::Graph => {
                self.fullscreen = if self.fullscreen == Some(FullPane::Graph) {
                    None
                } else {
                    Some(FullPane::Graph)
                };
            }
            Focus::Calendar => {
                self.fullscreen = if self.fullscreen == Some(FullPane::Calendar) {
                    None
                } else {
                    Some(FullPane::Calendar)
                };
            }
            _ => {}
        }
    }

    pub fn close_overlay(&mut self) {
        self.help_open = false;
        self.focus = self.last_focus;
    }

    pub fn run_search(&mut self) {
        let q = self.search.query.trim().to_string();
        self.search.results.clear();
        if q.is_empty() {
            return;
        }
        let needle = q.to_lowercase();
        let notes: Vec<PathBuf> = self.vault.tree.notes.clone();
        for path in notes {
            if let Ok(content) = std::fs::read_to_string(&path) {
                for (i, line) in content.lines().enumerate() {
                    if line.to_lowercase().contains(&needle) {
                        let preview = line.trim().chars().take(160).collect::<String>();
                        self.search.results.push(SearchHit {
                            path: path.clone(),
                            line: i,
                            preview,
                        });
                        if self.search.results.len() > 500 {
                            return;
                        }
                    }
                }
            }
        }
    }

    #[allow(dead_code)]
    pub fn ensure_doc(&mut self) -> &mut Document {
        if self.doc.is_none() {
            self.doc = Some(Document::new());
        }
        self.doc.as_mut().unwrap()
    }

    /// Handle ESC consistently across modes.
    pub fn escape(&mut self) {
        // A fullscreen pane collapses back to the normal layout first.
        if self.fullscreen.is_some() {
            self.fullscreen = None;
            return;
        }
        match self.focus {
            Focus::Palette | Focus::Switcher | Focus::Search | Focus::Help | Focus::Settings | Focus::Prompt => {
                self.close_overlay();
            }
            Focus::CommandLine => {
                self.cmdline.value.clear();
                self.cmdline.draft.clear();
                self.cmdline.history_idx = None;
                self.focus = self.last_focus;
            }
            Focus::Quicknote => {
                self.save_quicknote();
                self.focus = Focus::Editor;
            }
            Focus::Graph | Focus::Calendar | Focus::Todo => {
                self.focus = Focus::Editor;
            }
            Focus::Editor => {
                if let Some(doc) = self.doc.as_mut() {
                    doc.mode = Mode::Normal;
                    doc.pending_op = None;
                    doc.anchor = None;
                }
            }
            _ => {}
        }
    }
}

/// Convenience: KeyEvent helpers.
#[allow(dead_code)]
pub fn is_ctrl(ev: &KeyEvent) -> bool {
    ev.modifiers.contains(KeyModifiers::CONTROL)
}

#[allow(dead_code)]
pub fn is_shift(ev: &KeyEvent) -> bool {
    ev.modifiers.contains(KeyModifiers::SHIFT)
}

#[allow(dead_code)]
pub fn key_char(ev: &KeyEvent) -> Option<char> {
    if let KeyCode::Char(c) = ev.code {
        Some(c)
    } else {
        None
    }
}

/// Today as `NaiveDate` (timezone-aware via local).
pub fn today() -> NaiveDate {
    let d = Local::now().date_naive();
    NaiveDate::from_ymd_opt(d.year(), d.month(), d.day()).unwrap_or(d)
}

/// Build a wikilink target string for inserting at the cursor.
#[allow(dead_code)]
pub fn note_link(path: &Path, root: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Untitled");
    let _ = root;
    format!("[[{stem}]]")
}

/// Helper: shape a buffer-only operation as a "modifying" event so the App
/// can record undo + mark dirty in one place.
#[allow(dead_code)]
pub fn modify<F: FnOnce(&mut Buffer)>(doc: &mut Document, f: F) {
    doc.history.record(&doc.buffer);
    f(&mut doc.buffer);
    doc.buffer.clamp_cursor();
    doc.dirty = true;
}
