//! Top-level application state and event dispatch.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{Datelike, Local, NaiveDate};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use fuzzy_matcher::skim::SkimMatcherV2;
use fuzzy_matcher::FuzzyMatcher;
use ratatui::text::Text;
use unicode_segmentation::UnicodeSegmentation;

use crate::config::Config;
use crate::db_view::{self, DatabaseView};
use crate::editor::{Buffer, Document, History, Mode};
use crate::error::Result;
use crate::graph_sim::{EdgeKind, GraphSim};
use crate::theme::Theme;
use crate::todo::TodoList;
use crate::vault::{self, Vault, VaultWatcher};

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
    /// The start page shown when no note is open (interactive action menu).
    Home,
    Editor,
    Preview,
    Sidebar,
    Palette,
    Switcher,
    Search,
    Graph,
    Calendar,
    /// A folder rendered as a Notion-style database (table / board view).
    Database,
    Help,
    Settings,
    Prompt,
    /// Yes/no confirmation dialog (e.g. before deleting).
    Confirm,
    /// Vim-style ex command line (`:q`, `:w`, `:e file`, …).
    CommandLine,
}

/// State of the inline `[[wikilink]]` autocomplete popup, active while the
/// editor is in insert mode and the cursor sits inside an unclosed `[[`.
#[derive(Debug, Clone)]
pub struct LinkComplete {
    /// The text typed after `[[` (the fuzzy query).
    pub query: String,
    /// Candidate note names to insert (already filtered + ranked).
    pub matches: Vec<String>,
    /// Index into `matches` of the highlighted candidate.
    pub selected: usize,
}

/// An action on the Home start page.
#[derive(Debug, Clone)]
pub enum HomeAction {
    NewNote,
    NewFolder,
    Search,
    Switcher,
    DailyNote,
    OpenRecent(PathBuf),
}

/// One selectable row on the Home start page.
#[derive(Debug, Clone)]
pub struct HomeItem {
    pub icon: &'static str,
    pub label: String,
    pub hint: String,
    pub action: HomeAction,
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
    /// Overwrite a note that changed on disk since we opened it (force-save).
    OverwriteNote(PathBuf),
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

/// Messages from the background search worker, tagged with the search epoch so
/// stale results (from a superseded query) can be discarded.
pub enum SearchMsg {
    Hit(u64, SearchHit),
    Done(u64),
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

    // Home start-page selection (index into `home_items()`).
    pub home_selected: usize,

    // `[[wikilink]]` autocomplete popup (Some while typing inside `[[`).
    pub link_complete: Option<LinkComplete>,

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
    // Background search: epoch identifies the current query; `search_gen` is the
    // shared cancellation token the worker checks; results stream over `search_rx`.
    pub search_epoch: u64,
    pub search_gen: Arc<AtomicU64>,
    pub search_rx: Option<Receiver<SearchMsg>>,
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

    /// Active database view (a folder shown as a table/board), or None.
    pub database: Option<DatabaseView>,

    // Left-column side panes.
    pub quicknote: QuicknoteState,
    pub todos: TodoList,

    // Right sidebar lists
    pub sidebar_selected: usize,

    // Transient status message
    pub status_msg: Option<(String, std::time::Instant)>,

    // A queued external program for the event loop to run (TUI suspended).
    pub pending_external: Option<PendingExternal>,

