//! Top-level application state and event dispatch.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
    /// Signature of the fold state (collapsed set + selected callout) so toggling
    /// a callout re-renders even though the note text didn't change.
    pub fold_sig: u64,
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
    /// Vault-wide task rollup overlay.
    Tasks,
    /// Inline frontmatter-property editor for the open note.
    Properties,
    /// Google Tasks overlay (pulled from the Tasks API).
    GoogleTasks,
    /// Day-agenda overlay of Google Calendar events.
    Agenda,
    /// Google Drive file browser overlay.
    Drive,
    /// Local LLM assistant (Ollama) chat overlay.
    Ai,
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

/// One insertable block in the `/` slash-command menu.
#[derive(Debug, Clone)]
pub struct SlashItem {
    pub icon: &'static str,
    pub label: String,
    /// Text inserted at the cursor; `after` is inserted following it and the
    /// cursor is then moved back to sit between the two (so e.g. a code fence
    /// lands the caret on its empty body line).
    pub before: String,
    pub after: String,
}

/// State of the `/` slash-command popup (active in insert mode after a `/` at a
/// word boundary). Mirrors the `[[` wikilink popup.
#[derive(Debug, Clone)]
pub struct SlashComplete {
    pub query: String,
    pub matches: Vec<SlashItem>,
    pub selected: usize,
}

/// State of the `#tag` autocomplete popup (insert mode, after `#word`). Mirrors
/// the `[[` wikilink popup; `matches` are existing tag names (no `#`).
#[derive(Debug, Clone)]
pub struct TagComplete {
    pub query: String,
    pub matches: Vec<String>,
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
    OpenBookmark(PathBuf),
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
    /// Nested-structure navigation: parent / sibling / child pages of the note.
    Pages,
    Backlinks,
    Outline,
    Tags,
}

