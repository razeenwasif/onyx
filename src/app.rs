//! Top-level application state and event dispatch.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{Datelike, Local, NaiveDate};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::text::Text;

use crate::config::Config;
use crate::editor::{Buffer, Document, Mode};
use crate::error::Result;
use crate::graph_sim::{EdgeKind, GraphSim};
use crate::theme::Theme;
use crate::todo::TodoList;
use crate::vault::{self, Vault};

/// A flattened, visible file-tree row (owned, so it can be cached).
#[derive(Clone)]
pub struct TreeRow {
    pub path: PathBuf,
    pub name: String,
    pub depth: usize,
    pub is_dir: bool,
}

/// Cached rendered preview, keyed by the inputs that affect it. Lets the
/// preview re-parse markdown only when the note content, width, or theme change.
pub struct PreviewCache {
    pub path: Option<PathBuf>,
    pub rev: u64,
    pub width: u16,
    pub theme_gen: u64,
    pub text: Text<'static>,
}

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
    /// Yes/no confirmation dialog (e.g. before deleting).
    Confirm,
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

/// A pending yes/no confirmation.
#[derive(Debug, Default)]
pub struct ConfirmState {
    pub message: String,
    pub action: ConfirmAction,
}

#[derive(Debug, Default, Clone)]
pub enum ConfirmAction {
    #[default]
    None,
    /// Delete a note or folder at this path.
    Delete(PathBuf),
}

#[derive(Debug, Default, Clone, Copy)]
#[allow(dead_code)]
pub enum PromptAction {
    #[default]
    None,
    NewNote,
    NewFolder,
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
    // Bumped on expand/collapse; with FileTree::gen this is the flattened
    // file-tree view cache key.
    pub expanded_gen: u64,
    pub tree_view_cache: RefCell<Option<(u64, u64, Vec<TreeRow>)>>,

    // Overlays
    pub palette: PaletteState,
    pub switcher: PaletteState,
    pub search: SearchState,
    pub prompt: PromptState,
    pub confirm: ConfirmState,
    pub cmdline: CmdlineState,
    pub help_open: bool,
    pub graph_focus: Option<PathBuf>,
    /// Force-directed simulation backing the graph view (built lazily).
    pub graph_sim: Option<GraphSim>,
    /// Whether the graph shows the whole vault (true) or a local neighborhood.
    pub graph_global: bool,
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