    // Filesystem watcher: notices external edits (Obsidian, git, sync) so the
    // tree/index/open-doc stay in sync. None if the OS watcher couldn't start.
    pub watcher: Option<VaultWatcher>,
    // Paths Onyx wrote itself, with when — lets `handle_fs_events` ignore the
    // watcher events caused by our own saves (no self-triggered reindex storm).
    pub recent_self_writes: HashMap<PathBuf, Instant>,

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
        let watcher = VaultWatcher::new(&vault.root);

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
            focus: Focus::Home,
            last_focus: Focus::Home,
            home_selected: 0,
            link_complete: None,
            tree_selected: 0,
            expanded_dirs: expanded,
            expanded_gen: 0,
            tree_view_cache: RefCell::new(None),
            palette: PaletteState::default(),
            switcher: PaletteState::default(),
            search: SearchState::default(),
            search_epoch: 0,
            search_gen: Arc::new(AtomicU64::new(0)),
            search_rx: None,
            prompt: PromptState::default(),
            confirm: ConfirmState::default(),
            cmdline: CmdlineState::default(),
            help_open: false,
            graph_focus: None,
            graph_sim: None,
            graph_global: true,
            calendar: CalendarState::today(),
            database: None,
            quicknote: QuicknoteState::new(quicknote_text),
            todos,
            sidebar_selected: 0,
            status_msg: None,
            pending_external: None,
            watcher,
            recent_self_writes: HashMap::new(),
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

        // Re-arm the filesystem watcher on the new root.
        self.watcher = VaultWatcher::new(&self.vault.root);
        self.recent_self_writes.clear();

        self.doc = None;
        self.database = None;
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

    /// The focus the center pane should take: the editor when a note is open,
    /// otherwise the Home start page.
    pub fn center_focus(&self) -> Focus {
        if self.doc.is_some() {
            Focus::Editor
        } else {
            Focus::Home
        }
    }

    /// The selectable rows on the Home start page: quick actions, then the most
    /// recent notes. Both the renderer and the key handler build from this, so
    /// the displayed list and the action on Enter never drift apart.
    pub fn home_items(&self) -> Vec<HomeItem> {
        let mut items = vec![
            HomeItem {
                icon: "✎",
                label: "New note".into(),
                hint: "Ctrl-N".into(),
                action: HomeAction::NewNote,
            },
            HomeItem {
                icon: "✚",
                label: "New folder".into(),
                hint: String::new(),
                action: HomeAction::NewFolder,
            },
            HomeItem {
                icon: "⌕",
                label: "Search vault".into(),
                hint: "Ctrl-Shift-F".into(),
                action: HomeAction::Search,
            },
            HomeItem {
                icon: "❯",
                label: "Open note…".into(),
                hint: "Ctrl-O".into(),
                action: HomeAction::Switcher,
            },
            HomeItem {
                icon: "◷",
                label: "Today's daily note".into(),
                hint: "Ctrl-K".into(),
                action: HomeAction::DailyNote,
            },
        ];
        for (p, _) in self.vault.index.recent_notes().into_iter().take(8) {
            let label = vault::note_basename(&p);
            let rel = vault::note_relpath(&self.vault.root, &p);
            let hint = Path::new(&rel)
                .parent()
                .map(|d| d.to_string_lossy().to_string())
                .filter(|d| !d.is_empty())
                .unwrap_or_default();
            items.push(HomeItem {
                icon: "•",
                label,
                hint,
                action: HomeAction::OpenRecent(p),
            });
        }
        items
    }

    /// Run the selected Home action (Enter on the start page).
    pub fn activate_home(&mut self, action: HomeAction) {
        match action {
            HomeAction::Search => self.open_search(),
            HomeAction::Switcher => self.open_switcher(),
            HomeAction::DailyNote => {
                let today = today();
                if let Err(e) = self.open_daily_note(today) {
                    self.set_status(format!("daily note failed: {e}"));
                }
            }
            HomeAction::OpenRecent(p) => {
                if let Err(e) = self.open_note(p) {
                    self.set_status(format!("open failed: {e}"));
                }
            }
            // NewNote / NewFolder open a prompt; dispatch handles those (it owns
            // the prompt-starting helper).
            HomeAction::NewNote | HomeAction::NewFolder => {}
        }
    }