impl SidebarTab {
    pub fn label(&self) -> &'static str {
        match self {
            SidebarTab::Pages => "Pages",
            SidebarTab::Backlinks => "Backlinks",
            SidebarTab::Outline => "Outline",
            SidebarTab::Tags => "Tags",
        }
    }

    pub fn next(self) -> Self {
        match self {
            SidebarTab::Pages => SidebarTab::Backlinks,
            SidebarTab::Backlinks => SidebarTab::Outline,
            SidebarTab::Outline => SidebarTab::Tags,
            SidebarTab::Tags => SidebarTab::Pages,
        }
    }

    pub fn prev(self) -> Self {
        match self {
            SidebarTab::Pages => SidebarTab::Tags,
            SidebarTab::Backlinks => SidebarTab::Pages,
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
    AddEvent,
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
    /// Run the Google OAuth consent flow (suspends the TUI for the browser).
    GoogleAuth,
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

/// Cached "unlinked mentions" for the open note — other notes that mention this
/// note's name/aliases in plain text without linking it. Computed on a worker.
#[derive(Debug, Default, Clone)]
pub struct UnlinkedState {
    /// Note these mentions were computed for (None = nothing computed yet).
    pub for_path: Option<PathBuf>,
    pub mentions: Vec<PathBuf>,
    pub loading: bool,
}

/// Max unlinked mentions retained per note.
const UNLINKED_CAP: usize = 50;

/// One turn in the AI assistant conversation.
#[derive(Debug, Clone)]
pub struct AiTurn {
    pub role: AiRole,
    pub content: String,
    /// Streamed reasoning trace (assistant turns only); shown dimmed.
    pub thinking: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AiRole {
    User,
    Assistant,
}

/// State for the local-LLM (Ollama) chat overlay.
#[derive(Debug, Default)]
pub struct AiState {
    pub turns: Vec<AiTurn>,
    pub input: String,
    /// Lines scrolled up from the bottom (0 = follow the latest output).
    pub scroll: usize,
    pub streaming: bool,
}

/// Messages from the background AI worker, tagged with an epoch so a superseded
/// request's stragglers are ignored.
pub enum AiMsg {
    Delta(u64, crate::integrations::ollama::ChatChunk),
    Done(u64),
    Err(u64, String),
}

/// How much of the current note to include as context (chars).
const AI_NOTE_CONTEXT_CAP: usize = 6000;

/// Idle time after a keystroke before an autocomplete suggestion is requested.
const GHOST_DEBOUNCE: Duration = Duration::from_millis(600);
/// How much text before the cursor to send as autocomplete context.
const GHOST_CONTEXT_CAP: usize = 1500;

/// Progress state for "ask my vault" (RAG) embedding/indexing.
#[derive(Debug, Default)]
pub struct RagState {
    pub building: bool,
    pub done: usize,
    pub total: usize,
}

/// Messages from the background RAG worker (epoch-tagged).
pub enum RagMsg {
    /// (epoch, notes embedded so far, notes needing embedding)
    Progress(u64, usize, usize),
    /// (epoch, question, retrieved chunks) — ready to generate an answer.
    Ready(u64, String, Vec<crate::rag::Retrieved>),
    Err(u64, String),
}

/// How many retrieved chunks to feed the model.
const RAG_TOP_K: usize = 6;

/// In-progress AI rewrite of a buffer range (replaces in place when done).
#[derive(Debug, Default)]
pub struct RewriteState {
    pub active: bool,
    /// Inclusive line range being rewritten.
    pub start: usize,
    pub end: usize,
    /// Accumulated streamed output (applied to the buffer on completion).
    pub acc: String,
}

/// Messages from the background search worker, tagged with the search epoch so
/// stale results (from a superseded query) can be discarded.
pub enum SearchMsg {
    Hit(u64, SearchHit),
    Done(u64),
}

/// A parsed vault-search query: free text plus Obsidian-style filter operators.
/// `tag:rust async` → notes tagged `rust` whose lines contain "async".
/// `path:projects` → notes whose relative path contains "projects".
/// `line:1 foo` → only matches "foo" on line 1.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct SearchQuery {
    /// Free-text needle (may be empty when only filters are given).
    pub needle: String,
    /// `tag:` filters (lowercased, leading `#` stripped) — ANDed together.
    pub tags: Vec<String>,
    /// `path:` filters (lowercased substrings of the relpath) — ANDed together.
    pub paths: Vec<String>,
    /// `line:N` — restrict matches to this 1-based line number.
    pub line: Option<usize>,
}

impl SearchQuery {
    /// True when no free text and no filters were supplied (nothing to search).
    pub fn is_empty(&self) -> bool {
        self.needle.is_empty() && self.tags.is_empty() && self.paths.is_empty()
    }
}

/// Split a raw query into free text + `tag:`/`path:`/`line:` operators.
pub fn parse_search_query(raw: &str) -> SearchQuery {
    let mut q = SearchQuery::default();
    let mut needle = Vec::new();
    for tok in raw.split_whitespace() {
        if let Some(v) = tok.strip_prefix("tag:") {
            let v = v.trim_start_matches('#').to_lowercase();
            if !v.is_empty() {
                q.tags.push(v);
            }
        } else if let Some(v) = tok.strip_prefix("path:") {
            let v = v.to_lowercase();
            if !v.is_empty() {
                q.paths.push(v);
            }
        } else if let Some(v) = tok.strip_prefix("line:") {
            if let Ok(n) = v.parse::<usize>() {
                if n >= 1 {
                    q.line = Some(n);
                }
            }
        } else {
            needle.push(tok);
        }
    }
    q.needle = needle.join(" ");
    q
}

/// Where a Todo-pane row comes from (local checklist vs. Google Tasks).
#[derive(Debug, Clone, Copy)]
pub enum TodoSource {
    Local(usize),
    Google(usize),
}

/// A merged Todo-pane row (local todos + open Google tasks).
#[derive(Debug, Clone)]
pub struct TodoRow {
    pub source: TodoSource,
    pub text: String,
    pub done: bool,
}

/// Result delivered by a background Drive listing: `(requested folder id, files-or-error)`.
pub type DriveListResult =
    (String, std::result::Result<Vec<crate::integrations::gdrive::DriveFile>, String>);

/// Google Drive file-browser overlay state.
#[derive(Debug, Default)]
pub struct DriveBrowser {
    /// Breadcrumb of `(folder id, folder name)`; the last entry is the current
    /// folder. Starts at `("root", "My Drive")`.
    pub stack: Vec<(String, String)>,
    pub files: Vec<crate::integrations::gdrive::DriveFile>,
    pub selected: usize,
    pub loading: bool,
}

impl DriveBrowser {
    pub fn current_id(&self) -> &str {
        self.stack.last().map(|(id, _)| id.as_str()).unwrap_or("root")
    }
    pub fn breadcrumb(&self) -> String {
        self.stack
            .iter()
            .map(|(_, n)| n.as_str())
            .collect::<Vec<_>>()
            .join(" / ")
    }
}

/// One row in the vault-wide task rollup.
#[derive(Debug, Clone)]
pub struct TaskItem {
    pub path: PathBuf,
    pub line: usize,
    pub text: String,
    pub done: bool,
}

#[derive(Debug, Default)]
pub struct TasksState {
    pub items: Vec<TaskItem>,
    pub selected: usize,
}

/// An active inline edit within the property editor.
#[derive(Debug, Clone)]
pub struct PropEdit {
    /// True when adding a new property (the buffer holds `key: value`); false
    /// when editing `key`'s value (the buffer holds just the value).
    pub is_add: bool,
    pub key: String,
    pub buffer: String,
}

/// Inline frontmatter-property editor state for the open note.
#[derive(Debug, Default)]
pub struct PropsEditState {
    pub items: Vec<(String, String)>,
    pub selected: usize,
    pub editing: Option<PropEdit>,
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
    /// Open editor tabs in display order (the active tab's path is `doc.path`).
    pub tab_paths: Vec<PathBuf>,
    /// Background tabs: open documents other than the active one (kept so each
    /// tab preserves its own buffer/cursor/scroll/dirty state).
    pub tabs: Vec<Document>,
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
    // `/` slash-command insert popup (Some while typing `/cmd` at a boundary).
    pub slash_complete: Option<SlashComplete>,
    // `#tag` autocomplete popup (Some while typing `#word` at a boundary).
    pub tag_complete: Option<TagComplete>,

    // Preview fold state for collapsible callouts: indices (document order) of
    // foldable callouts that are collapsed, and the fold cursor in the preview.
    pub preview_collapsed: HashSet<usize>,
    pub preview_fold_sel: usize,

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
    // Unlinked mentions for the open note (background-computed, same epoch/gen
    // cancellation pattern as search). `(epoch, result)` over the channel.
    pub unlinked: UnlinkedState,
    pub unlinked_rx: Option<Receiver<(u64, Vec<PathBuf>)>>,
    pub unlinked_epoch: u64,
    pub unlinked_gen: Arc<AtomicU64>,
    // Local AI assistant (Ollama): streamed deltas over `ai_rx` tagged with
    // `ai_epoch`; `ai_cancel` stops the in-flight worker mid-stream.
    pub ai: AiState,
    pub ai_rx: Option<Receiver<AiMsg>>,
    pub ai_epoch: u64,
    pub ai_cancel: Arc<AtomicBool>,
    /// Sources line to append once the current RAG answer finishes streaming.
    pub ai_pending_sources: Option<String>,
    // "Ask my vault" (RAG): a background worker embeds/indexes the vault then
    // retrieves; results come over `rag_rx` tagged with `rag_epoch`.
    pub rag: RagState,
    pub rag_rx: Option<Receiver<RagMsg>>,
    pub rag_epoch: u64,
    pub rag_gen: Arc<AtomicU64>,
    // AI rewrite of a buffer range (reuses the chat worker; output accumulates
    // and is applied to the buffer in one undo-able edit when streaming ends).
    pub rewrite: RewriteState,
    pub rewrite_rx: Option<Receiver<AiMsg>>,
    pub rewrite_epoch: u64,
    pub rewrite_cancel: Arc<AtomicBool>,
    // Inline autocomplete (ghost text): a debounced completion request fires
    // after a typing pause; the suggestion is shown dimmed after the cursor.
    pub ghost: Option<String>,
    pub ghost_rx: Option<Receiver<(u64, std::result::Result<String, String>)>>,
    pub ghost_epoch: u64,
    pub ghost_cancel: Arc<AtomicBool>,
    /// Buffer revision the current ghost (or in-flight request) is for.
    pub ghost_for_rev: Option<u64>,
    /// When the user last edited in insert mode (debounce timer).
    pub last_edit: Option<Instant>,
    pub prompt: PromptState,
    pub confirm: ConfirmState,
    pub cmdline: CmdlineState,
    pub help_open: bool,
    /// First visible row of the help overlay (it scrolls; clamped by the renderer).
    pub help_scroll: usize,
    /// Line-wise yank register (Visual `y`/`d` → `p`/`P`).
    pub register: String,
    pub graph_focus: Option<PathBuf>,
    /// Force-directed simulation backing the graph view (built lazily).
    pub graph_sim: Option<GraphSim>,
    /// Whether the graph shows the whole vault (true) or a local neighborhood.
    pub graph_global: bool,
    pub calendar: CalendarState,
    pub tasks: TasksState,
    pub props_edit: PropsEditState,
    /// Google Tasks pulled from the API (shared by the overlay + Todo pane).
    pub gtasks: Vec<crate::integrations::gtasks::GTask>,
    pub gtasks_selected: usize,
    /// Background Google-Tasks sync result channel (None when idle).
    pub gtasks_rx: Option<Receiver<std::result::Result<Vec<crate::integrations::gtasks::GTask>, String>>>,
    /// Selection cursor for the merged Todo pane (local + Google).
    pub todo_cursor: usize,

    /// Google Calendar events for the loaded month + which month they're for.
    pub cal_events: Vec<crate::integrations::gcal::CalEvent>,
    pub cal_events_rx: Option<Receiver<std::result::Result<Vec<crate::integrations::gcal::CalEvent>, String>>>,
    pub cal_loaded_month: Option<(i32, u32)>,
    /// Selection in the day-agenda overlay.
    pub agenda_selected: usize,

    /// Google Drive browser (Some while open).
    pub drive: Option<DriveBrowser>,
    /// Background Drive listing: `(folder id requested, result)`.
    pub drive_rx: Option<Receiver<DriveListResult>>,

    /// Active database view (a folder shown as a table/board), or None.
    pub database: Option<DatabaseView>,

    /// When set, the right pane shows this note rendered read-only (a vertical
    /// split) instead of the active note's preview.
    pub split_doc: Option<PathBuf>,

    // Left-column side panes.
    pub quicknote: QuicknoteState,
    pub todos: TodoList,

    /// Pinned/bookmarked notes (absolute paths), shown on the Home page.
    pub bookmarks: Vec<PathBuf>,

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
        let bookmarks = load_bookmarks(&vault);
        // Opt-in: pull Google Tasks into the Todo pane at launch (background).
        let gtasks_rx = if config.google.sync_tasks && config.google.is_configured() {
            Some(spawn_gtasks_fetch(&config.google))
        } else {
            None
        };
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
            tab_paths: Vec::new(),
            tabs: Vec::new(),
            focus: Focus::Home,
            last_focus: Focus::Home,
            home_selected: 0,
            link_complete: None,
            slash_complete: None,
            tag_complete: None,
            preview_collapsed: HashSet::new(),
            preview_fold_sel: 0,
            tree_selected: 0,
            expanded_dirs: expanded,
            expanded_gen: 0,
            tree_view_cache: RefCell::new(None),
            palette: PaletteState::default(),
            switcher: PaletteState::default(),
            search: SearchState::default(),
            unlinked: UnlinkedState::default(),
            unlinked_rx: None,
            unlinked_epoch: 0,
            unlinked_gen: Arc::new(AtomicU64::new(0)),
            ai: AiState::default(),
            ai_rx: None,
            ai_epoch: 0,
            ai_cancel: Arc::new(AtomicBool::new(false)),
            ai_pending_sources: None,
            rag: RagState::default(),
            rag_rx: None,
            rag_epoch: 0,
            rag_gen: Arc::new(AtomicU64::new(0)),
            rewrite: RewriteState::default(),
            rewrite_rx: None,
            rewrite_epoch: 0,
            rewrite_cancel: Arc::new(AtomicBool::new(false)),
            ghost: None,
            ghost_rx: None,
            ghost_epoch: 0,
            ghost_cancel: Arc::new(AtomicBool::new(false)),
            ghost_for_rev: None,
            last_edit: None,
            search_epoch: 0,
            search_gen: Arc::new(AtomicU64::new(0)),
            search_rx: None,
            prompt: PromptState::default(),
            confirm: ConfirmState::default(),
            cmdline: CmdlineState::default(),
            help_open: false,
            help_scroll: 0,
            register: String::new(),
            graph_focus: None,
            graph_sim: None,
            graph_global: true,
            calendar: CalendarState::today(),
            tasks: TasksState::default(),
            props_edit: PropsEditState::default(),
            gtasks: Vec::new(),
            gtasks_selected: 0,
            gtasks_rx,
            todo_cursor: 0,
            cal_events: Vec::new(),
            cal_events_rx: None,
            cal_loaded_month: None,
            agenda_selected: 0,
            drive: None,
            drive_rx: None,
            database: None,
            split_doc: None,
            quicknote: QuicknoteState::new(quicknote_text),
            todos,
            bookmarks,
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

    pub fn is_bookmarked(&self, path: &Path) -> bool {
        self.bookmarks.iter().any(|p| p == path)
    }

    /// Pin/unpin a note; persists to `.onyx/bookmarks.json`.
    pub fn toggle_bookmark(&mut self, path: PathBuf) {
        if let Some(pos) = self.bookmarks.iter().position(|p| p == &path) {
            self.bookmarks.remove(pos);
            self.set_status(format!("unpinned {}", vault::note_basename(&path)));
        } else {
            self.bookmarks.push(path.clone());
            self.set_status(format!("pinned {}", vault::note_basename(&path)));
        }
        self.save_bookmarks();
    }

    /// Pin/unpin the currently-open note.
    pub fn toggle_bookmark_current(&mut self) {
        match self.doc.as_ref().and_then(|d| d.path.clone()) {
            Some(p) => self.toggle_bookmark(p),
            None => self.set_status("no note open to pin"),
        }
    }

    fn save_bookmarks(&self) {
        let rels: Vec<String> = self
            .bookmarks
            .iter()
            .map(|p| vault::note_relpath(&self.vault.root, p))
            .collect();
        if let Ok(json) = serde_json::to_string_pretty(&rels) {
            let path = self.vault.bookmarks_path();
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(path, json);
        }
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
        self.tab_paths.clear();
        self.tabs.clear();
        self.split_doc = None;
        self.database = None;
        self.graph_focus = None;
        self.fullscreen = None;
        self.tree_selected = 0;
        self.sidebar_selected = 0;
        self.todo_cursor = 0;
        self.expanded_dirs.clear();
        self.expanded_dirs.insert(self.vault.root.clone());

        let qn = std::fs::read_to_string(self.vault.quicknote_path()).unwrap_or_default();
        self.quicknote = QuicknoteState::new(qn);
        self.todos = TodoList::load(&self.vault.todos_path());
        self.bookmarks = load_bookmarks(&self.vault);

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
        let folder_hint = |p: &Path| {
            let rel = vault::note_relpath(&self.vault.root, p);
            Path::new(&rel)
                .parent()
                .map(|d| d.to_string_lossy().to_string())
                .filter(|d| !d.is_empty())
                .unwrap_or_default()
        };
        // Pinned notes first (skipping any that vanished).
        for p in self.bookmarks.iter().filter(|p| p.exists()) {
            items.push(HomeItem {
                icon: "★",
                label: vault::note_basename(p),
                hint: folder_hint(p),
                action: HomeAction::OpenBookmark(p.clone()),
            });
        }
        for (p, _) in self.vault.index.recent_notes().into_iter().take(8) {
            items.push(HomeItem {
                icon: "•",
                label: vault::note_basename(&p),
                hint: folder_hint(&p),
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
            HomeAction::OpenRecent(p) | HomeAction::OpenBookmark(p) => {
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
        for (p, m) in self.vault.index.all_notes() {
            let b = vault::note_basename(&p);
            if let Some(s) = matcher.fuzzy_match(&b, query) {
                scored.push((s, b));
            }
            // Aliases are linkable names too.
            for alias in &m.aliases {
                if let Some(s) = matcher.fuzzy_match(alias, query) {
                    scored.push((s, alias.clone()));
                }
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

    /// Recompute the `/` slash-command popup from the cursor context. Active in
    /// insert mode when the cursor sits just after a `/word` whose `/` is at the
    /// start of the line or after whitespace (so URLs/dates/fractions don't
    /// trigger it). Never competes with the `[[` wikilink popup.
    pub fn refresh_slash_complete(&mut self) {
        let in_insert = self
            .doc
            .as_ref()
            .map(|d| d.mode == Mode::Insert)
            .unwrap_or(false);
        if !in_insert || self.link_complete.is_some() {
            self.slash_complete = None;
            return;
        }
        let query = {
            let doc = self.doc.as_ref().unwrap();
            let li = doc.buffer.cursor.line;
            let byte = doc.buffer.col_to_byte(li, doc.buffer.cursor.col);
            let prefix = &doc.buffer.line(li)[..byte];
            match prefix.rfind('/') {
                Some(pos) => {
                    let boundary = pos == 0
                        || prefix[..pos]
                            .chars()
                            .next_back()
                            .map(|c| c.is_whitespace())
                            .unwrap_or(true);
                    let after = &prefix[pos + 1..];
                    if !boundary || after.contains(char::is_whitespace) {
                        self.slash_complete = None;
                        return;
                    }
                    after.to_string()
                }
                None => {
                    self.slash_complete = None;
                    return;
                }
            }
        };
        let matches = compute_slash_matches(&query);
        if matches.is_empty() {
            self.slash_complete = None;
            return;
        }
        self.slash_complete = Some(SlashComplete {
            query,
            matches,
            selected: 0,
        });
    }

    /// Move the slash-popup selection (wraps).
    pub fn slash_complete_move(&mut self, down: bool) {
        if let Some(sc) = self.slash_complete.as_mut() {
            let n = sc.matches.len();
            if n == 0 {
                return;
            }
            sc.selected = if down {
                (sc.selected + 1) % n
            } else {
                (sc.selected + n - 1) % n
            };
        }
    }

    /// Accept the highlighted slash item: replace the typed `/query` with the
    /// block snippet and place the caret inside it. Returns false if nothing to do.
    pub fn accept_slash_complete(&mut self) -> bool {
        let Some(sc) = self.slash_complete.take() else {
            return false;
        };
        let Some(item) = sc.matches.get(sc.selected).cloned() else {
            return false;
        };
        let Some(doc) = self.doc.as_mut() else {
            return false;
        };
        doc.history.record(&doc.buffer);
        // Delete the typed `/query` (cursor is right after it).
        for _ in 0..(sc.query.graphemes(true).count() + 1) {
            doc.buffer.backspace();
        }
        doc.buffer.insert_str(&item.before);
        if !item.after.is_empty() {
            doc.buffer.insert_str(&item.after);
            for _ in 0..item.after.graphemes(true).count() {
                doc.buffer.move_left();
            }
        }
        doc.dirty = true;
        true
    }

    /// Dismiss the slash popup without inserting (stay in insert mode).
    pub fn cancel_slash_complete(&mut self) {
        self.slash_complete = None;
    }

    /// Recompute the `#tag` autocomplete popup. Active in insert mode after a
    /// `#word` (word at a boundary, tag-valid chars). Never competes with the
    /// `[[` or `/` popups.
    pub fn refresh_tag_complete(&mut self) {
        let in_insert = self
            .doc
            .as_ref()
            .map(|d| d.mode == Mode::Insert)
            .unwrap_or(false);
        if !in_insert || self.link_complete.is_some() || self.slash_complete.is_some() {
            self.tag_complete = None;
            return;
        }
        let query = {
            let doc = self.doc.as_ref().unwrap();
            let li = doc.buffer.cursor.line;
            let byte = doc.buffer.col_to_byte(li, doc.buffer.cursor.col);
            let prefix = &doc.buffer.line(li)[..byte];
            match prefix.rfind('#') {
                Some(pos) => {
                    let boundary = pos == 0
                        || prefix[..pos]
                            .chars()
                            .next_back()
                            .map(|c| c.is_whitespace())
                            .unwrap_or(true);
                    let after = &prefix[pos + 1..];
                    let valid = !after.is_empty()
                        && after.chars().next().map(|c| c.is_ascii_alphanumeric()).unwrap_or(false)
                        && after
                            .chars()
                            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '/');
                    if !boundary || !valid {
                        self.tag_complete = None;
                        return;
                    }
                    after.to_string()
                }
                None => {
                    self.tag_complete = None;
                    return;
                }
            }
        };
        let matcher = SkimMatcherV2::default();
        let mut scored: Vec<(i64, String)> = self
            .vault
            .index
            .all_tags()
            .into_iter()
            .filter_map(|(t, _)| matcher.fuzzy_match(&t, &query).map(|s| (s, t)))
            .collect();
        scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        let matches: Vec<String> = scored.into_iter().map(|(_, t)| t).take(50).collect();
        if matches.is_empty() {
            self.tag_complete = None;
            return;
        }
        self.tag_complete = Some(TagComplete {
            query,
            matches,
            selected: 0,
        });
    }

    pub fn tag_complete_move(&mut self, down: bool) {
        if let Some(tc) = self.tag_complete.as_mut() {
            let n = tc.matches.len();
            if n == 0 {
                return;
            }
            tc.selected = if down {
                (tc.selected + 1) % n
            } else {
                (tc.selected + n - 1) % n
            };
        }
    }

    /// Accept the highlighted tag: replace the typed `#query` fragment with the
    /// chosen tag (the `#` stays). Returns false if nothing to do.
    pub fn accept_tag_complete(&mut self) -> bool {
        let Some(tc) = self.tag_complete.take() else {
            return false;
        };
        let Some(tag) = tc.matches.get(tc.selected).cloned() else {
            return false;
        };
        let Some(doc) = self.doc.as_mut() else {
            return false;
        };
        doc.history.record(&doc.buffer);
        for _ in 0..tc.query.graphemes(true).count() {
            doc.buffer.backspace();
        }
        doc.buffer.insert_str(&format!("{tag} "));
        doc.dirty = true;
        true
    }

    pub fn cancel_tag_complete(&mut self) {
        self.tag_complete = None;
    }

    /// Headings of the open note as `(0-based line, level, text)`, skipping code
    /// fences. Powers the Outline sidebar tab and its jump-to-heading.
    pub fn outline_headings(&self) -> Vec<(usize, u8, String)> {
        let Some(doc) = self.doc.as_ref() else {
            return Vec::new();
        };
        let src = doc.buffer.to_string();
        let mut out = Vec::new();
        let mut in_code = false;
        for (i, line) in src.lines().enumerate() {
            let t = line.trim_start();
            if t.starts_with("```") || t.starts_with("~~~") {
                in_code = !in_code;
                continue;
            }
            if in_code {
                continue;
            }
            let h = t.chars().take_while(|c| *c == '#').count();
            if (1..=6).contains(&h) && t.chars().nth(h) == Some(' ') {
                out.push((i, h as u8, t[h + 1..].trim().to_string()));
            }
        }
        out
    }

    /// Move the editor cursor to the `idx`-th heading and focus the editor.
    pub fn jump_to_heading(&mut self, idx: usize) {
        let Some(&(line, _, _)) = self.outline_headings().get(idx) else {
            return;
        };
        if let Some(doc) = self.doc.as_mut() {
            let line = line.min(doc.buffer.line_count().saturating_sub(1));
            doc.buffer.cursor.line = line;
            doc.buffer.cursor.col = 0;
            doc.buffer.goal_col = 0;
            doc.scroll = line;
        }
        self.focus = Focus::Editor;
    }

    /// Toggle a `- [ ]` checkbox on the cursor's current line.
    pub fn toggle_task_on_current_line(&mut self) {
        let Some(doc) = self.doc.as_mut() else {
            return;
        };
        let li = doc.buffer.cursor.line;
        let line = doc.buffer.line(li).to_string();
        match crate::markdown::parse::toggle_task_marker(&line) {
            Some(new) => {
                doc.history.record(&doc.buffer);
                doc.buffer.replace_line(li, &new);
                doc.dirty = true;
            }
            None => self.set_status("not a task line (\"- [ ]\")"),
        }
    }

    /// Seed the preview's fold state from a note's source: foldable callouts
    /// marked `-` start collapsed; the fold cursor resets to the top.
    fn seed_preview_folds(&mut self, source: &str) {
        let defaults = crate::markdown::foldable_callouts(source);
        self.preview_collapsed = defaults
            .iter()
            .enumerate()
            .filter(|(_, collapsed)| **collapsed)
            .map(|(i, _)| i)
            .collect();
        self.preview_fold_sel = 0;
    }

    /// Number of foldable callouts in the open note (for clamping the fold cursor).
    pub fn foldable_count(&self) -> usize {
        self.doc
            .as_ref()
            .map(|d| crate::markdown::foldable_callouts(&d.buffer.to_string()).len())
            .unwrap_or(0)
    }

    /// Move the preview's fold cursor among foldable callouts (no wrap).
    pub fn preview_fold_move(&mut self, delta: i64) {
        let n = self.foldable_count();
        if n == 0 {
            return;
        }
        let cur = self.preview_fold_sel.min(n - 1) as i64;
        self.preview_fold_sel = (cur + delta).clamp(0, n as i64 - 1) as usize;
        *self.preview_cache.borrow_mut() = None;
        self.needs_redraw = true;
    }

    /// Collapse/expand the foldable callout under the preview's fold cursor.
    pub fn preview_fold_toggle(&mut self) {
        let n = self.foldable_count();
        if n == 0 {
            self.set_status("no collapsible callouts in this note");
            return;
        }
        let idx = self.preview_fold_sel.min(n - 1);
        if !self.preview_collapsed.remove(&idx) {
            self.preview_collapsed.insert(idx);
        }
        *self.preview_cache.borrow_mut() = None;
        self.needs_redraw = true;
    }

    pub fn open_note(&mut self, path: PathBuf) -> Result<()> {
        // Already the active tab? Nothing to do.
        if self.doc.as_ref().and_then(|d| d.path.as_ref()) == Some(&path) {
            return Ok(());
        }
        // The current note becomes a background tab (keeping its buffer state).
        self.stash_active();
        // If `path` is already an open tab, re-activate its stashed document.
        if let Some(pos) = self
            .tabs
            .iter()
            .position(|d| d.path.as_deref() == Some(path.as_path()))
        {
            let doc = self.tabs.remove(pos);
            self.activate_doc(doc, path);
            return Ok(());
        }
        // Otherwise read it fresh and add a new tab.
        let text = self.vault.read_note(&path)?;
        let mut doc = Document::from_text(Some(path.clone()), text);
        doc.disk_mtime = vault::file_mtime(&path);
        if !self.tab_paths.iter().any(|p| p == &path) {
            self.tab_paths.push(path.clone());
        }
        self.activate_doc(doc, path);
        Ok(())
    }

    /// Stash the active document as a background tab (no-op for a pathless
    /// scratch buffer, which is simply dropped).
    fn stash_active(&mut self) {
        if let Some(doc) = self.doc.take() {
            if let Some(p) = doc.path.clone() {
                if !self.tab_paths.iter().any(|x| x == &p) {
                    self.tab_paths.push(p);
                }
                self.tabs.push(doc);
            }
        }
    }

    /// Make `doc` (for `path`) the active document and update derived state.
    fn activate_doc(&mut self, doc: Document, path: PathBuf) {
        self.seed_preview_folds(&doc.buffer.to_string());
        self.doc = Some(doc);
        self.focus = Focus::Editor;
        self.set_status(format!("Opened {}", vault::note_relpath(&self.vault.root, &path)));
        self.graph_focus = Some(path);
        if !self.graph_global {
            self.graph_sim = None;
        }
        self.sidebar_selected = 0;
    }

    /// Open tabs as `(path, is_active, dirty)` in display order — for the tab bar.
    pub fn tab_infos(&self) -> Vec<(PathBuf, bool, bool)> {
        self.tab_paths
            .iter()
            .map(|p| {
                let active = self.doc.as_ref().and_then(|d| d.path.as_ref()) == Some(p);
                let dirty = if active {
                    self.doc.as_ref().map(|d| d.dirty).unwrap_or(false)
                } else {
                    self.tabs
                        .iter()
                        .find(|d| d.path.as_deref() == Some(p.as_path()))
                        .map(|d| d.dirty)
                        .unwrap_or(false)
                };
                (p.clone(), active, dirty)
            })
            .collect()
    }

    /// Switch to the next/prev tab (wraps).
    pub fn cycle_tab(&mut self, dir: i64) {
        if self.tab_paths.len() < 2 {
            return;
        }
        let Some(cur) = self.doc.as_ref().and_then(|d| d.path.clone()) else {
            return;
        };
        let idx = self.tab_paths.iter().position(|p| p == &cur).unwrap_or(0) as i64;
        let n = self.tab_paths.len() as i64;
        let next = (((idx + dir) % n) + n) % n;
        let target = self.tab_paths[next as usize].clone();
        let _ = self.open_note(target);
    }

    /// Close the active tab (won't discard unsaved edits unless `force`),
    /// activating an adjacent tab or falling back to Home.
    pub fn close_current_tab(&mut self, force: bool) {
        let dirty = self.doc.as_ref().map(|d| d.dirty).unwrap_or(false);
        if dirty && !force {
            self.set_status("unsaved changes — :w to save, or :bd! to discard");
            return;
        }
        let cur = self.doc.as_ref().and_then(|d| d.path.clone());
        self.doc = None;
        if let Some(cur) = cur {
            if let Some(i) = self.tab_paths.iter().position(|p| p == &cur) {
                self.tab_paths.remove(i);
                let next = self
                    .tab_paths
                    .get(i)
                    .or_else(|| self.tab_paths.get(i.wrapping_sub(1)))
                    .cloned();
                if let Some(np) = next {
                    if let Some(pos) =
                        self.tabs.iter().position(|d| d.path.as_deref() == Some(np.as_path()))
                    {
                        let doc = self.tabs.remove(pos);
                        self.activate_doc(doc, np);
                        return;
                    }
                }
            }
        }
        self.focus = self.center_focus();
    }

    /// Drop a path from the tab set entirely (e.g. when its file is deleted).
    pub fn forget_tab(&mut self, path: &Path) {
        self.tab_paths.retain(|p| p != path);
        self.tabs.retain(|d| d.path.as_deref() != Some(path));
        if self.split_doc.as_deref() == Some(path) {
            self.split_doc = None;
        }
    }

    /// The first open tab that isn't the active note (for `:vsplit`).
    fn next_other_tab(&self) -> Option<PathBuf> {
        let cur = self.doc.as_ref().and_then(|d| d.path.clone());
        self.tab_paths.iter().find(|p| Some(p.as_path()) != cur.as_deref()).cloned()
    }

    /// Toggle the split view: off if on, else show another open note alongside.
    pub fn toggle_split(&mut self) {
        if self.split_doc.is_some() {
            self.split_doc = None;
            return;
        }
        match self.next_other_tab() {
            Some(p) => {
                self.split_doc = Some(p);
                self.show_preview = true;
            }
            None => self.set_status("open another note first to split"),
        }
    }

    /// Show `path` in the split pane.
    pub fn split_with(&mut self, path: PathBuf) {
        self.split_doc = Some(path);
        self.show_preview = true;
    }

    /// Swap the active note with the split note.
    pub fn swap_split(&mut self) {
        if let Some(sp) = self.split_doc.clone() {
            let prev = self.doc.as_ref().and_then(|d| d.path.clone());
            let _ = self.open_note(sp);
            self.split_doc = prev;
        }
    }

    /// The split note's `(name, content)` — from its open buffer if it's a tab,
    /// else read from disk.
    pub fn split_content(&self) -> Option<(String, String)> {
        let path = self.split_doc.as_ref()?;
        let name = vault::note_basename(path);
        if self.doc.as_ref().and_then(|d| d.path.as_ref()) == Some(path) {
            return Some((name, self.doc.as_ref().unwrap().buffer.to_string()));
        }
        if let Some(d) = self.tabs.iter().find(|d| d.path.as_deref() == Some(path.as_path())) {
            return Some((name, d.buffer.to_string()));
        }
        self.vault.read_note(path).ok().map(|c| (name, c))
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
        // A Drive-backed buffer uploads back to Drive instead of writing locally.
        if let Some(id) = self.doc.as_ref().and_then(|d| d.drive_id.clone()) {
            return self.save_drive_doc(&id);
        }
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
                self.seed_preview_folds(&text);
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
        self.help_scroll = 0;
    }

    /// Scroll the help overlay by `delta` rows (clamped to ≥0; the renderer caps
    /// the upper bound against the viewport so it can't scroll past the end).
    pub fn help_scroll_by(&mut self, delta: i64) {
        self.help_scroll = (self.help_scroll as i64 + delta).max(0) as usize;
        self.needs_redraw = true;
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
                // Forget any open tabs at/under the deleted path.
                let affected: Vec<PathBuf> = self
                    .tab_paths
                    .iter()
                    .filter(|p| *p == path || p.starts_with(path))
                    .cloned()
                    .collect();
                let cleared = self
                    .doc
                    .as_ref()
                    .and_then(|d| d.path.as_ref())
                    .map(|p| p == path || p.starts_with(path))
                    .unwrap_or(false);
                if cleared {
                    self.doc = None;
                }
                for p in &affected {
                    self.forget_tab(p);
                }
                if cleared {
                    // Activate an adjacent surviving tab, else fall back to Home.
                    if let Some(np) = self.tab_paths.first().cloned() {
                        if let Some(pos) =
                            self.tabs.iter().position(|d| d.path.as_deref() == Some(np.as_path()))
                        {
                            let doc = self.tabs.remove(pos);
                            self.activate_doc(doc, np);
                        }
                    } else if self.focus == Focus::Editor || self.focus == Focus::Preview {
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

    /// Move the editor|preview divider by `delta` percentage points (the editor's
    /// share), clamped to [20, 80]. The new ratio is persisted to config.
    pub fn resize_editor_split(&mut self, delta: i16) {
        let cur = self.config.layout.editor_split_percent.clamp(20, 80) as i16;
        let next = (cur + delta).clamp(20, 80) as u16;
        if next != self.config.layout.editor_split_percent {
            self.config.layout.editor_split_percent = next;
            let _ = self.config.save();
            self.needs_redraw = true;
        }
        if self.show_preview {
            self.set_status(format!("editor {next}% · preview {}%", 100 - next));
        } else {
            self.set_status(format!(
                "editor {next}% · preview {}% (preview hidden — Ctrl-E to show)",
                100 - next
            ));
        }
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

    /// Set (or remove, with `value = None`) a top-level frontmatter property on a
    /// note file, then reindex so views reflect it.
    fn set_note_property(&mut self, path: &Path, key: &str, value: Option<&str>) -> Result<()> {
        let content = self.vault.read_note(path)?;
        let updated = crate::markdown::parse::set_frontmatter_property(&content, key, value);
        if updated != content {
            self.vault.write_note(path, &updated)?;
            self.record_self_write(path);
            self.vault.refresh();
            // Keep an open, clean copy of this note in sync with the new disk text.
            if self.doc.as_ref().and_then(|d| d.path.as_ref()) == Some(&path.to_path_buf())
                && self.doc.as_ref().map(|d| !d.dirty).unwrap_or(false)
            {
                self.reload_current();
            }
        }
        Ok(())
    }

    /// Move the selected board card to the previous/next group, rewriting that
    /// note's group-by frontmatter property to the new group's value (editable
    /// kanban). `dir` is -1 (prev) or +1 (next).
    pub fn board_move_card(&mut self, dir: i64) {
        let (key, path, target_label, value) = {
            let Some(db) = self.database.as_ref() else {
                return;
            };
            if db.mode != db_view::DbViewMode::Board {
                self.set_status("switch to board mode (t) to move cards");
                return;
            }
            let Some(key) = db.group_by.clone() else {
                self.set_status("pick a group-by column first ([ / ])");
                return;
            };
            let groups = db.groups();
            let target_gi = db.board_group as i64 + dir;
            if target_gi < 0 || target_gi as usize >= groups.len() {
                return;
            }
            let target_label = groups[target_gi as usize].0.clone();
            let Some((_, idxs)) = groups.get(db.board_group) else {
                return;
            };
            let Some(&ri) = idxs.get(db.board_card) else {
                return;
            };
            let path = db.rows[ri].path.clone();
            // The synthetic "—" group means "no value" → clear the property.
            let value = (target_label != "—").then(|| target_label.clone());
            (key, path, target_label, value)
        };

        if let Err(e) = self.set_note_property(&path, &key, value.as_deref()) {
            self.set_status(format!("move failed: {e}"));
            return;
        }
        self.rebuild_database();
        // Follow the moved card to its new group.
        if let Some(db) = self.database.as_mut() {
            let groups = db.groups();
            let mut found = None;
            for (gi, (_, idxs)) in groups.iter().enumerate() {
                if let Some(ci) = idxs.iter().position(|&i| db.rows[i].path == path) {
                    found = Some((gi, ci));
                    break;
                }
            }
            if let Some((gi, ci)) = found {
                db.board_group = gi;
                db.board_card = ci;
            }
        }
        self.set_status(format!("moved to {target_label}"));
    }

    /// Import an unzipped Notion "Markdown & CSV" export into the vault under
    /// `Notion Import/`, cleaning hash-suffixed names, rewriting links to
    /// wikilinks, and turning CSV databases into note folders with frontmatter.
    pub fn import_notion(&mut self, src: &Path) {
        if !src.exists() {
            self.set_status(format!("no such folder: {}", src.display()));
            return;
        }
        if src.is_file() {
            let hint = if src.extension().map(|e| e == "zip").unwrap_or(false) {
                " — unzip it first, then point at the folder"
            } else {
                ""
            };
            self.set_status(format!("expected an export folder, not a file{hint}"));
            return;
        }
        let dest = self.vault.root.join("Notion Import");
        match crate::notion_import::import_export(src, &dest) {
            Ok(r) => {
                self.vault.refresh();
                *self.preview_cache.borrow_mut() = None;
                self.graph_sim = None;
                let extra = if r.collisions > 0 {
                    format!(", {} renamed", r.collisions)
                } else {
                    String::new()
                };
                let dest_name = r
                    .dest
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| "Notion Import".to_string());
                self.set_status(format!(
                    "imported {} notes, {} databases, {} attachments → {dest_name}/{extra}",
                    r.notes, r.databases, r.attachments
                ));
            }
            Err(e) => self.set_status(format!("import failed: {e}")),
        }
    }

    /// Scan the whole vault for task checkboxes and open the rollup overlay
    /// (open tasks first, then completed). Reads files synchronously.
    pub fn open_tasks(&mut self) {
        use crate::markdown::parse::task_line;
        let mut items: Vec<TaskItem> = Vec::new();
        'outer: for path in &self.vault.tree.notes {
            let Ok(content) = std::fs::read_to_string(path) else {
                continue;
            };
            let mut in_code = false;
            for (i, line) in content.lines().enumerate() {
                let t = line.trim_start();
                if t.starts_with("```") || t.starts_with("~~~") {
                    in_code = !in_code;
                    continue;
                }
                if in_code {
                    continue;
                }
                if let Some((done, text)) = task_line(line) {
                    if !text.is_empty() {
                        items.push(TaskItem {
                            path: path.clone(),
                            line: i,
                            text: text.to_string(),
                            done,
                        });
                    }
                }
                if items.len() >= 5000 {
                    break 'outer;
                }
            }
        }
        // Open tasks first, then done; stable within by path then line.
        items.sort_by(|a, b| {
            a.done
                .cmp(&b.done)
                .then_with(|| a.path.cmp(&b.path))
                .then_with(|| a.line.cmp(&b.line))
        });
        let open = items.iter().filter(|t| !t.done).count();
        self.tasks = TasksState { items, selected: 0 };
        self.last_focus = self.focus;
        self.focus = Focus::Tasks;
        self.set_status(format!("{} tasks · {open} open", self.tasks.items.len()));
    }

    pub fn tasks_move(&mut self, delta: i64) {
        let n = self.tasks.items.len();
        if n == 0 {
            return;
        }
        let cur = self.tasks.selected.min(n - 1) as i64;
        self.tasks.selected = (cur + delta).clamp(0, n as i64 - 1) as usize;
    }

    /// Open the selected task's note with the cursor on its line.
    pub fn tasks_open_selected(&mut self) {
        let Some(item) = self.tasks.items.get(self.tasks.selected).cloned() else {
            return;
        };
        if let Err(e) = self.open_note(item.path) {
            self.set_status(format!("open failed: {e}"));
            return;
        }
        if let Some(doc) = self.doc.as_mut() {
            let line = item.line.min(doc.buffer.line_count().saturating_sub(1));
            doc.buffer.cursor.line = line;
            doc.buffer.cursor.col = 0;
            doc.buffer.goal_col = 0;
            doc.scroll = line;
        }
        self.focus = Focus::Editor;
    }

    /// Open the inline frontmatter-property editor for the current note.
    pub fn open_props_editor(&mut self) {
        if self.doc.as_ref().and_then(|d| d.path.as_ref()).is_none() {
            self.set_status("open a note to edit its properties");
            return;
        }
        self.props_edit = PropsEditState::default();
        self.rebuild_props_items();
        self.last_focus = self.focus;
        self.focus = Focus::Properties;
    }

    fn rebuild_props_items(&mut self) {
        let src = self
            .doc
            .as_ref()
            .map(|d| d.buffer.to_string())
            .unwrap_or_default();
        self.props_edit.items = crate::markdown::parse::extract_frontmatter_properties(&src)
            .into_iter()
            .map(|(k, v)| (k, v.join(", ")))
            .collect();
        if self.props_edit.selected >= self.props_edit.items.len() {
            self.props_edit.selected = self.props_edit.items.len().saturating_sub(1);
        }
    }

    /// Apply a frontmatter property change to the *open buffer* (so it joins the
    /// note's undo history and is saved normally), then re-read the list.
    fn set_open_doc_property(&mut self, key: &str, value: Option<&str>) {
        if let Some(doc) = self.doc.as_mut() {
            let content = doc.buffer.to_string();
            let updated = crate::markdown::parse::set_frontmatter_property(&content, key, value);
            if updated != content {
                doc.history.record(&doc.buffer);
                let cur = doc.buffer.cursor;
                doc.buffer = Buffer::from_string(updated);
                doc.buffer.cursor = cur;
                doc.buffer.clamp_cursor();
                doc.dirty = true;
            }
        }
        *self.preview_cache.borrow_mut() = None;
        self.rebuild_props_items();
    }

    pub fn props_move(&mut self, delta: i64) {
        let n = self.props_edit.items.len();
        if n == 0 {
            return;
        }
        let cur = self.props_edit.selected.min(n - 1) as i64;
        self.props_edit.selected = (cur + delta).clamp(0, n as i64 - 1) as usize;
    }

    pub fn props_begin_edit(&mut self) {
        if let Some((k, v)) = self.props_edit.items.get(self.props_edit.selected).cloned() {
            self.props_edit.editing = Some(PropEdit {
                is_add: false,
                key: k,
                buffer: v,
            });
        }
    }

    pub fn props_begin_add(&mut self) {
        self.props_edit.editing = Some(PropEdit {
            is_add: true,
            key: String::new(),
            buffer: String::new(),
        });
    }

    pub fn props_delete_selected(&mut self) {
        if let Some((k, _)) = self.props_edit.items.get(self.props_edit.selected).cloned() {
            self.set_open_doc_property(&k, None);
        }
    }

    /// Commit the active inline edit.
    pub fn props_commit_edit(&mut self) {
        let Some(edit) = self.props_edit.editing.take() else {
            return;
        };
        if edit.is_add {
            // Parse `key: value` (or `key = value`).
            let raw = edit.buffer.trim();
            let split = raw.find(':').or_else(|| raw.find('='));
            if let Some(i) = split {
                let key = raw[..i].trim().to_string();
                let val = raw[i + 1..].trim().to_string();
                if !key.is_empty() {
                    self.set_open_doc_property(&key, Some(&val));
                }
            } else if !raw.is_empty() {
                self.set_open_doc_property(raw, Some(""));
            }
        } else {
            self.set_open_doc_property(&edit.key, Some(edit.buffer.trim()));
        }
    }

    /// Queue the Google OAuth consent flow (the event loop runs it suspended).
    pub fn request_google_auth(&mut self) {
        if !self.config.google.is_configured() {
            self.set_status("set [google] client_id/client_secret in config.toml, then :google auth");
            return;
        }
        self.pending_external = Some(PendingExternal::GoogleAuth);
    }

    /// Fetch Google Tasks (blocking) and open the overlay.
    pub fn open_gtasks(&mut self) {
        let g = self.config.google.clone();
        if !g.is_configured() {
            self.set_status("set [google] client_id/client_secret in config.toml first");
            return;
        }
        let path = crate::config::Config::google_token_path();
        self.set_status("fetching Google Tasks…");
        match crate::integrations::gtasks::fetch_all(&g.client_id, &g.client_secret, &path) {
            Ok(tasks) => {
                let open = tasks.iter().filter(|t| !t.completed).count();
                self.gtasks = tasks;
                self.gtasks_selected = 0;
                self.last_focus = self.focus;
                self.focus = Focus::GoogleTasks;
                self.set_status(format!("{} Google tasks · {open} open", self.gtasks.len()));
            }
            Err(e) => self.set_status(format!("Google Tasks: {e}")),
        }
    }

    pub fn gtasks_move(&mut self, delta: i64) {
        let n = self.gtasks.len();
        if n == 0 {
            return;
        }
        let cur = self.gtasks_selected.min(n - 1) as i64;
        self.gtasks_selected = (cur + delta).clamp(0, n as i64 - 1) as usize;
    }

    /// Pull the selected Google task into the quicknote scratch as a checkbox.
    pub fn gtasks_pull_selected(&mut self) {
        let Some(t) = self.gtasks.get(self.gtasks_selected) else {
            return;
        };
        let mark = if t.completed { "x" } else { " " };
        let title = t.title.clone();
        let line = format!("- [{mark}] {title}\n");
        let buf = self.quicknote.buffer.to_string();
        let joined = if buf.is_empty() || buf.ends_with('\n') {
            format!("{buf}{line}")
        } else {
            format!("{buf}\n{line}")
        };
        self.quicknote.buffer = Buffer::from_string(joined);
        self.quicknote.dirty = true;
        self.save_quicknote();
        self.set_status(format!("pulled \"{title}\" into quicknote"));
    }

    /// Set a Google task (by index into `gtasks`) complete/incomplete via PATCH.
    fn gtasks_set_completed_index(&mut self, idx: usize, target: bool) {
        let Some(t) = self.gtasks.get(idx).cloned() else {
            return;
        };
        let g = self.config.google.clone();
        let path = crate::config::Config::google_token_path();
        match crate::integrations::gtasks::set_completed(
            &g.client_id, &g.client_secret, &path, &t.list_id, &t.id, target,
        ) {
            Ok(()) => {
                if let Some(tm) = self.gtasks.get_mut(idx) {
                    tm.completed = target;
                }
                self.set_status(if target {
                    format!("✓ completed \"{}\"", t.title)
                } else {
                    format!("reopened \"{}\"", t.title)
                });
            }
            Err(e) => self.set_status(format!("Google Tasks: {e}")),
        }
    }

    /// Delete a Google task (by index into `gtasks`) via DELETE.
    fn gtasks_delete_index(&mut self, idx: usize) {
        let Some(t) = self.gtasks.get(idx).cloned() else {
            return;
        };
        let g = self.config.google.clone();
        let path = crate::config::Config::google_token_path();
        match crate::integrations::gtasks::delete_task(
            &g.client_id, &g.client_secret, &path, &t.list_id, &t.id,
        ) {
            Ok(()) => {
                self.gtasks.remove(idx);
                self.set_status(format!("deleted \"{}\"", t.title));
            }
            Err(e) => self.set_status(format!("Google Tasks: {e}")),
        }
    }

    /// Toggle the selected Google task in the overlay (two-way).
    pub fn gtasks_toggle_selected(&mut self) {
        let target = self
            .gtasks
            .get(self.gtasks_selected)
            .map(|t| !t.completed)
            .unwrap_or(true);
        self.gtasks_set_completed_index(self.gtasks_selected, target);
    }

    /// Delete the selected Google task in the overlay (two-way).
    pub fn gtasks_delete_selected(&mut self) {
        self.gtasks_delete_index(self.gtasks_selected);
        if self.gtasks_selected >= self.gtasks.len() {
            self.gtasks_selected = self.gtasks.len().saturating_sub(1);
        }
    }

    // --- Merged Todo pane (local todos + Google tasks) -----------------------

    /// The Todo pane's rows: every local todo, then *open* Google tasks.
    pub fn todo_rows(&self) -> Vec<TodoRow> {
        let mut rows: Vec<TodoRow> = self
            .todos
            .items
            .iter()
            .enumerate()
            .map(|(i, it)| TodoRow {
                source: TodoSource::Local(i),
                text: it.text.clone(),
                done: it.done,
            })
            .collect();
        for (i, t) in self.gtasks.iter().enumerate() {
            if !t.completed {
                rows.push(TodoRow {
                    source: TodoSource::Google(i),
                    text: t.title.clone(),
                    done: false,
                });
            }
        }
        rows
    }

    pub fn todo_move(&mut self, delta: i64) {
        let n = self.todo_rows().len();
        if n == 0 {
            self.todo_cursor = 0;
            return;
        }
        let cur = self.todo_cursor.min(n - 1) as i64;
        self.todo_cursor = (cur + delta).clamp(0, n as i64 - 1) as usize;
    }

    /// The source of the currently-selected Todo-pane row.
    pub fn todo_selected_source(&self) -> Option<TodoSource> {
        self.todo_rows().get(self.todo_cursor).map(|r| r.source)
    }

    /// Toggle the selected Todo-pane row (local → todos.md; Google → PATCH).
    pub fn todo_toggle_selected(&mut self) {
        match self.todo_selected_source() {
            Some(TodoSource::Local(i)) => {
                self.todos.selected = i;
                self.todos.toggle();
                self.save_todos();
            }
            // Panel shows open Google tasks → toggling completes them.
            Some(TodoSource::Google(i)) => self.gtasks_set_completed_index(i, true),
            None => {}
        }
        let n = self.todo_rows().len();
        if self.todo_cursor >= n {
            self.todo_cursor = n.saturating_sub(1);
        }
    }

    /// Delete the selected Todo-pane row (local → todos.md; Google → DELETE).
    pub fn todo_delete_selected(&mut self) {
        match self.todo_selected_source() {
            Some(TodoSource::Local(i)) => {
                self.todos.selected = i;
                self.todos.delete_selected();
                self.save_todos();
            }
            Some(TodoSource::Google(i)) => self.gtasks_delete_index(i),
            None => {}
        }
        let n = self.todo_rows().len();
        if self.todo_cursor >= n {
            self.todo_cursor = n.saturating_sub(1);
        }
    }

    /// True for a Google-backed Todo-pane row (so the UI can mark it + so edit
    /// is steered to local-only).
    pub fn todo_selected_is_google(&self) -> bool {
        matches!(self.todo_selected_source(), Some(TodoSource::Google(_)))
    }

    // --- Background Google-Tasks sync ----------------------------------------

    /// Kick off a background Google-Tasks fetch (non-blocking). Results land via
    /// `drain_gtasks` on the next event-loop tick.
    pub fn start_gtasks_sync(&mut self) {
        if !self.config.google.is_configured() {
            self.set_status("set [google] client_id/client_secret in config.toml first");
            return;
        }
        if self.gtasks_rx.is_some() {
            return; // already in flight
        }
        self.gtasks_rx = Some(spawn_gtasks_fetch(&self.config.google));
        self.set_status("syncing Google Tasks…");
        self.needs_redraw = true;
    }

    /// Drain a finished background Google-Tasks sync into `gtasks`.
    pub fn drain_gtasks(&mut self) {
        let Some(rx) = &self.gtasks_rx else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok(tasks)) => {
                let open = tasks.iter().filter(|t| !t.completed).count();
                self.gtasks = tasks;
                self.gtasks_rx = None;
                if self.gtasks_selected >= self.gtasks.len() {
                    self.gtasks_selected = self.gtasks.len().saturating_sub(1);
                }
                let n = self.todo_rows().len();
                if self.todo_cursor >= n {
                    self.todo_cursor = n.saturating_sub(1);
                }
                self.set_status(format!("Google Tasks synced · {open} open"));
                self.needs_redraw = true;
            }
            Ok(Err(e)) => {
                self.gtasks_rx = None;
                self.set_status(format!("Google Tasks sync failed: {e}"));
                self.needs_redraw = true;
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => self.gtasks_rx = None,
        }
    }

    pub fn gtasks_syncing(&self) -> bool {
        self.gtasks_rx.is_some()
    }

    // --- Google Calendar -----------------------------------------------------

    /// Background-fetch the displayed month's events.
    pub fn start_calendar_sync(&mut self) {
        if !self.config.google.is_configured() {
            self.set_status("set [google] client_id/client_secret in config.toml first");
            return;
        }
        if self.cal_events_rx.is_some() {
            return;
        }
        let (y, m) = (self.calendar.cursor.year(), self.calendar.cursor.month());
        self.cal_events_rx = Some(spawn_calendar_fetch(&self.config.google, y, m));
        self.cal_loaded_month = Some((y, m));
        self.set_status("syncing Google Calendar…");
        self.needs_redraw = true;
    }

    /// Auto-sync the displayed month when opted in and not already loaded
    /// (called each tick — covers startup and month navigation).
    pub fn maybe_autosync_calendar(&mut self) {
        if self.config.google.sync_calendar && self.config.google.is_configured() {
            let cur = (self.calendar.cursor.year(), self.calendar.cursor.month());
            if self.cal_loaded_month != Some(cur) && self.cal_events_rx.is_none() {
                self.start_calendar_sync();
            }
        }
    }

    pub fn drain_calendar(&mut self) {
        let Some(rx) = &self.cal_events_rx else {
            return;
        };
        match rx.try_recv() {
            Ok(Ok(events)) => {
                let n = events.len();
                self.cal_events = events;
                self.cal_events_rx = None;
                self.set_status(format!("Calendar synced · {n} events"));
                self.needs_redraw = true;
            }
            Ok(Err(e)) => {
                self.cal_events_rx = None;
                self.set_status(format!("Calendar sync failed: {e}"));
                self.needs_redraw = true;
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => self.cal_events_rx = None,
        }
    }

    pub fn calendar_syncing(&self) -> bool {
        self.cal_events_rx.is_some()
    }

    pub fn has_calendar_event(&self, date: NaiveDate) -> bool {
        self.cal_events.iter().any(|e| e.date == date)
    }

    pub fn events_on(&self, date: NaiveDate) -> Vec<&crate::integrations::gcal::CalEvent> {
        self.cal_events.iter().filter(|e| e.date == date).collect()
    }

    /// Open the day-agenda overlay for the calendar's selected day.
    pub fn open_agenda(&mut self) {
        self.agenda_selected = 0;
        self.last_focus = self.focus;
        self.focus = Focus::Agenda;
    }

    pub fn agenda_move(&mut self, delta: i64) {
        let n = self.events_on(self.calendar.cursor).len();
        if n == 0 {
            return;
        }
        let cur = self.agenda_selected.min(n - 1) as i64;
        self.agenda_selected = (cur + delta).clamp(0, n as i64 - 1) as usize;
    }

    /// Create an all-day Google event on the selected day, then re-sync.
    pub fn agenda_add_event(&mut self, title: &str) {
        let title = title.trim();
        if title.is_empty() {
            return;
        }
        let g = self.config.google.clone();
        if !g.is_configured() {
            self.set_status("set [google] client_id/client_secret in config.toml first");
            return;
        }
        let path = crate::config::Config::google_token_path();
        let date = self.calendar.cursor;
        match crate::integrations::gcal::create_all_day(&g.client_id, &g.client_secret, &path, date, title) {
            Ok(()) => {
                self.set_status(format!("added \"{title}\" on {date}"));
                self.start_calendar_sync();
            }
            Err(e) => self.set_status(format!("Calendar: {e}")),
        }
    }

    pub fn agenda_delete_selected(&mut self) {
        let day = self.calendar.cursor;
        let (cal_id, ev_id, summary) = {
            let evs = self.events_on(day);
            let Some(e) = evs.get(self.agenda_selected) else {
                return;
            };
            (e.calendar_id.clone(), e.id.clone(), e.summary.clone())
        };
        let g = self.config.google.clone();
        let path = crate::config::Config::google_token_path();
        match crate::integrations::gcal::delete_event(&g.client_id, &g.client_secret, &path, &cal_id, &ev_id) {
            Ok(()) => {
                self.cal_events.retain(|x| x.id != ev_id);
                let n = self.events_on(day).len();
                if self.agenda_selected >= n {
                    self.agenda_selected = n.saturating_sub(1);
                }
                self.set_status(format!("deleted \"{summary}\""));
            }
            Err(e) => self.set_status(format!("Calendar: {e}")),
        }
    }

    // --- Google Drive --------------------------------------------------------

    /// Open the Drive browser at My Drive's root.
    pub fn open_drive_browser(&mut self) {
        if !self.config.google.is_configured() {
            self.set_status("set [google] client_id/client_secret in config.toml first");
            return;
        }
        self.drive = Some(DriveBrowser {
            stack: vec![("root".to_string(), "My Drive".to_string())],
            files: Vec::new(),
            selected: 0,
            loading: true,
        });
        self.last_focus = self.focus;
        self.focus = Focus::Drive;
        self.fetch_drive_folder("root");
    }

    fn fetch_drive_folder(&mut self, parent: &str) {
        if let Some(d) = self.drive.as_mut() {
            d.loading = true;
        }
        self.drive_rx = Some(spawn_drive_list(&self.config.google, parent));
        self.needs_redraw = true;
    }

    pub fn drain_drive(&mut self) {
        let Some(rx) = &self.drive_rx else {
            return;
        };
        match rx.try_recv() {
            Ok((parent, res)) => {
                self.drive_rx = None;
                if self.drive.as_ref().map(|d| d.current_id() == parent).unwrap_or(false) {
                    match res {
                        Ok(files) => {
                            if let Some(d) = self.drive.as_mut() {
                                d.files = files;
                                d.selected = 0;
                                d.loading = false;
                            }
                        }
                        Err(e) => {
                            if let Some(d) = self.drive.as_mut() {
                                d.loading = false;
                            }
                            self.set_status(format!("Drive: {e}"));
                        }
                    }
                    self.needs_redraw = true;
                }
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => self.drive_rx = None,
        }
    }

    pub fn drive_loading(&self) -> bool {
        self.drive_rx.is_some()
    }

    pub fn drive_move(&mut self, delta: i64) {
        if let Some(d) = self.drive.as_mut() {
            let n = d.files.len();
            if n == 0 {
                return;
            }
            let cur = d.selected.min(n - 1) as i64;
            d.selected = (cur + delta).clamp(0, n as i64 - 1) as usize;
        }
    }

    /// Descend into a folder, or open a text file in the editor.
    pub fn drive_enter(&mut self) {
        let Some(file) = self
            .drive
            .as_ref()
            .and_then(|d| d.files.get(d.selected).cloned())
        else {
            return;
        };
        if file.is_folder() {
            if let Some(d) = self.drive.as_mut() {
                d.stack.push((file.id.clone(), file.name.clone()));
            }
            self.fetch_drive_folder(&file.id);
        } else if file.is_google_doc() {
            self.set_status("Google Docs/Sheets aren't editable in Onyx yet");
        } else if file.is_text() {
            self.open_drive_file(&file.id, &file.name);
        } else {
            // PDF, image, or other binary → download + open in the system viewer.
            self.open_drive_binary(&file.id, &file.name);
        }
    }

    pub fn drive_up(&mut self) {
        let parent = self.drive.as_mut().and_then(|d| {
            if d.stack.len() > 1 {
                d.stack.pop();
                d.stack.last().map(|(id, _)| id.clone())
            } else {
                None
            }
        });
        if let Some(p) = parent {
            self.fetch_drive_folder(&p);
        }
    }

    /// Download a Drive text file and open it in the editor (saving uploads back).
    fn open_drive_file(&mut self, file_id: &str, name: &str) {
        let g = self.config.google.clone();
        let path = crate::config::Config::google_token_path();
        self.set_status(format!("downloading {name}…"));
        match crate::integrations::gdrive::download_text(&g.client_id, &g.client_secret, &path, file_id) {
            Ok(content) => {
                self.stash_active();
                let mut doc = Document::from_text(None, content);
                doc.drive_id = Some(file_id.to_string());
                doc.drive_name = Some(name.to_string());
                self.doc = Some(doc);
                self.drive = None;
                self.focus = Focus::Editor;
                self.set_status(format!("opened {name} from Drive (save to upload back)"));
            }
            Err(e) => self.set_status(format!("Drive: {e}")),
        }
    }

    /// Download a non-text Drive file (PDF, image, …) to a temp file and open it
    /// in the system's default app (detached — Onyx stays on screen).
    fn open_drive_binary(&mut self, file_id: &str, name: &str) {
        let g = self.config.google.clone();
        let path = crate::config::Config::google_token_path();
        let dest = std::env::temp_dir()
            .join("onyx-drive")
            .join(sanitize_filename(name));
        self.set_status(format!("downloading {name}…"));
        match crate::integrations::gdrive::download_file(
            &g.client_id,
            &g.client_secret,
            &path,
            file_id,
            &dest,
        ) {
            Ok(()) => match crate::external::open_external(&dest) {
                Ok(opener) => self.set_status(format!("opened {name} with {opener}")),
                Err(e) => self.set_status(format!(
                    "saved to {} but no opener found: {e}",
                    dest.display()
                )),
            },
            Err(e) => self.set_status(format!("Drive: {e}")),
        }
    }

    /// Upload the open Drive-backed buffer back to Drive.
    fn save_drive_doc(&mut self, drive_id: &str) -> Result<()> {
        let g = self.config.google.clone();
        let path = crate::config::Config::google_token_path();
        let content = self.doc.as_ref().map(|d| d.buffer.to_string()).unwrap_or_default();
        match crate::integrations::gdrive::upload_text(&g.client_id, &g.client_secret, &path, drive_id, &content) {
            Ok(()) => {
                if let Some(d) = self.doc.as_mut() {
                    d.dirty = false;
                }
                let name = self.doc.as_ref().and_then(|d| d.drive_name.clone()).unwrap_or_default();
                self.set_status(format!("uploaded {name} to Drive ✓"));
                Ok(())
            }
            Err(e) => {
                self.set_status(format!("Drive upload failed: {e}"));
                Ok(())
            }
        }
    }

    /// Upload the currently-open note as a NEW file in the Drive folder being
    /// browsed (create, not update). Refreshes the listing on success.
    pub fn upload_current_to_drive(&mut self) {
        let parent = match self.drive.as_ref() {
            Some(d) => d.current_id().to_string(),
            None => {
                self.set_status("open :drive and navigate to a target folder first");
                return;
            }
        };
        let (name, content) = match self.doc.as_ref() {
            Some(doc) => {
                let name = doc
                    .path
                    .as_ref()
                    .and_then(|p| p.file_name())
                    .and_then(|s| s.to_str())
                    .map(|s| s.to_string())
                    .or_else(|| doc.drive_name.clone())
                    .unwrap_or_else(|| "untitled.md".to_string());
                (name, doc.buffer.to_string())
            }
            None => {
                self.set_status("open a note first, then press u to upload it to Drive");
                return;
            }
        };
        let mime = if name.to_ascii_lowercase().ends_with(".md") {
            "text/markdown"
        } else {
            "text/plain"
        };
        let g = self.config.google.clone();
        let token = crate::config::Config::google_token_path();
        self.set_status(format!("uploading {name} to Drive…"));
        match crate::integrations::gdrive::create_file(
            &g.client_id,
            &g.client_secret,
            &token,
            &parent,
            &name,
            &content,
            mime,
        ) {
            Ok(_id) => {
                self.set_status(format!("uploaded {name} to Drive ✓"));
                // Re-list so the new file shows up in the browser.
                self.fetch_drive_folder(&parent);
            }
            Err(e) => self.set_status(format!("Drive upload failed: {e}")),
        }
    }

    pub fn close_drive(&mut self) {
        self.drive = None;
        self.focus = self.center_focus();
    }

    /// Create a task in the user's default Google Tasks list.
    pub fn gtasks_add_task(&mut self, title: &str) {
        let title = title.trim();
        if title.is_empty() {
            self.set_status("usage: :gtasks add <title>");
            return;
        }
        let g = self.config.google.clone();
        if !g.is_configured() {
            self.set_status("set [google] client_id/client_secret in config.toml first");
            return;
        }
        let path = crate::config::Config::google_token_path();
        match crate::integrations::gtasks::create_task(
            &g.client_id,
            &g.client_secret,
            &path,
            crate::integrations::gtasks::DEFAULT_LIST,
            title,
            "",
        ) {
            Ok(()) => self.set_status(format!("added \"{title}\" to Google Tasks")),
            Err(e) => self.set_status(format!("Google Tasks: {e}")),
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
        let q = parse_search_query(self.search.query.trim());
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
        // Resolve tag:/path: filters against the in-memory index up front, so the
        // worker only line-scans the candidate files.
        let paths = self.filtered_search_paths(&q);
        let gen = self.search_gen.clone();
        std::thread::spawn(move || search_worker(q, paths, epoch, gen, tx));
        self.needs_redraw = true;
    }

    /// Notes to scan for a query, after applying its `tag:`/`path:` filters
    /// (both ANDed). With no filters this is the whole vault.
    fn filtered_search_paths(&self, q: &SearchQuery) -> Vec<PathBuf> {
        let mut paths: Vec<PathBuf> = self.vault.tree.notes.clone();
        for tag in &q.tags {
            let set: std::collections::HashSet<PathBuf> =
                self.vault.index.notes_with_tag(tag).into_iter().collect();
            paths.retain(|p| set.contains(p));
        }
        for needle in &q.paths {
            paths.retain(|p| {
                crate::vault::note_relpath(&self.vault.root, p)
                    .to_lowercase()
                    .contains(needle)
            });
        }
        paths
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

    // --- Unlinked mentions (Backlinks pane) ---------------------------------

    /// Names to look for when finding unlinked mentions of a note: its basename
    /// plus any aliases, lowercased, dropping anything under 3 chars (too noisy).
    fn note_mention_names(&self, path: &Path) -> Vec<String> {
        let mut names: Vec<String> = vec![crate::vault::note_basename(path).to_lowercase()];
        if let Some(meta) = self.vault.index.meta(path) {
            for a in &meta.aliases {
                names.push(a.to_lowercase());
            }
        }
        names.retain(|n| n.chars().count() >= 3);
        names.sort();
        names.dedup();
        names
    }

    /// Kick off a background scan for unlinked mentions of `path`. Excludes the
    /// note itself and notes that already link to it (real backlinks).
    fn start_unlinked_scan(&mut self, path: PathBuf) {
        let names = self.note_mention_names(&path);
        let mut exclude: std::collections::HashSet<PathBuf> =
            self.vault.index.backlinks_for(&path).into_iter().collect();
        exclude.insert(path.clone());
        self.unlinked = UnlinkedState {
            for_path: Some(path),
            mentions: Vec::new(),
            loading: !names.is_empty(),
        };
        if names.is_empty() {
            self.unlinked_rx = None;
            return;
        }
        self.unlinked_epoch = self.unlinked_epoch.wrapping_add(1);
        let epoch = self.unlinked_epoch;
        self.unlinked_gen.store(epoch, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        self.unlinked_rx = Some(rx);
        let paths = self.vault.tree.notes.clone();
        let gen = self.unlinked_gen.clone();
        std::thread::spawn(move || unlinked_worker(names, exclude, paths, epoch, gen, tx));
        self.needs_redraw = true;
    }

    /// Re-scan unlinked mentions when the open note changes (called each tick).
    /// Only runs while the right sidebar (which hosts Backlinks) is visible.
    pub fn maybe_refresh_unlinked(&mut self) {
        if !self.show_right {
            return;
        }
        let cur = self.doc.as_ref().and_then(|d| d.path.clone());
        if cur.as_deref() == self.unlinked.for_path.as_deref() {
            return; // already tracking this note (scanning or done)
        }
        match cur {
            Some(p) => self.start_unlinked_scan(p),
            None => {
                self.unlinked = UnlinkedState::default();
                self.unlinked_rx = None;
            }
        }
    }

    /// Apply a finished unlinked-mention scan (called each tick).
    pub fn drain_unlinked(&mut self) {
        let Some(rx) = &self.unlinked_rx else {
            return;
        };
        match rx.try_recv() {
            Ok((epoch, mentions)) => {
                self.unlinked_rx = None;
                if epoch == self.unlinked_epoch {
                    self.unlinked.mentions = mentions;
                    self.unlinked.loading = false;
                    self.needs_redraw = true;
                }
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => self.unlinked_rx = None,
        }
    }

    pub fn unlinked_loading(&self) -> bool {
        self.unlinked_rx.is_some()
    }

    /// Rows for the Backlinks pane: real backlinks (`false`) first, then unlinked
    /// mentions (`true`). Selection in the pane indexes into this list.
    pub fn backlink_rows(&self, path: &Path) -> Vec<(PathBuf, bool)> {
        let mut rows: Vec<(PathBuf, bool)> = self
            .vault
            .index
            .backlinks_for(path)
            .into_iter()
            .map(|p| (p, false))
            .collect();
        if self.unlinked.for_path.as_deref() == Some(path) {
            for p in &self.unlinked.mentions {
                rows.push((p.clone(), true));
            }
        }
        rows
    }

    // --- Local AI assistant (Ollama) ----------------------------------------

    /// Open the AI chat overlay (keeping any prior conversation).
    pub fn open_ai(&mut self) {
        if self.focus != Focus::Ai {
            self.last_focus = self.focus;
        }
        self.focus = Focus::Ai;
        self.ai.scroll = 0;
        self.needs_redraw = true;
    }

    /// Open the overlay and immediately send `prompt` (used by `:ai <text>` and
    /// note actions like `:summarize`).
    pub fn ai_prompt(&mut self, prompt: String) {
        self.open_ai();
        let prompt = prompt.trim().to_string();
        if !prompt.is_empty() && !self.ai.streaming {
            self.send_ai_message(prompt);
        }
    }

    pub fn close_ai(&mut self) {
        // Stop the in-flight stream but keep the conversation for next time.
        self.ai_cancel.store(true, Ordering::Relaxed);
        self.ai_rx = None;
        self.ai.streaming = false;
        self.focus = self.center_focus();
        self.needs_redraw = true;
    }

    pub fn ai_input_char(&mut self, c: char) {
        self.ai.input.push(c);
        self.needs_redraw = true;
    }

    pub fn ai_input_backspace(&mut self) {
        self.ai.input.pop();
        self.needs_redraw = true;
    }

    pub fn ai_scroll(&mut self, delta: i64) {
        self.ai.scroll = (self.ai.scroll as i64 + delta).max(0) as usize;
        self.needs_redraw = true;
    }

    /// Clear the conversation (keeps the overlay open).
    pub fn ai_clear(&mut self) {
        self.ai_cancel.store(true, Ordering::Relaxed);
        self.ai_rx = None;
        self.ai.streaming = false;
        self.ai.turns.clear();
        self.ai.scroll = 0;
        self.set_status("AI conversation cleared");
    }

    /// Submit whatever is in the input box.
    pub fn ai_submit(&mut self) {
        if self.ai.streaming {
            return;
        }
        let text = self.ai.input.trim().to_string();
        if text.is_empty() {
            return;
        }
        self.ai.input.clear();
        self.send_ai_message(text);
    }

    /// Build the message list (system + note context + history + new user turn),
    /// record the turns, and spawn the streaming worker.
    fn send_ai_message(&mut self, user_text: String) {
        use crate::integrations::ollama::ChatMessage;

        let mut sys = String::from(
            "You are a helpful assistant embedded in Onyx, a Markdown notes (TUI) app. \
             Answer concisely and format replies in Markdown. You know Onyx's keybindings \
             (listed below); when asked about a shortcut or how to do something in Onyx, \
             answer from this list and give the exact keys.\n\n# Onyx keybindings\n",
        );
        sys.push_str(&crate::keymap::cheatsheet());
        if let Some(doc) = self.doc.as_ref() {
            let title = doc
                .path
                .as_ref()
                .and_then(|p| p.file_stem())
                .and_then(|s| s.to_str())
                .map(|s| s.to_string())
                .or_else(|| doc.drive_name.clone())
                .unwrap_or_else(|| "untitled".to_string());
            let mut body = doc.buffer.to_string();
            if body.len() > AI_NOTE_CONTEXT_CAP {
                body.truncate(AI_NOTE_CONTEXT_CAP);
                body.push_str("\n…(truncated)");
            }
            sys.push_str(&format!(
                "\n\nThe user's current note (\"{title}\") follows; use it as context when relevant:\n\n{body}"
            ));
        }

        let mut messages = vec![ChatMessage::system(sys)];
        for turn in &self.ai.turns {
            match turn.role {
                AiRole::User => messages.push(ChatMessage::user(turn.content.clone())),
                AiRole::Assistant => messages.push(ChatMessage::assistant(turn.content.clone())),
            }
        }
        messages.push(ChatMessage::user(user_text.clone()));

        // Record the user turn, then stream the reply.
        self.ai.turns.push(AiTurn {
            role: AiRole::User,
            content: user_text,
            thinking: String::new(),
        });
        self.begin_stream(messages);
    }

    /// Push an empty assistant turn and spawn the streaming worker for `messages`
    /// (supersedes any in-flight stream). The caller has already recorded the
    /// user turn(s) that should appear above the reply.
    fn begin_stream(&mut self, messages: Vec<crate::integrations::ollama::ChatMessage>) {
        self.ai.turns.push(AiTurn {
            role: AiRole::Assistant,
            content: String::new(),
            thinking: String::new(),
        });
        self.ai.scroll = 0;

        self.ai_cancel.store(true, Ordering::Relaxed);
        let cancel = Arc::new(AtomicBool::new(false));
        self.ai_cancel = cancel.clone();
        self.ai_epoch = self.ai_epoch.wrapping_add(1);
        let epoch = self.ai_epoch;
        let (tx, rx) = mpsc::channel();
        self.ai_rx = Some(rx);
        self.ai.streaming = true;
        let host = self.config.ai.host.clone();
        let model = self.config.ai.model.clone();
        std::thread::spawn(move || ai_worker(host, model, messages, epoch, cancel, tx));
        self.needs_redraw = true;
    }

    /// Apply streamed AI deltas (called each loop tick).
    pub fn drain_ai(&mut self) {
        let mut changed = false;
        let mut finished = false;
        let mut error: Option<String> = None;
        if let Some(rx) = &self.ai_rx {
            loop {
                match rx.try_recv() {
                    Ok(AiMsg::Delta(e, chunk)) => {
                        if e == self.ai_epoch {
                            if let Some(turn) = self.ai.turns.last_mut() {
                                if turn.role == AiRole::Assistant {
                                    turn.content.push_str(&chunk.content);
                                    turn.thinking.push_str(&chunk.thinking);
                                }
                            }
                            changed = true;
                        }
                    }
                    Ok(AiMsg::Done(e)) => {
                        if e == self.ai_epoch {
                            finished = true;
                        }
                    }
                    Ok(AiMsg::Err(e, msg)) => {
                        if e == self.ai_epoch {
                            finished = true;
                            error = Some(msg);
                        }
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        finished = true;
                        break;
                    }
                }
                if finished {
                    break;
                }
            }
        }
        if finished {
            self.ai_rx = None;
            self.ai.streaming = false;
            changed = true;
            if let Some(msg) = error {
                self.ai_pending_sources = None;
                if let Some(turn) = self.ai.turns.last_mut() {
                    if turn.role == AiRole::Assistant && turn.content.trim().is_empty() {
                        turn.content = format!("⚠ {msg}");
                    }
                }
                self.set_status(format!("AI: {msg}"));
            } else if let Some(src) = self.ai_pending_sources.take() {
                // Append the RAG source list under the finished answer.
                if let Some(turn) = self.ai.turns.last_mut() {
                    if turn.role == AiRole::Assistant {
                        turn.content.push_str(&format!("\n\n— Sources: {src}"));
                    }
                }
            }
        }
        if changed {
            self.needs_redraw = true;
        }
    }

    pub fn ai_streaming(&self) -> bool {
        self.ai_rx.is_some()
    }

    /// Summarize the open note via the assistant.
    pub fn summarize_current(&mut self) {
        if self.doc.is_none() {
            self.set_status("open a note to summarize");
            return;
        }
        self.ai_prompt("Summarize this note in a few concise bullet points.".to_string());
    }

    /// Switch the active Ollama model (persisted to config).
    pub fn ai_set_model(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            self.set_status(format!("AI model: {}", self.config.ai.model));
            return;
        }
        self.config.ai.model = name.to_string();
        let _ = self.config.save();
        self.set_status(format!("AI model set to {name}"));
    }

    /// List installed Ollama models into the status line (a quick blocking call).
    pub fn ai_list_models(&mut self) {
        match crate::integrations::ollama::list_models(&self.config.ai.host) {
            Ok(models) if !models.is_empty() => {
                self.set_status(format!("models: {}", models.join("  ")))
            }
            Ok(_) => self.set_status("no Ollama models found (run `ollama pull`)"),
            Err(e) => self.set_status(format!("AI: {e}")),
        }
    }

    // --- Ask my vault (RAG) -------------------------------------------------

    /// Answer a question using semantic search over the whole vault. Opens the
    /// AI overlay, (re)builds the embedding index in the background if stale,
    /// then retrieves and streams an answer.
    pub fn ask_vault(&mut self, question: String) {
        let question = question.trim().to_string();
        if question.is_empty() {
            self.set_status("usage: :ask <question>");
            return;
        }
        self.open_ai();
        if self.ai.streaming || self.rag.building {
            self.set_status("AI is busy — wait for the current reply");
            return;
        }
        // Snapshot notes + mtimes for the worker (it embeds only changed ones).
        let root = self.vault.root.clone();
        let notes: Vec<(String, u64)> = self
            .vault
            .tree
            .notes
            .iter()
            .map(|p| {
                let mtime = std::fs::metadata(p)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                (p.to_string_lossy().to_string(), mtime)
            })
            .collect();
        let host = self.config.ai.host.clone();
        let embed_model = self.config.ai.embed_model.clone();

        self.rag_epoch = self.rag_epoch.wrapping_add(1);
        let epoch = self.rag_epoch;
        self.rag_gen.store(epoch, Ordering::Relaxed);
        let gen = self.rag_gen.clone();
        let (tx, rx) = mpsc::channel();
        self.rag_rx = Some(rx);
        self.rag = RagState { building: true, done: 0, total: 0 };

        // Show the question immediately while indexing runs.
        self.ai.turns.push(AiTurn {
            role: AiRole::User,
            content: format!("📚 {question}"),
            thinking: String::new(),
        });
        self.ai.scroll = 0;

        let job = RagJob { root, notes, host, embed_model, question };
        std::thread::spawn(move || rag_worker(job, epoch, gen, tx));
        self.needs_redraw = true;
    }

    /// Apply RAG worker progress/results (called each loop tick).
    pub fn drain_rag(&mut self) {
        let mut progress: Option<(usize, usize)> = None;
        let mut ready: Option<(String, Vec<crate::rag::Retrieved>)> = None;
        let mut error: Option<String> = None;
        let mut finished = false;
        if let Some(rx) = &self.rag_rx {
            loop {
                match rx.try_recv() {
                    Ok(RagMsg::Progress(e, d, t)) => {
                        if e == self.rag_epoch {
                            progress = Some((d, t));
                        }
                    }
                    Ok(RagMsg::Ready(e, q, hits)) => {
                        if e == self.rag_epoch {
                            ready = Some((q, hits));
                        }
                        finished = true;
                    }
                    Ok(RagMsg::Err(e, m)) => {
                        if e == self.rag_epoch {
                            error = Some(m);
                        }
                        finished = true;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        finished = true;
                        break;
                    }
                }
                if finished {
                    break;
                }
            }
        }
        if let Some((d, t)) = progress {
            self.rag.done = d;
            self.rag.total = t;
            self.needs_redraw = true;
        }
        if finished {
            self.rag_rx = None;
            self.rag.building = false;
            if let Some(m) = error {
                self.ai.turns.push(AiTurn {
                    role: AiRole::Assistant,
                    content: format!("⚠ {m}"),
                    thinking: String::new(),
                });
                self.set_status(format!("ask: {m}"));
            } else if let Some((question, hits)) = ready {
                self.start_rag_answer(question, hits);
            }
            self.needs_redraw = true;
        }
    }

    pub fn rag_building(&self) -> bool {
        self.rag_rx.is_some()
    }

    /// Build the grounded prompt from retrieved chunks and stream the answer.
    fn start_rag_answer(&mut self, question: String, hits: Vec<crate::rag::Retrieved>) {
        use crate::integrations::ollama::ChatMessage;
        if hits.is_empty() {
            self.ai.turns.push(AiTurn {
                role: AiRole::Assistant,
                content: "I couldn't find anything relevant in your vault.".into(),
                thinking: String::new(),
            });
            return;
        }
        let mut context = String::new();
        let mut sources: Vec<String> = Vec::new();
        for (i, h) in hits.iter().enumerate() {
            let title = Path::new(&h.path)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("note")
                .to_string();
            context.push_str(&format!("[{}] {} (line {}):\n{}\n\n", i + 1, title, h.line + 1, h.text));
            sources.push(format!("[{}] {}", i + 1, title));
        }
        let sys = format!(
            "You answer questions about the user's personal notes. Use ONLY the excerpts \
             below; if they don't contain the answer, say you couldn't find it. Cite sources \
             inline like [1], [2]. Be concise and use Markdown.\n\nExcerpts:\n{context}"
        );
        let messages = vec![ChatMessage::system(sys), ChatMessage::user(question)];
        self.ai_pending_sources = Some(sources.join("  "));
        self.begin_stream(messages);
    }

    // --- AI rewrite (apply back into the note) ------------------------------

    /// Rewrite the current paragraph (or the whole note when `whole`) via the
    /// LLM, replacing it in place as a single undo-able edit. Empty instruction
    /// → a default cleanup.
    /// Entry point for the `:rewrite` command: rewrite the Visual selection if
    /// one is active, else the paragraph (`:rewrite all` → whole note).
    pub fn rewrite_command(&mut self, args: &str) {
        let in_visual = self
            .doc
            .as_ref()
            .map(|d| d.mode == Mode::Visual)
            .unwrap_or(false);
        if in_visual {
            if let Some((s, e)) = self.visual_line_range() {
                self.exit_visual();
                self.rewrite_lines(s, e, args.trim().to_string(), "selection");
                return;
            }
        }
        let a = args.trim();
        match a.strip_prefix("all") {
            Some(rest) if rest.is_empty() || rest.starts_with(char::is_whitespace) => {
                self.rewrite_range(true, rest.trim().to_string())
            }
            _ => self.rewrite_range(false, a.to_string()),
        }
    }

    pub fn rewrite_range(&mut self, whole: bool, instruction: String) {
        let Some(doc) = self.doc.as_ref() else {
            self.set_status("open a note to rewrite");
            return;
        };
        let lc = doc.buffer.line_count();
        let cur = doc.buffer.cursor.line.min(lc.saturating_sub(1));
        let (start, end) = if whole {
            (0, lc.saturating_sub(1))
        } else {
            let blank = |i: usize| doc.buffer.line(i).trim().is_empty();
            if blank(cur) {
                (cur, cur)
            } else {
                let mut s = cur;
                while s > 0 && !blank(s - 1) {
                    s -= 1;
                }
                let mut e = cur;
                while e + 1 < lc && !blank(e + 1) {
                    e += 1;
                }
                (s, e)
            }
        };
        self.rewrite_lines(start, end, instruction, if whole { "note" } else { "paragraph" });
    }

    /// Core: rewrite the inclusive line range `start..=end` per `instruction`,
    /// streaming the result and replacing it in place when done.
    fn rewrite_lines(&mut self, start: usize, end: usize, instruction: String, scope: &str) {
        if self.rewrite.active || self.ai.streaming {
            self.set_status("AI is busy — wait for the current task");
            return;
        }
        let Some(doc) = self.doc.as_ref() else {
            self.set_status("open a note to rewrite");
            return;
        };
        let text: String = (start..=end.min(doc.buffer.line_count().saturating_sub(1)))
            .map(|i| doc.buffer.line(i))
            .collect::<Vec<_>>()
            .join("\n");
        if text.trim().is_empty() {
            self.set_status("nothing to rewrite here");
            return;
        }

        let instruction = if instruction.trim().is_empty() {
            "Improve clarity and fix grammar; keep the meaning and Markdown structure.".to_string()
        } else {
            instruction.trim().to_string()
        };
        use crate::integrations::ollama::ChatMessage;
        let sys = "You are a careful text editor. Rewrite the user's text following their \
                   instruction. Output ONLY the rewritten text — no preamble, no commentary, \
                   no surrounding code fences. Preserve Markdown formatting.";
        let user = format!("Instruction: {instruction}\n\nText:\n{text}");
        let messages = vec![ChatMessage::system(sys), ChatMessage::user(user)];

        self.rewrite_cancel.store(true, Ordering::Relaxed);
        let cancel = Arc::new(AtomicBool::new(false));
        self.rewrite_cancel = cancel.clone();
        self.rewrite_epoch = self.rewrite_epoch.wrapping_add(1);
        let epoch = self.rewrite_epoch;
        let (tx, rx) = mpsc::channel();
        self.rewrite_rx = Some(rx);
        self.rewrite = RewriteState { active: true, start, end, acc: String::new() };
        let host = self.config.ai.host.clone();
        let model = self.config.ai.model.clone();
        std::thread::spawn(move || ai_worker(host, model, messages, epoch, cancel, tx));
        self.set_status(format!("rewriting {scope}…"));
        self.needs_redraw = true;
    }

    // --- Visual (line-wise) selection ---------------------------------------

    /// The selected inclusive line range, if in Visual mode.
    pub fn visual_line_range(&self) -> Option<(usize, usize)> {
        let doc = self.doc.as_ref()?;
        let anchor = doc.anchor?;
        let cur = doc.buffer.cursor.line;
        Some((anchor.line.min(cur), anchor.line.max(cur)))
    }

    pub fn enter_visual(&mut self) {
        if let Some(doc) = self.doc.as_mut() {
            doc.anchor = Some(doc.buffer.cursor);
            doc.mode = Mode::Visual;
        }
        self.needs_redraw = true;
    }

    pub fn exit_visual(&mut self) {
        if let Some(doc) = self.doc.as_mut() {
            doc.mode = Mode::Normal;
            doc.anchor = None;
        }
        self.needs_redraw = true;
    }

    /// Yank the selected lines into the register, then leave Visual mode.
    pub fn visual_yank(&mut self) {
        if let Some((s, e)) = self.visual_line_range() {
            if let Some(doc) = self.doc.as_ref() {
                self.register = (s..=e).map(|i| doc.buffer.line(i)).collect::<Vec<_>>().join("\n");
            }
            self.set_status(format!("yanked {} line(s)", e - s + 1));
        }
        self.exit_visual();
    }

    /// Delete the selected lines (yanking them first), then leave Visual mode.
    pub fn visual_delete(&mut self) {
        if let Some((s, e)) = self.visual_line_range() {
            if let Some(doc) = self.doc.as_mut() {
                self.register = (s..=e).map(|i| doc.buffer.line(i)).collect::<Vec<_>>().join("\n");
                doc.history.record(&doc.buffer);
                doc.buffer.remove_line_range(s, e);
                doc.dirty = true;
            }
        }
        self.exit_visual();
    }

    /// Rewrite the selected lines with the AI (default cleanup), leaving Visual.
    pub fn rewrite_selection(&mut self, instruction: String) {
        let Some((s, e)) = self.visual_line_range() else {
            return;
        };
        self.exit_visual();
        self.rewrite_lines(s, e, instruction, "selection");
    }

    /// Paste the register as whole lines (after the cursor line, or before for `P`).
    pub fn paste_register(&mut self, after: bool) {
        if self.register.is_empty() {
            self.set_status("nothing to paste");
            return;
        }
        let reg = self.register.clone();
        if let Some(doc) = self.doc.as_mut() {
            doc.history.record(&doc.buffer);
            let at = if after { doc.buffer.cursor.line + 1 } else { doc.buffer.cursor.line };
            doc.buffer.insert_lines(at, &reg);
            doc.dirty = true;
        }
        self.needs_redraw = true;
    }

    // --- Inline autocomplete (ghost text) -----------------------------------

    /// Record an insert-mode edit/move: reset the debounce timer and drop any
    /// stale suggestion + in-flight request.
    pub fn note_edit(&mut self) {
        self.last_edit = Some(Instant::now());
        if self.ghost.take().is_some() {
            self.needs_redraw = true;
        }
        if self.ghost_rx.is_some() {
            self.ghost_cancel.store(true, Ordering::Relaxed);
            self.ghost_rx = None;
        }
        self.ghost_for_rev = None;
    }

    /// True while waiting out the debounce before requesting a suggestion (the
    /// event loop polls faster so it can fire even with no further input).
    pub fn ghost_armed(&self) -> bool {
        self.config.ai.autocomplete
            && self.last_edit.is_some()
            && self.focus == Focus::Editor
            && self.doc.as_ref().map(|d| d.mode == Mode::Insert).unwrap_or(false)
    }

    pub fn ghost_pending(&self) -> bool {
        self.ghost_rx.is_some()
    }

    /// Fire a debounced completion request when idle in insert mode at line end.
    pub fn maybe_request_ghost(&mut self) {
        if !self.config.ai.autocomplete
            || self.focus != Focus::Editor
            || self.ghost.is_some()
            || self.ghost_rx.is_some()
            || self.link_complete.is_some()
            || self.slash_complete.is_some()
            || self.tag_complete.is_some()
        {
            return;
        }
        let Some(last) = self.last_edit else { return };
        if last.elapsed() < GHOST_DEBOUNCE {
            return;
        }
        let Some(doc) = self.doc.as_ref() else { return };
        if doc.mode != Mode::Insert {
            return;
        }
        let line = doc.buffer.cursor.line;
        let cur_line = doc.buffer.line(line);
        // Only suggest at the end of a line with some content.
        if doc.buffer.cursor.col < cur_line.chars().count() {
            return;
        }
        let rev = doc.buffer.revision;
        if self.ghost_for_rev == Some(rev) {
            return;
        }
        let mut ctx = String::new();
        for i in 0..line {
            ctx.push_str(doc.buffer.line(i));
            ctx.push('\n');
        }
        ctx.push_str(cur_line);
        if ctx.trim().is_empty() {
            return;
        }
        if ctx.len() > GHOST_CONTEXT_CAP {
            let mut start = ctx.len() - GHOST_CONTEXT_CAP;
            while !ctx.is_char_boundary(start) {
                start += 1;
            }
            ctx = ctx[start..].to_string();
        }

        self.ghost_for_rev = Some(rev);
        self.last_edit = None; // don't refire until the next edit
        self.ghost_cancel.store(true, Ordering::Relaxed);
        let cancel = Arc::new(AtomicBool::new(false));
        self.ghost_cancel = cancel.clone();
        self.ghost_epoch = self.ghost_epoch.wrapping_add(1);
        let epoch = self.ghost_epoch;
        let (tx, rx) = mpsc::channel();
        self.ghost_rx = Some(rx);
        let host = self.config.ai.host.clone();
        let model = self.config.ai.completion_model.clone();
        std::thread::spawn(move || ghost_worker(host, model, ctx, epoch, cancel, tx));
    }

    /// Apply a finished completion (if the buffer is still in the same state).
    pub fn drain_ghost(&mut self) {
        let msg = match &self.ghost_rx {
            Some(rx) => rx.try_recv(),
            None => return,
        };
        match msg {
            Ok((epoch, res)) => {
                self.ghost_rx = None;
                if epoch != self.ghost_epoch {
                    return;
                }
                if let Ok(text) = res {
                    let g = clean_ghost(&text);
                    let rev_ok = self
                        .doc
                        .as_ref()
                        .map(|d| {
                            d.mode == Mode::Insert && Some(d.buffer.revision) == self.ghost_for_rev
                        })
                        .unwrap_or(false);
                    if !g.is_empty() && rev_ok && self.focus == Focus::Editor {
                        self.ghost = Some(g);
                        self.needs_redraw = true;
                    }
                }
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => self.ghost_rx = None,
        }
    }

    /// Accept the shown suggestion, inserting it at the cursor.
    pub fn accept_ghost(&mut self) {
        let Some(g) = self.ghost.take() else { return };
        if let Some(doc) = self.doc.as_mut() {
            doc.history.record(&doc.buffer);
            doc.buffer.insert_str(&g);
            doc.dirty = true;
        }
        self.ghost_for_rev = None;
        self.last_edit = None;
        self.needs_redraw = true;
    }

    /// Toggle inline autocomplete on/off (persisted).
    pub fn set_autocomplete(&mut self, on: bool) {
        self.config.ai.autocomplete = on;
        let _ = self.config.save();
        if !on {
            self.ghost = None;
            self.ghost_rx = None;
        }
        self.set_status(if on { "autocomplete on" } else { "autocomplete off" });
    }

    /// Accumulate the rewrite stream; on completion replace the range in place.
    pub fn drain_rewrite(&mut self) {
        let mut finished = false;
        let mut error: Option<String> = None;
        if let Some(rx) = &self.rewrite_rx {
            loop {
                match rx.try_recv() {
                    Ok(AiMsg::Delta(e, chunk)) => {
                        if e == self.rewrite_epoch {
                            self.rewrite.acc.push_str(&chunk.content);
                        }
                    }
                    Ok(AiMsg::Done(e)) => {
                        if e == self.rewrite_epoch {
                            finished = true;
                        }
                    }
                    Ok(AiMsg::Err(e, m)) => {
                        if e == self.rewrite_epoch {
                            finished = true;
                            error = Some(m);
                        }
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        finished = true;
                        break;
                    }
                }
                if finished {
                    break;
                }
            }
        }
        if finished {
            self.rewrite_rx = None;
            self.rewrite.active = false;
            if let Some(m) = error {
                self.set_status(format!("rewrite: {m}"));
                self.needs_redraw = true;
                return;
            }
            let out = clean_rewrite_output(&self.rewrite.acc);
            if out.trim().is_empty() {
                self.set_status("rewrite produced nothing");
                self.needs_redraw = true;
                return;
            }
            let (start, end) = (self.rewrite.start, self.rewrite.end);
            if let Some(doc) = self.doc.as_mut() {
                doc.history.record(&doc.buffer);
                doc.buffer.replace_line_range(start, end, &out);
                doc.dirty = true;
            }
            self.set_status("rewritten — u to undo");
            self.needs_redraw = true;
        }
    }

    pub fn rewrite_active(&self) -> bool {
        self.rewrite_rx.is_some()
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
            Focus::Properties => {
                // First Esc cancels an in-progress field edit; the next closes.
                if self.props_edit.editing.is_some() {
                    self.props_edit.editing = None;
                } else {
                    self.close_overlay();
                }
            }
            Focus::Palette | Focus::Switcher | Focus::Search | Focus::Help | Focus::Settings | Focus::Prompt | Focus::Tasks | Focus::GoogleTasks | Focus::Agenda => {
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
            Focus::Drive => self.close_drive(),
            Focus::Ai => self.close_ai(),
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
            Focus::Graph | Focus::Calendar | Focus::Todo | Focus::Preview => {
                self.focus = self.center_focus();
            }
            // Esc from Home drops to the file tree if it's visible.
            Focus::Home if self.show_left => {
                self.focus = Focus::FileTree;
            }
            Focus::Editor => {
                self.link_complete = None;
                self.slash_complete = None;
                self.tag_complete = None;
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

/// Spawn a background thread that fetches all Google Tasks, returning the
/// channel its result arrives on.
fn spawn_gtasks_fetch(
    g: &crate::config::GoogleConfig,
) -> Receiver<std::result::Result<Vec<crate::integrations::gtasks::GTask>, String>> {
    let cid = g.client_id.clone();
    let sec = g.client_secret.clone();
    let path = Config::google_token_path();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(crate::integrations::gtasks::fetch_all(&cid, &sec, &path));
    });
    rx
}

/// Spawn a background thread that fetches a month's Google Calendar events.
fn spawn_calendar_fetch(
    g: &crate::config::GoogleConfig,
    year: i32,
    month: u32,
) -> Receiver<std::result::Result<Vec<crate::integrations::gcal::CalEvent>, String>> {
    let cid = g.client_id.clone();
    let sec = g.client_secret.clone();
    let path = Config::google_token_path();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(crate::integrations::gcal::fetch_month(&cid, &sec, &path, year, month));
    });
    rx
}

/// Spawn a background thread that lists a Drive folder's children, returning the
/// requested folder id alongside the result (so stale fetches can be ignored).
/// Make a Drive file name safe to use as a single temp-file path component
/// (Drive names can contain `/` and other separators).
fn sanitize_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if matches!(c, '/' | '\\' | '\0') { '_' } else { c })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "drive-file".to_string()
    } else {
        trimmed.to_string()
    }
}

fn spawn_drive_list(
    g: &crate::config::GoogleConfig,
    parent: &str,
) -> Receiver<DriveListResult> {
    let cid = g.client_id.clone();
    let sec = g.client_secret.clone();
    let path = Config::google_token_path();
    let parent = parent.to_string();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let res = crate::integrations::gdrive::list_folder(&cid, &sec, &path, &parent);
        let _ = tx.send((parent, res));
    });
    rx
}

/// Load pinned notes from `.onyx/bookmarks.json` (a JSON array of vault-relative
/// paths), dropping any that no longer exist.
fn load_bookmarks(vault: &Vault) -> Vec<PathBuf> {
    let raw = std::fs::read_to_string(vault.bookmarks_path()).unwrap_or_default();
    let rels: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
    rels.into_iter()
        .map(|r| vault.root.join(r))
        .filter(|p| p.exists())
        .collect()
}

/// The full `/` slash-command catalog (Notion-style block inserts). Built fresh
/// each call so dynamic items (today's date) stay current.
fn slash_items() -> Vec<SlashItem> {
    let date = today().format("%Y-%m-%d").to_string();
    let mk = |icon: &'static str, label: &str, before: &str, after: &str| SlashItem {
        icon,
        label: label.to_string(),
        before: before.to_string(),
        after: after.to_string(),
    };
    vec![
        mk("◆", "Callout (note)", "> [!note] ", ""),
        mk("✦", "Callout (tip)", "> [!tip] ", ""),
        mk("⚠", "Callout (warning)", "> [!warning] ", ""),
        mk("⛔", "Callout (danger)", "> [!danger] ", ""),
        mk("❝", "Callout (quote)", "> [!quote] ", ""),
        mk("▾", "Callout (foldable)", "> [!note]- ", ""),
        mk("▦", "Columns", "::: columns\n", "\n+++\n\n:::"),
        mk("⌗", "Code block", "```\n", "\n```"),
        mk("☷", "Table", "| Header | Header |\n| --- | --- |\n| Cell | Cell |", ""),
        mk("☐", "To-do", "- [ ] ", ""),
        mk("•", "Bullet list", "- ", ""),
        mk("1.", "Numbered list", "1. ", ""),
        mk("H1", "Heading 1", "# ", ""),
        mk("H2", "Heading 2", "## ", ""),
        mk("H3", "Heading 3", "### ", ""),
        mk("—", "Divider", "---\n", ""),
        mk("◷", &format!("Date — {date}"), &date, ""),
    ]
}

/// Fuzzy-rank slash items against `query` (empty query lists them all).
fn compute_slash_matches(query: &str) -> Vec<SlashItem> {
    let items = slash_items();
    if query.is_empty() {
        return items;
    }
    let matcher = SkimMatcherV2::default();
    let mut scored: Vec<(i64, SlashItem)> = items
        .into_iter()
        .filter_map(|it| matcher.fuzzy_match(&it.label, query).map(|s| (s, it)))
        .collect();
    scored.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    scored.into_iter().map(|(_, it)| it).collect()
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

/// Background vault search over the (already tag/path-filtered) `paths`. When the
/// query has free text, builds a case-insensitive byte regex and scans each
/// note's bytes line-by-line — no per-line allocation. With only operators (no
/// free text), emits one hit per file (its first non-empty line) so e.g.
/// `tag:rust` lists every Rust note. `line:N` restricts matches to that line.
/// Bails as soon as a newer search starts (`gen != epoch`) or the cap is hit.
fn search_worker(
    query: SearchQuery,
    paths: Vec<PathBuf>,
    epoch: u64,
    gen: Arc<AtomicU64>,
    tx: mpsc::Sender<SearchMsg>,
) {
    let re = if query.needle.is_empty() {
        None
    } else {
        match regex::bytes::RegexBuilder::new(&regex::escape(&query.needle))
            .case_insensitive(true)
            .build()
        {
            Ok(r) => Some(r),
            Err(_) => {
                let _ = tx.send(SearchMsg::Done(epoch));
                return;
            }
        }
    };
    let want_line = query.line; // 1-based
    let preview_of = |line: &[u8]| -> String {
        String::from_utf8_lossy(line).trim().chars().take(160).collect()
    };
    let mut count = 0usize;
    'files: for path in paths {
        if gen.load(Ordering::Relaxed) != epoch {
            return; // superseded — drop silently
        }
        let Ok(data) = std::fs::read(&path) else {
            continue;
        };
        match &re {
            // Free-text search: every matching line (optionally pinned to line N).
            Some(re) => {
                for (i, line) in data.split(|&b| b == b'\n').enumerate() {
                    if let Some(n) = want_line {
                        if i + 1 != n {
                            continue;
                        }
                    }
                    if re.is_match(line) {
                        let hit = SearchHit { path: path.clone(), line: i, preview: preview_of(line) };
                        if tx.send(SearchMsg::Hit(epoch, hit)).is_err() {
                            return;
                        }
                        count += 1;
                        if count >= SEARCH_CAP {
                            break 'files;
                        }
                    }
                }
            }
            // Filters only: one hit per file (the target line, or first non-blank).
            None => {
                let mut chosen: Option<(usize, String)> = None;
                for (i, line) in data.split(|&b| b == b'\n').enumerate() {
                    let is_target = match want_line {
                        Some(n) => i + 1 == n,
                        None => !line.iter().all(|b| b.is_ascii_whitespace()),
                    };
                    if is_target {
                        chosen = Some((i, preview_of(line)));
                        break;
                    }
                }
                if let Some((i, preview)) = chosen {
                    let hit = SearchHit { path: path.clone(), line: i, preview };
                    if tx.send(SearchMsg::Hit(epoch, hit)).is_err() {
                        return;
                    }
                    count += 1;
                    if count >= SEARCH_CAP {
                        break 'files;
                    }
                }
            }
        }
    }
    let _ = tx.send(SearchMsg::Done(epoch));
}

/// Background scan for unlinked mentions: notes (outside `exclude`) whose text
/// contains any of `names` as a whole word. Sends `(epoch, hits)` once done;
/// bails if superseded (`gen != epoch`).
fn unlinked_worker(
    names: Vec<String>,
    exclude: std::collections::HashSet<PathBuf>,
    paths: Vec<PathBuf>,
    epoch: u64,
    gen: Arc<AtomicU64>,
    tx: mpsc::Sender<(u64, Vec<PathBuf>)>,
) {
    let mut hits = Vec::new();
    for path in paths {
        if gen.load(Ordering::Relaxed) != epoch {
            return; // superseded
        }
        if exclude.contains(&path) {
            continue;
        }
        let Ok(data) = std::fs::read(&path) else {
            continue;
        };
        let hay = String::from_utf8_lossy(&data).to_lowercase();
        if names.iter().any(|n| contains_word(&hay, n)) {
            hits.push(path);
            if hits.len() >= UNLINKED_CAP {
                break;
            }
        }
    }
    let _ = tx.send((epoch, hits));
}

/// Background AI worker: streams a chat completion from Ollama, forwarding each
/// delta as an `AiMsg` tagged with `epoch`. `cancel` stops it mid-stream.
fn ai_worker(
    host: String,
    model: String,
    messages: Vec<crate::integrations::ollama::ChatMessage>,
    epoch: u64,
    cancel: Arc<AtomicBool>,
    tx: mpsc::Sender<AiMsg>,
) {
    let tx2 = tx.clone();
    let res = crate::integrations::ollama::chat_stream(
        &host,
        &model,
        &messages,
        &cancel,
        |chunk| {
            let _ = tx2.send(AiMsg::Delta(epoch, chunk));
        },
    );
    match res {
        Ok(()) => {
            let _ = tx.send(AiMsg::Done(epoch));
        }
        Err(e) => {
            let _ = tx.send(AiMsg::Err(epoch, e));
        }
    }
}

/// Background autocomplete worker: ask the fast model for a short continuation
/// of `context`, accumulate it, and deliver it once (epoch-tagged).
fn ghost_worker(
    host: String,
    model: String,
    context: String,
    epoch: u64,
    cancel: Arc<AtomicBool>,
    tx: mpsc::Sender<(u64, std::result::Result<String, String>)>,
) {
    use crate::integrations::ollama::ChatMessage;
    let sys = "You are an inline autocomplete engine for a Markdown notes editor. Continue the \
               user's text from exactly where it stops. Output ONLY the continuation to insert \
               at the cursor — no quotes, no explanation, no code fences, at most one short \
               sentence. If nothing sensible follows, output nothing.";
    let user = format!("Continue this text:\n\n{context}");
    let messages = vec![ChatMessage::system(sys), ChatMessage::user(user)];
    let mut acc = String::new();
    let res = crate::integrations::ollama::chat_stream(&host, &model, &messages, &cancel, |chunk| {
        acc.push_str(&chunk.content);
    });
    let _ = match res {
        Ok(()) => tx.send((epoch, Ok(acc))),
        Err(e) => tx.send((epoch, Err(e))),
    };
}

/// Reduce a model completion to a single short ghost suggestion.
fn clean_ghost(s: &str) -> String {
    let line = s.lines().map(|l| l.trim()).find(|l| !l.is_empty()).unwrap_or("");
    let line = line.trim_matches('"').trim_matches('`').trim();
    line.chars().take(120).collect()
}

/// Tidy an LLM rewrite: trim, and strip a single surrounding ```fence``` if the
/// model wrapped the whole output in one despite being told not to.
fn clean_rewrite_output(s: &str) -> String {
    let t = s.trim();
    if t.starts_with("```") && t.ends_with("```") && t.len() > 6 {
        // Drop the opening ```/```lang line and the closing ``` line.
        let inner = &t[3..t.len() - 3];
        let body = inner.split_once('\n').map(|(_, rest)| rest).unwrap_or(inner);
        return body.trim().to_string();
    }
    t.to_string()
}

/// Inputs for a RAG worker run.
struct RagJob {
    root: PathBuf,
    notes: Vec<(String, u64)>,
    host: String,
    embed_model: String,
    question: String,
}

/// Background RAG worker: (re)embed changed notes into the on-disk index, embed
/// the query, and return the top-K chunks. Reports progress; bails if superseded.
fn rag_worker(job: RagJob, epoch: u64, gen: Arc<AtomicU64>, tx: mpsc::Sender<RagMsg>) {
    use crate::rag;
    let RagJob { root, notes, host, embed_model, question } = job;

    // Load the cache; reset it if it was built with a different embed model.
    let mut index = rag::load_index(&root);
    if index.model != embed_model {
        index = rag::RagIndex {
            model: embed_model.clone(),
            notes: std::collections::HashMap::new(),
        };
    }
    // Drop notes that no longer exist.
    let present: std::collections::HashSet<&String> = notes.iter().map(|(p, _)| p).collect();
    index.notes.retain(|p, _| present.contains(p));

    // Notes that are new or whose mtime changed need (re)embedding.
    let stale: Vec<(String, u64)> = notes
        .iter()
        .filter(|(p, m)| index.notes.get(p).map(|ne| ne.mtime != *m).unwrap_or(true))
        .cloned()
        .collect();
    let total = stale.len();
    let _ = tx.send(RagMsg::Progress(epoch, 0, total));

    for (i, (path, mtime)) in stale.iter().enumerate() {
        if gen.load(Ordering::Relaxed) != epoch {
            return; // superseded
        }
        let content = std::fs::read_to_string(path).unwrap_or_default();
        let chunks = rag::chunk_note(&content, 1000);
        if chunks.is_empty() {
            index
                .notes
                .insert(path.clone(), rag::NoteEmbeds { mtime: *mtime, chunks: Vec::new() });
        } else {
            let texts: Vec<String> = chunks.iter().map(|c| c.text.clone()).collect();
            match crate::integrations::ollama::embed(&host, &embed_model, &texts) {
                Ok(vecs) => {
                    let embedded: Vec<rag::EmbeddedChunk> = chunks
                        .into_iter()
                        .zip(vecs)
                        .map(|(c, v)| rag::EmbeddedChunk { text: c.text, line: c.line, q: rag::pack(&v) })
                        .collect();
                    index
                        .notes
                        .insert(path.clone(), rag::NoteEmbeds { mtime: *mtime, chunks: embedded });
                }
                Err(e) => {
                    let _ = tx.send(RagMsg::Err(epoch, e));
                    return;
                }
            }
        }
        let _ = tx.send(RagMsg::Progress(epoch, i + 1, total));
    }

    let _ = rag::save_index(&root, &index);

    // Embed the query, then rank.
    let qvec = match crate::integrations::ollama::embed(&host, &embed_model, std::slice::from_ref(&question)) {
        Ok(mut v) if !v.is_empty() => v.remove(0),
        Ok(_) => {
            let _ = tx.send(RagMsg::Err(epoch, "empty query embedding".into()));
            return;
        }
        Err(e) => {
            let _ = tx.send(RagMsg::Err(epoch, e));
            return;
        }
    };
    let hits = rag::top_k(&index, &qvec, RAG_TOP_K);
    let _ = tx.send(RagMsg::Ready(epoch, question, hits));
}

/// True if `needle` occurs in `hay` as a whole word (boundaries are anything but
/// `[A-Za-z0-9_]`). Both are expected lowercased. Used for unlinked mentions so
/// "java" doesn't match inside "javascript".
fn contains_word(hay: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    let hb = hay.as_bytes();
    for (i, _) in hay.match_indices(needle) {
        let before_ok = i == 0 || !is_word_byte(hb[i - 1]);
        let after = i + needle.len();
        let after_ok = after >= hb.len() || !is_word_byte(hb[after]);
        if before_ok && after_ok {
            return true;
        }
    }
    false
}

fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
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

#[cfg(test)]
mod tests {
    use super::{clean_rewrite_output, contains_word, parse_search_query};

    #[test]
    fn strips_surrounding_code_fence_from_rewrite() {
        assert_eq!(clean_rewrite_output("```md\nHello world\n```"), "Hello world");
        assert_eq!(clean_rewrite_output("```\nplain\n```"), "plain");
        // No fence → just trimmed.
        assert_eq!(clean_rewrite_output("  already clean  "), "already clean");
        // Inline backticks must not be mistaken for a fence.
        assert_eq!(clean_rewrite_output("use `code` here"), "use `code` here");
    }

    #[test]
    fn parses_search_operators() {
        let q = parse_search_query("tag:Rust path:projects line:3 async runtime");
        assert_eq!(q.needle, "async runtime");
        assert_eq!(q.tags, vec!["rust"]); // lowercased
        assert_eq!(q.paths, vec!["projects"]);
        assert_eq!(q.line, Some(3));
        assert!(!q.is_empty());
    }

    #[test]
    fn search_query_strips_hash_and_handles_filters_only() {
        let q = parse_search_query("#work tag:#home");
        // `#work` is free text (only `tag:`/`path:`/`line:` are operators).
        assert_eq!(q.needle, "#work");
        assert_eq!(q.tags, vec!["home"]); // leading # stripped from tag value
        let only_ops = parse_search_query("tag:rust");
        assert!(only_ops.needle.is_empty() && !only_ops.is_empty());
        assert!(parse_search_query("   ").is_empty());
    }

    #[test]
    fn contains_word_respects_boundaries() {
        assert!(contains_word("learning java today", "java"));
        assert!(!contains_word("i love javascript", "java")); // substring, not a word
        assert!(contains_word("see [java]", "java")); // punctuation is a boundary
        assert!(contains_word("java", "java"));
        assert!(!contains_word("", "java"));
        assert!(!contains_word("anything", ""));
    }
}