    // Set whenever something changed; the event loop redraws only when true
    // (so an idle Onyx doesn't burn CPU repainting).
    pub needs_redraw: bool,
    // Bumped on theme change to invalidate the preview cache.
    pub theme_gen: u64,
    // Cached rendered markdown preview (see PreviewCache).
    pub preview_cache: RefCell<Option<PreviewCache>>,

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
            expanded_gen: 0,
            tree_view_cache: RefCell::new(None),
            palette: PaletteState::default(),
            switcher: PaletteState::default(),
            search: SearchState::default(),
            prompt: PromptState::default(),
            confirm: ConfirmState::default(),
            cmdline: CmdlineState::default(),
            help_open: false,
            graph_focus: None,
            graph_sim: None,
            graph_global: true,
            calendar: CalendarState::today(),
            quicknote: QuicknoteState::new(quicknote_text),
            todos,
            sidebar_selected: 0,
            status_msg: None,
            pending_external: None,
            needs_redraw: true,
            theme_gen: 0,
            preview_cache: RefCell::new(None),
            config,
            should_quit: false,
        }
    }

    /// Whether the graph animates frame-by-frame (drives the redraw decision and
    /// the faster poll cadence). Only the focused/fullscreen graph animates;
    /// passive panes are pre-settled once and then static.
    pub fn graph_should_step(&self) -> bool {
        self.graph_animating()
    }

    /// Bump the expand/collapse generation (invalidates the flattened view).
    pub fn invalidate_tree_view(&mut self) {
        self.expanded_gen = self.expanded_gen.wrapping_add(1);
    }

    /// The flattened, visible file-tree rows. Cached and rebuilt only when the
    /// tree is rescanned (`FileTree::gen`) or a folder is expanded/collapsed
    /// (`expanded_gen`) — instead of re-walking the tree on every access.
    pub fn visible_tree(&self) -> std::cell::Ref<'_, Vec<TreeRow>> {
        let key = (self.vault.tree.gen, self.expanded_gen);
        {
            let mut cache = self.tree_view_cache.borrow_mut();
            let stale = cache
                .as_ref()
                .map(|(g, e, _)| (*g, *e) != key)
                .unwrap_or(true);
            if stale {
                let rows = self.build_tree_view();
                *cache = Some((key.0, key.1, rows));
            }
        }
        std::cell::Ref::map(self.tree_view_cache.borrow(), |o| &o.as_ref().unwrap().2)
    }

    fn build_tree_view(&self) -> Vec<TreeRow> {
        struct Exp<'a>(&'a HashSet<PathBuf>);
        impl crate::vault::tree::ExpansionSet for Exp<'_> {
            fn is_expanded(&self, p: &Path) -> bool {
                self.0.contains(p)
            }
        }
        let exp = Exp(&self.expanded_dirs);
        self.vault
            .tree
            .flatten(&exp)
            .into_iter()
            .map(|n| TreeRow {
                path: n.path.clone(),
                name: n.name.clone(),
                depth: n.depth,
                is_dir: n.is_dir,
            })
            .collect()
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
        self.needs_redraw = true;
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
        // Re-center the (local) graph on the newly-opened note.
        if !self.graph_global {
            self.graph_sim = None;
        }
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
        // Title the note by its file name (not the folder path).
        let heading = vault::note_basename(&path);
        let body = format!("# {heading}\n\n");
        self.vault.write_note(&path, &body)?;
        // Reveal the new note's folder in the tree.
        if let Some(parent) = path.parent() {
            self.expanded_dirs.insert(parent.to_path_buf());
        }
        self.open_note(path)?;
        // Place cursor at end and switch to insert mode for immediate writing.
        if let Some(doc) = self.doc.as_mut() {
            doc.buffer.move_doc_end();
            doc.mode = Mode::Insert;
        }
        Ok(())
    }

    /// Create an (empty) folder at a vault-relative path and reveal it.
    pub fn create_folder(&mut self, rel: &str) -> Result<()> {
        let path = self.vault.create_folder(rel)?;
        self.expanded_dirs.insert(path.clone());
        if let Some(parent) = path.parent() {
            self.expanded_dirs.insert(parent.to_path_buf());
        }
        self.set_status(format!(
            "created folder {}",
            vault::note_relpath(&self.vault.root, &path)
        ));
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

    /// Open a yes/no confirmation dialog for the given action.
    pub fn start_confirm(&mut self, message: impl Into<String>, action: ConfirmAction) {
        self.last_focus = self.focus;
        self.confirm = ConfirmState {
            message: message.into(),
            action,
        };
        self.focus = Focus::Confirm;
    }

    /// Run the pending confirmation's action (called on "yes").
    pub fn execute_confirm(&mut self) {
        let action = std::mem::take(&mut self.confirm.action);
        self.focus = self.last_focus;
        match action {
            ConfirmAction::None => {}
            ConfirmAction::Delete(path) => self.delete_path(&path),
        }
    }

    fn delete_path(&mut self, path: &Path) {
        let is_dir = path.is_dir();
        let rel = vault::note_relpath(&self.vault.root, path);
        let res = if is_dir {
            self.vault.delete_folder(path)
        } else {
            self.vault.delete_note(path)
        };
        match res {
            Ok(()) => {
                // Drop the open doc if it (or its folder) was deleted.
                let cleared = self
                    .doc
                    .as_ref()
                    .and_then(|d| d.path.as_ref())
                    .map(|p| p == path || p.starts_with(path))
                    .unwrap_or(false);
                if cleared {
                    self.doc = None;
                }
                self.tree_selected = self.tree_selected.saturating_sub(1);
                self.set_status(format!("deleted {rel}"));
            }
            Err(e) => self.set_status(format!("delete failed: {e}")),
        }
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

    pub fn toggle_graph_scope(&mut self) {
        self.graph_global = !self.graph_global;
        self.graph_sim = None; // rebuild with the new scope
    }

    /// True when a graph is currently on screen (pane or fullscreen).
    pub fn graph_visible(&self) -> bool {
        if self.fullscreen == Some(FullPane::Graph) {
            return true;
        }
        self.fullscreen.is_none() && self.show_right && self.show_graph_pane
    }

    /// True when the graph should animate at the faster frame rate — i.e. the
    /// user is actively looking at it (focused or fullscreen). The passive
    /// sidebar pane still drifts, but only at the app's idle redraw cadence.
    pub fn graph_animating(&self) -> bool {
        self.fullscreen == Some(FullPane::Graph) || self.focus == Focus::Graph
    }

    /// The note the graph is centered on.
    pub fn graph_center_path(&self) -> Option<PathBuf> {
        self.graph_focus
            .clone()
            .or_else(|| self.doc.as_ref().and_then(|d| d.path.clone()))
            .or_else(|| self.most_connected_note())
    }

    fn most_connected_note(&self) -> Option<PathBuf> {
        let mut best: Option<(usize, PathBuf)> = None;
        for (p, m) in &self.vault.index.notes {
            let deg = m.outgoing.len() + self.vault.index.backlinks_for(p).len();
            if best.as_ref().map(|(d, _)| deg > *d).unwrap_or(true) {
                best = Some((deg, p.clone()));
            }
        }
        best.map(|(_, p)| p)
    }

    /// Step the graph simulation one frame, building/rebuilding it as needed.
    pub fn tick_graph(&mut self) {
        if !self.graph_visible() {
            return;
        }
        let center = self.graph_center_path();
        // Rebuild on scope change; in *local* mode also when the center note
        // changes. The global "earth" is kept stable across note switches.
        let stale = match &self.graph_sim {
            None => true,
            Some(sim) => {
                sim.global != self.graph_global || (!self.graph_global && sim.built_for != center)
            }
        };
        let animating = self.graph_animating();
        if stale {
            let mut sim = self.build_graph_sim(center);
            // Pre-settle a passive (unfocused) graph in one batch so it shows a
            // laid-out layout immediately with zero ongoing redraws. Fewer
            // iterations for big graphs to keep the one-time cost small.
            if !animating {
                let iters = if sim.nodes.len() > 400 { 60 } else { 180 };
                for _ in 0..iters {
                    sim.step();
                }
            }
            self.graph_sim = Some(sim);
            self.needs_redraw = true;
        }
        // While focused/fullscreen, advance one frame per tick → perpetual
        // motion. Passive panes don't step here (they were pre-settled), so an
        // idle Onyx does no graph work.
        if animating {
            if let Some(sim) = self.graph_sim.as_mut() {
                sim.step();
            }
            self.needs_redraw = true;
        }
    }

    /// Link + capped tag neighbors of a note (for graph expansion).
    fn note_neighbors(&self, p: &Path, tag_cap: usize) -> Vec<PathBuf> {
        let idx = &self.vault.index;
        let mut out: Vec<PathBuf> = Vec::new();
        if let Some(m) = idx.notes.get(p) {
            out.extend(m.outgoing.iter().cloned());
        }
        out.extend(idx.backlinks_for(p));
        out.extend(idx.shared_tag_notes(p, tag_cap));
        out
    }

    fn build_graph_sim(&self, center: Option<PathBuf>) -> GraphSim {
        // Local graphs stay small for readability; the global "earth" shows the
        // whole vault (bounded only to keep the O(n²) sim snappy on huge vaults).
        let local_cap = 160usize;
        let global_cap = 1500usize;
        let max_nodes = if self.graph_global { global_cap } else { local_cap };
        let mut paths: Vec<PathBuf> = Vec::new();
        let mut seen: HashSet<PathBuf> = HashSet::new();

        if let Some(c) = &center {
            if self.vault.index.notes.contains_key(c) {
                paths.push(c.clone());
                seen.insert(c.clone());
            }
        }

        if self.graph_global {
            // Whole vault. Sort by degree so that, if we ever hit the cap, the
            // most-connected notes are kept.
            let mut ranked: Vec<(usize, PathBuf)> = self
                .vault
                .index
                .notes
                .iter()
                .map(|(p, m)| {
                    (
                        m.outgoing.len() + self.vault.index.backlinks_for(p).len() + m.tags.len(),
                        p.clone(),
                    )
                })
                .collect();
            ranked.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
            for (_, p) in ranked {
                if paths.len() >= max_nodes {
                    break;
                }
                if seen.insert(p.clone()) {
                    paths.push(p);
                }
            }
        } else if center.is_some() {
            // Local: BFS two hops with generous neighbor caps.
            let mut frontier = vec![paths[0].clone()];
            for hop in 0..2 {
                let cap = if hop == 0 { 20 } else { 6 };
                let mut next = Vec::new();
                for n in &frontier {
                    for nb in self.note_neighbors(n, cap) {
                        if paths.len() >= max_nodes {
                            break;
                        }
                        if seen.insert(nb.clone()) {
                            paths.push(nb.clone());
                            next.push(nb);
                        }
                    }
                }
                frontier = next;
                if paths.len() >= max_nodes {
                    break;
                }
            }
        }

        // Index map for edge building.
        let idx_of: HashMap<&PathBuf, usize> =
            paths.iter().enumerate().map(|(i, p)| (p, i)).collect();
        let mut edge_set: HashSet<(usize, usize)> = HashSet::new();
        let mut edges: Vec<(usize, usize, EdgeKind)> = Vec::new();

        // Link edges.
        for (i, p) in paths.iter().enumerate() {
            if let Some(m) = self.vault.index.notes.get(p) {
                for dst in &m.outgoing {
                    if let Some(&j) = idx_of.get(dst) {
                        let key = if i < j { (i, j) } else { (j, i) };
                        if i != j && edge_set.insert(key) {
                            edges.push((key.0, key.1, EdgeKind::Link));
                        }
                    }
                }
            }
        }
        // Tag edges, capped per node to avoid a hairball.
        let tag_cap = if self.graph_global { 3 } else { 6 };
        for (i, p) in paths.iter().enumerate() {
            for nb in self.vault.index.shared_tag_notes(p, tag_cap) {
                if let Some(&j) = idx_of.get(&nb) {
                    let key = if i < j { (i, j) } else { (j, i) };
                    if i != j && !edge_set.contains(&key) && edge_set.insert(key) {
                        edges.push((key.0, key.1, EdgeKind::Tag));
                    }
                }
            }
        }

        let center_idx = center
            .as_ref()
            .and_then(|c| idx_of.get(c).copied())
            .unwrap_or(0);
        // Pin the centered note only in local mode; the global earth floats free.
        let pin_center = !self.graph_global;
        GraphSim::new(paths, edges, center_idx, center, self.graph_global, pin_center)
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
            Focus::Confirm => {
                // Esc cancels the pending action.
                self.confirm.action = ConfirmAction::None;
                self.focus = self.last_focus;
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