    /// Recompute the `[[wikilink]]` autocomplete popup from the cursor context.
    /// The popup is active only in insert mode when the cursor sits just after an
    /// unclosed `[[…` on the current line; otherwise it's dismissed. Called after
    /// each insert-mode edit (cheap: the prefix scan early-outs unless `[[` is
    /// open, and only then does it fuzzy-match note names).
    pub fn refresh_link_complete(&mut self) {
        let in_insert = self
            .doc
            .as_ref()
            .map(|d| d.mode == Mode::Insert)
            .unwrap_or(false);
        if !in_insert {
            self.link_complete = None;
            return;
        }
        // Extract the query: text between the last `[[` and the cursor on this
        // line, rejecting any `[`/`]` in between (that means it's not open).
        let query = {
            let doc = self.doc.as_ref().unwrap();
            let li = doc.buffer.cursor.line;
            let byte = doc.buffer.col_to_byte(li, doc.buffer.cursor.col);
            let prefix = &doc.buffer.line(li)[..byte];
            match prefix.rfind("[[") {
                Some(pos) => {
                    let after = &prefix[pos + 2..];
                    if after.contains('[') || after.contains(']') {
                        self.link_complete = None;
                        return;
                    }
                    after.to_string()
                }
                None => {
                    self.link_complete = None;
                    return;
                }
            }
        };
        let matches = self.compute_link_matches(&query);
        if matches.is_empty() {
            self.link_complete = None;
            return;
        }
        self.link_complete = Some(LinkComplete {
            query,
            matches,
            selected: 0,
        });
    }

    /// Fuzzy-rank note basenames against `query` for the link popup. An empty
    /// query lists recent notes. Deduplicated by name, capped.
    fn compute_link_matches(&self, query: &str) -> Vec<String> {
        let mut seen = HashSet::new();
        let mut out: Vec<String> = Vec::new();
        if query.is_empty() {
            for (p, _) in self.vault.index.recent_notes() {
                let b = vault::note_basename(&p);
                if seen.insert(b.clone()) {
                    out.push(b);
                }
                if out.len() >= 50 {
                    break;
                }
            }
            return out;
        }
        let matcher = SkimMatcherV2::default();
        let mut scored: Vec<(i64, String)> = Vec::new();
        for (p, _) in self.vault.index.all_notes() {
            let b = vault::note_basename(&p);
            if let Some(s) = matcher.fuzzy_match(&b, query) {
                scored.push((s, b));
            }
        }
        scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        for (_, b) in scored {
            if seen.insert(b.clone()) {
                out.push(b);
            }
            if out.len() >= 50 {
                break;
            }
        }
        out
    }

    /// Move the link-popup selection (wraps).
    pub fn link_complete_move(&mut self, down: bool) {
        if let Some(lc) = self.link_complete.as_mut() {
            let n = lc.matches.len();
            if n == 0 {
                return;
            }
            lc.selected = if down {
                (lc.selected + 1) % n
            } else {
                (lc.selected + n - 1) % n
            };
        }
    }

    /// Accept the highlighted candidate: replace the typed query with the chosen
    /// note name and close the wikilink (`]]`). Returns false if nothing to do.
    pub fn accept_link_complete(&mut self) -> bool {
        let Some(lc) = self.link_complete.take() else {
            return false;
        };
        let Some(target) = lc.matches.get(lc.selected).cloned() else {
            return false;
        };
        let Some(doc) = self.doc.as_mut() else {
            return false;
        };
        doc.history.record(&doc.buffer);
        // Delete the typed query (cursor is right after it), then insert the
        // chosen name plus the closing `]]`.
        for _ in 0..lc.query.graphemes(true).count() {
            doc.buffer.backspace();
        }
        doc.buffer.insert_str(&format!("{target}]]"));
        doc.dirty = true;
        true
    }

    /// Dismiss the link popup without inserting (stay in insert mode).
    pub fn cancel_link_complete(&mut self) {
        self.link_complete = None;
    }

    pub fn open_note(&mut self, path: PathBuf) -> Result<()> {
        // Save current dirty doc silently first? No — let the user save explicitly.
        let text = self.vault.read_note(&path)?;
        let mut doc = Document::from_text(Some(path.clone()), text);
        doc.disk_mtime = vault::file_mtime(&path);
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
        self.save_current_inner(false)
    }

    /// Save unconditionally, overwriting any external change (`:w!`).
    pub fn force_save_current(&mut self) -> Result<()> {
        self.save_current_inner(true)
    }

    /// Save the open document. When `force` is false and the file changed on
    /// disk since we last read/wrote it, this opens a confirm dialog instead of
    /// clobbering the external version (the conflict guard).
    fn save_current_inner(&mut self, force: bool) -> Result<()> {
        let (path, known) = match self.doc.as_ref() {
            Some(d) => (d.path.clone(), d.disk_mtime),
            None => return Ok(()),
        };
        let path = match path {
            Some(p) => p,
            None => self.vault.path_for_new_note("Untitled"),
        };
        // Conflict guard: the file moved underneath us. Ask before overwriting.
        if !force && path.exists() {
            if let (Some(now), Some(prev)) = (vault::file_mtime(&path), known) {
                if now != prev {
                    let rel = vault::note_relpath(&self.vault.root, &path);
                    self.start_confirm(
                        format!(
                            "\"{rel}\" changed on disk since you opened it. \
                             Overwrite and lose the on-disk version?"
                        ),
                        ConfirmAction::OverwriteNote(path),
                    );
                    return Ok(());
                }
            }
        }
        let content = self.doc.as_ref().unwrap().buffer.to_string();
        self.vault.write_note(&path, &content)?;
        self.record_self_write(&path);
        let mt = vault::file_mtime(&path);
        if let Some(d) = self.doc.as_mut() {
            d.path = Some(path.clone());
            d.dirty = false;
            d.disk_mtime = mt;
        }
        self.set_status(format!("Saved {}", vault::note_relpath(&self.vault.root, &path)));
        Ok(())
    }

    /// Record that Onyx just wrote `path`, so the filesystem watcher doesn't
    /// mistake our own save for an external change. Entries expire after a few
    /// seconds; we prune stale ones here too.
    fn record_self_write(&mut self, path: &Path) {
        let now = Instant::now();
        self.recent_self_writes
            .retain(|_, t| now.duration_since(*t) < Duration::from_secs(5));
        self.recent_self_writes.insert(path.to_path_buf(), now);
    }

    /// Reload the open document from disk, discarding the in-memory buffer.
    /// Backs `:e!` and the seamless live-reload of clean buffers.
    pub fn reload_current(&mut self) {
        let Some(path) = self.doc.as_ref().and_then(|d| d.path.clone()) else {
            self.set_status("nothing to reload");
            return;
        };
        match self.vault.read_note(&path) {
            Ok(text) => {
                let mt = vault::file_mtime(&path);
                if let Some(d) = self.doc.as_mut() {
                    d.buffer = Buffer::from_string(text);
                    d.buffer.clamp_cursor();
                    d.history = History::default();
                    d.dirty = false;
                    d.scroll = 0;
                    d.disk_mtime = mt;
                }
                *self.preview_cache.borrow_mut() = None;
                self.set_status(format!(
                    "reloaded {}",
                    vault::note_relpath(&self.vault.root, &path)
                ));
            }
            Err(e) => self.set_status(format!("reload failed: {e}")),
        }
    }

    /// Drain filesystem-watcher events and react to genuinely-external changes:
    /// refresh the tree/index and reconcile the open document. Onyx's own writes
    /// (and anything under a dot-dir like `.git`/`.obsidian`/`.onyx`) are
    /// ignored so we don't reindex in response to ourselves.
    pub fn handle_fs_events(&mut self) {
        let changed = match self.watcher.as_ref() {
            Some(w) => w.drain(),
            None => return,
        };
        if changed.is_empty() {
            return;
        }
        let now = Instant::now();
        self.recent_self_writes
            .retain(|_, t| now.duration_since(*t) < Duration::from_secs(5));

        let external = changed.iter().any(|p| {
            !is_internal_path(p) && !self.recent_self_writes.contains_key(p)
        });
        if !external {
            return;
        }

        // Reflect external creates/deletes/renames in the tree, index, graph.
        self.vault.refresh();
        *self.preview_cache.borrow_mut() = None;
        self.graph_sim = None;
        let len = self.visible_tree().len();
        if self.tree_selected >= len {
            self.tree_selected = len.saturating_sub(1);
        }
        self.reconcile_open_doc();
        if self.database.is_some() {
            self.rebuild_database();
        }
        self.needs_redraw = true;
    }

    /// After an external change, bring the open document back in line with disk:
    /// clean buffers reload seamlessly; dirty buffers are left untouched with a
    /// warning so the user's edits are never silently lost.
    fn reconcile_open_doc(&mut self) {
        let Some(path) = self.doc.as_ref().and_then(|d| d.path.clone()) else {
            return;
        };
        let rel = vault::note_relpath(&self.vault.root, &path);
        let Some(now) = vault::file_mtime(&path) else {
            self.set_status(format!("⚠ {rel} was deleted on disk"));
            return;
        };
        let changed = self
            .doc
            .as_ref()
            .and_then(|d| d.disk_mtime)
            .map(|prev| prev != now)
            .unwrap_or(false);
        if !changed {
            return;
        }
        let dirty = self.doc.as_ref().map(|d| d.dirty).unwrap_or(false);
        if dirty {
            self.set_status(format!(
                "⚠ {rel} changed on disk — unsaved edits kept (:e! to reload, save to overwrite)"
            ));
        } else {
            self.reload_current();
        }
    }

    pub fn create_note(&mut self, title: &str) -> Result<()> {
        let path = self.vault.path_for_new_note(title);
        // Title the note by its file name (not the folder path).
        let heading = vault::note_basename(&path);
        let body = format!("# {heading}\n\n");
        self.vault.write_note(&path, &body)?;
        self.record_self_write(&path);
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
        if self.doc.is_some() {
            order.push(Focus::Editor);
            if self.show_preview {
                order.push(Focus::Preview);
            }
        } else {
            order.push(Focus::Home);
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
            order.push(if self.doc.is_some() {
                Focus::Editor
            } else {
                Focus::Home
            });
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
            ConfirmAction::OverwriteNote(path) => {
                // Only force-save if the open doc still targets the file the
                // user confirmed about (it could have changed while the dialog
                // was up).
                let same = self
                    .doc
                    .as_ref()
                    .and_then(|d| d.path.as_ref())
                    .map(|p| p == &path)
                    .unwrap_or(false);
                if same {
                    if let Err(e) = self.save_current_inner(true) {
                        self.set_status(format!("save failed: {e}"));
                    }
                }
            }
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
                    // No note open → fall back to the Home start page, unless the
                    // user is actively in the tree/another pane.
                    if self.focus == Focus::Editor || self.focus == Focus::Preview {
                        self.focus = Focus::Home;
                        self.home_selected = 0;
                    }
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
                best = Some((deg, p.to_path_buf()));
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
            out.extend(m.outgoing.iter().map(|d| d.to_path_buf()));
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
            if self.vault.index.notes.contains_key(c.as_path()) {
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
                        p.to_path_buf(),
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
        let idx_of: HashMap<&Path, usize> =
            paths.iter().enumerate().map(|(i, p)| (p.as_path(), i)).collect();
        let mut edge_set: HashSet<(usize, usize)> = HashSet::new();
        let mut edges: Vec<(usize, usize, EdgeKind)> = Vec::new();

        // Link edges.
        for (i, p) in paths.iter().enumerate() {
            if let Some(m) = self.vault.index.notes.get(p.as_path()) {
                for dst in &m.outgoing {
                    if let Some(&j) = idx_of.get(dst.as_ref()) {
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
                if let Some(&j) = idx_of.get(nb.as_path()) {
                    let key = if i < j { (i, j) } else { (j, i) };
                    if i != j && !edge_set.contains(&key) && edge_set.insert(key) {
                        edges.push((key.0, key.1, EdgeKind::Tag));
                    }
                }
            }
        }

        let center_idx = center
            .as_ref()
            .and_then(|c| idx_of.get(c.as_path()).copied())
            .unwrap_or(0);
        // Pin the centered note only in local mode; the global earth floats free.
        let pin_center = !self.graph_global;
        GraphSim::new(paths, edges, center_idx, center, self.graph_global, pin_center)
    }

    /// Open the folder at `folder` (absolute) as a Notion-style database view:
    /// its direct-child notes become rows and their frontmatter properties
    /// become columns. No-ops with a status message when the folder is empty.
    pub fn open_database(&mut self, folder: PathBuf) {
        match self.build_database(folder) {
            Some(view) => {
                self.last_focus = self.focus;
                self.database = Some(view);
                self.focus = Focus::Database;
                self.needs_redraw = true;
            }
            None => self.set_status("no notes in that folder to show as a database"),
        }
    }

    /// Build a database view from the index for `folder`'s direct-child notes,
    /// or `None` if there are none. `_schema.md` sidecars are excluded.
    fn build_database(&self, folder: PathBuf) -> Option<DatabaseView> {
        let mut items: Vec<db_view::RowInput> = Vec::new();
        for (p, m) in &self.vault.index.notes {
            if p.parent() != Some(folder.as_path()) {
                continue;
            }
            let base = vault::note_basename(p);
            if base.eq_ignore_ascii_case("_schema") {
                continue;
            }
            let name = if m.title.trim().is_empty() {
                base
            } else {
                m.title.clone()
            };
            items.push((p.to_path_buf(), name, m.properties.clone()));
        }
        if items.is_empty() {
            return None;
        }
        items.sort_by(|a, b| a.0.cmp(&b.0));
        let (columns, rows) = db_view::build_rows(items);
        let group_by = db_view::pick_group_by(&columns, &rows);
        let title = folder
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "vault".to_string());
        Some(DatabaseView {
            folder,
            title,
            mode: db_view::DbViewMode::Table,
            columns,
            rows,
            selected: 0,
            col_offset: 0,
            sort_by: None,
            sort_desc: false,
            group_by,
            board_group: 0,
            board_card: 0,
            filter: String::new(),
            filtering: false,
        })
    }

    /// Rebuild the active database view from the (possibly-changed) index,
    /// preserving the user's mode/sort/group/filter/selection. Called after an
    /// external change refreshes the index.
    pub fn rebuild_database(&mut self) {
        let Some(old) = self.database.take() else {
            return;
        };
        if let Some(mut v) = self.build_database(old.folder.clone()) {
            v.mode = old.mode;
            v.sort_by = old.sort_by;
            v.sort_desc = old.sort_desc;
            v.group_by = old.group_by;
            v.filter = old.filter;
            v.filtering = old.filtering;
            v.selected = old.selected;
            v.col_offset = old.col_offset;
            v.board_group = old.board_group;
            v.board_card = old.board_card;
            v.clamp();
            self.database = Some(v);
        } else {
            // The folder went empty — leave the view closed.
            self.focus = self.center_focus();
        }
    }

    /// Close the database view, returning focus to the editor/home.
    pub fn close_database(&mut self) {
        self.database = None;
        self.focus = self.center_focus();
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
        // Leaving the search overlay cancels any in-flight worker.
        if self.focus == Focus::Search {
            self.cancel_search();
        }
        self.help_open = false;
        self.focus = self.last_focus;
    }

    /// Kick off a vault-wide content search on a background thread. Results
    /// stream back via `search_rx` and are applied by `drain_search`, so the UI
    /// never blocks (even on large vaults).
    pub fn run_search(&mut self) {
        let q = self.search.query.trim().to_string();
        self.search.results.clear();
        self.search.selected = 0;
        if q.is_empty() {
            self.search_rx = None;
            return;
        }
        // New epoch supersedes any in-flight worker (which checks `search_gen`).
        self.search_epoch = self.search_epoch.wrapping_add(1);
        let epoch = self.search_epoch;
        self.search_gen.store(epoch, Ordering::Relaxed);

        let (tx, rx) = mpsc::channel();
        self.search_rx = Some(rx);
        let paths = self.vault.tree.notes.clone();
        let gen = self.search_gen.clone();
        std::thread::spawn(move || search_worker(q, paths, epoch, gen, tx));
        self.needs_redraw = true;
    }

    /// Drain any results the search worker has produced (called each loop tick).
    pub fn drain_search(&mut self) {
        let mut changed = false;
        let mut done = false;
        if let Some(rx) = &self.search_rx {
            loop {
                match rx.try_recv() {
                    Ok(SearchMsg::Hit(e, hit)) => {
                        if e == self.search_epoch && self.search.results.len() < SEARCH_CAP {
                            self.search.results.push(hit);
                            changed = true;
                        }
                    }
                    Ok(SearchMsg::Done(e)) => {
                        if e == self.search_epoch {
                            done = true;
                        }
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        done = true;
                        break;
                    }
                }
            }
        }
        if done {
            self.search_rx = None;
        }
        if changed || done {
            self.needs_redraw = true;
        }
    }

    pub fn search_in_flight(&self) -> bool {
        self.search_rx.is_some()
    }

    /// Abandon any in-flight search (worker stops at its next file check).
    pub fn cancel_search(&mut self) {
        self.search_epoch = self.search_epoch.wrapping_add(1);
        self.search_gen.store(self.search_epoch, Ordering::Relaxed);
        self.search_rx = None;
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
                self.focus = self.center_focus();
            }
            Focus::Database => {
                // First Esc cancels an in-progress filter; the next closes the view.
                if let Some(db) = self.database.as_mut() {
                    if db.filtering {
                        db.filtering = false;
                        db.filter.clear();
                        db.clamp();
                        return;
                    }
                }
                self.close_database();
            }
            Focus::Graph | Focus::Calendar | Focus::Todo => {
                self.focus = self.center_focus();
            }
            // Esc from Home drops to the file tree if it's visible.
            Focus::Home if self.show_left => {
                self.focus = Focus::FileTree;
            }
            Focus::Editor => {
                self.link_complete = None;
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

/// True for paths the watcher should ignore: anything inside (or named as) a
/// dot-entry — `.git`, `.obsidian`, `.onyx`, and our own `.*.onyxtmp` temp
/// files. Real notes are never dot-prefixed, so this filters infrastructure
/// churn without missing user edits.
fn is_internal_path(p: &Path) -> bool {
    p.components()
        .any(|c| c.as_os_str().to_string_lossy().starts_with('.'))
}

/// Max search results retained.
const SEARCH_CAP: usize = 500;

/// Background vault search. Builds a case-insensitive byte regex from the
/// (literal) query and scans each note's bytes line-by-line — no per-line
/// `to_lowercase`/`String` allocation. Bails as soon as a newer search starts
/// (`gen != epoch`) or the cap is hit.
fn search_worker(
    query: String,
    paths: Vec<PathBuf>,
    epoch: u64,
    gen: Arc<AtomicU64>,
    tx: mpsc::Sender<SearchMsg>,
) {
    let re = match regex::bytes::RegexBuilder::new(&regex::escape(&query))
        .case_insensitive(true)
        .build()
    {
        Ok(r) => r,
        Err(_) => {
            let _ = tx.send(SearchMsg::Done(epoch));
            return;
        }
    };
    let mut count = 0usize;
    'files: for path in paths {
        if gen.load(Ordering::Relaxed) != epoch {
            return; // superseded — drop silently
        }
        let Ok(data) = std::fs::read(&path) else {
            continue;
        };
        for (i, line) in data.split(|&b| b == b'\n').enumerate() {
            if re.is_match(line) {
                let preview: String = String::from_utf8_lossy(line)
                    .trim()
                    .chars()
                    .take(160)
                    .collect();
                let hit = SearchHit {
                    path: path.clone(),
                    line: i,
                    preview,
                };
                if tx.send(SearchMsg::Hit(epoch, hit)).is_err() {
                    return; // receiver gone
                }
                count += 1;
                if count >= SEARCH_CAP {
                    break 'files;
                }
            }
        }
    }
    let _ = tx.send(SearchMsg::Done(epoch));
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
