# Onyx — Architecture Quickguide

A scannable map of how Onyx is wired. Read top-to-bottom in ~15 minutes and you should know where any given concern lives.

> All path/line references in this guide are relative to the repo root and point at the file as it stands today. They will drift; treat them as starting points, not promises.

---

## 1. What it is

Onyx is a single-binary Rust TUI for editing a vault of markdown notes. It is:

- **Single-threaded.** One event loop, one terminal, one frame at a time.
- **Stateless on disk between sessions** except for `~/.config/onyx/config.toml` and the vault itself.
- **Immediate-mode, dirty-gated.** The whole screen is rebuilt from `App` state, but only when something changed (`App::needs_redraw`) or the graph is animating — an idle Onyx blocks on input and uses ~no CPU. ratatui still diffs at the cell level. Two render-time caches exist: the preview's rendered markdown (keyed by note/revision/width/theme) and the graph's force-directed layout (persisted in `App::graph_sim`).
- **Plain-text first.** A note is just a `.md` file on disk. The index is rebuilt from disk; it is never the source of truth.

The stack:

| Layer        | Crate                | What it gives us                         |
|--------------|----------------------|------------------------------------------|
| Terminal I/O | `crossterm`          | Raw mode, alt screen, key events, colors |
| Widgets      | `ratatui` 0.29       | `Frame`, `Layout`, `Block`, `Paragraph`  |
| Markdown     | `pulldown-cmark`     | CommonMark + GFM event stream            |
| Fuzzy match  | `fuzzy-matcher`      | Skim-style scoring for palette/switcher  |
| Filesystem   | `ignore`, `walkdir`  | Gitignore-aware vault traversal          |
| Persistence  | `serde` + `toml`     | Config (de)serialization                 |
| Index cache  | `serde_json`         | `.onyx/index-cache.json` (fast startup)  |
| Dates        | `chrono`             | Calendar + daily notes                   |

---

## 2. Crate layout at a glance

```
src/
├── main.rs              — entry, CLI parse, terminal setup, event loop, panic hook
├── app.rs               — App state struct + the only place state lives
├── dispatch.rs          — key router: every keybinding lands here
├── config.rs            — TOML config load/save (+ ONYX_CONFIG override)
├── theme.rs             — color palettes and Style helpers
├── keymap.rs            — static glossary used by the help overlay
├── todo.rs              — todo checklist model (.onyx/todos.md)
├── graph_sim.rs         — force-directed sim + Barnes-Hut quadtree
├── external.rs          — suspend TUI, run fzf/yazi, resume
├── error.rs             — OnyxError + Result alias
│
├── editor/
│   ├── mod.rs           — Document = path + buffer + history + mode
│   ├── buffer.rs        — Vec<String> text buffer, grapheme cursor, revision
│   ├── history.rs       — snapshot undo/redo, coalesced, byte-capped
│   └── modes.rs         — Normal | Insert | Visual | OpPending
│
├── vault/
│   ├── mod.rs           — Vault facade: open/create, read/write/delete, folders
│   ├── tree.rs          — recursive file tree (notes + empty dirs)
│   ├── index.rs         — link/tag/backlink index (incremental update)
│   ├── index_cache.rs   — persistent index cache (.onyx/index-cache.json)
│   └── watcher.rs       — fs watcher (notify): drives live-reload + conflict sync
│
├── markdown/
│   ├── mod.rs           — re-exports
│   ├── parse.rs         — [[wikilinks]], [md](links), #tags + frontmatter tags
│   └── render.rs        — pulldown-cmark events → ratatui Text
│
└── ui/
    ├── mod.rs           — compositor: draw(), left/right columns, fullscreen
    ├── title_bar.rs     — top row: name, vault path, stats
    ├── status.rs        — bottom row: mode, cursor, focus hints
    ├── file_tree.rs     — Files pane (left column, top)
    ├── quicknote.rs     — Quicknote scratch pane (left column)
    ├── todo.rs          — Todo checklist pane (left column)
    ├── home.rs          — start page (interactive action menu; shown when no note is open)
    ├── editor_pane.rs   — center pane (the editor itself)
    ├── preview.rs       — rendered preview (cached)
    ├── sidebar.rs       — right column: tabs + graph + calendar panes
    ├── calendar.rs      — month grid for daily notes
    ├── graph.rs         — force-directed graph (dots+colors; compact/fullscreen)
    ├── palette.rs       — Ctrl-P command palette overlay
    ├── switcher.rs      — Ctrl-O quick note switcher overlay
    ├── search.rs        — Ctrl-Shift-F full-vault search overlay
    ├── help.rs          — Ctrl-/ keybinding overlay
    ├── prompt.rs        — generic "type a value" overlay
    ├── confirm.rs       — yes/no confirmation dialog (delete)
    └── cmdline.rs       — vim `:` ex command line
```

The shape to internalize: **state in `app.rs`, decisions in `dispatch.rs`, pixels in `ui/`.** Anything you add should slot into one of those three.

---

## 3. Module dependency graph

```
                          main.rs
                             │
                ┌────────────┼────────────┐
                ▼            ▼            ▼
              app          dispatch       ui::draw
                │            │            │
                └─────┬──────┴─────┬──────┘
                      │            │
        ┌─────────────┼────────────┼────────────┐
        ▼             ▼            ▼            ▼
     vault         editor       markdown      theme
        │             │            │            ▲
        └─────────────┴────► markdown::parse ──┘
                                                ▲
                                                │
                                            config
```

Read this as: `main` owns the loop, hands every key to `dispatch`, then asks `ui::draw` to repaint from `app`. `dispatch` and `ui` both depend on `app` (because `App` is the world). `vault`, `editor`, `markdown`, `theme` are leaf-ish — they don't reach upward into `app`.

The one cycle worth noting: `vault::index` calls `markdown::parse` to extract links/tags during indexing. Tree of one direction; not a real cycle.

---

## 4. The lifecycle

The whole program in one walk-through:

1. **`main()`** (`src/main.rs:34`)
   - Parse argv (`parse_args`, `src/main.rs:88`).
   - Load `Config` from `~/.config/onyx/config.toml` (`Config::load`, `src/config.rs:159`).
   - Resolve the vault path: CLI arg → `config.last_vault` → `~/OnyxVault` (`resolve_vault_path`, `src/main.rs:129`).
   - `Vault::open` or `Vault::create` — both end at a fully-indexed `Vault` (`src/vault/mod.rs:27` / `:39`). Indexing goes through `vault::build_index`, which reuses the on-disk cache to skip re-parsing unchanged notes (§ 10).
   - Build `App::new(vault, config)` (`src/app.rs`), which starts on the **Home** start page (`Focus::Home`, no note auto-opened — see § 7.1) and arms the filesystem watcher on the vault root (§ 8.4).

2. **`run()`** (`src/main.rs:144`)
   - Enables crossterm raw mode, enters the alternate screen, enables mouse capture.
   - Constructs the `CrosstermBackend` + `Terminal`, calls `term.clear()`.
   - Hands control to `event_loop()`. Guarantees that no matter how the loop exits, the terminal is restored.

3. **`event_loop()`** (`src/main.rs:176`)
   - The only loop in the program. Each iteration, before drawing, it runs three cheap "drains":
     1. `app.tick_graph()` — advance the force-directed graph if it's on screen (sets `needs_redraw` when it moves).
     2. `app.drain_search()` — apply any results streamed from the background search worker.
     3. `app.handle_fs_events()` — react to external file changes the watcher noticed (§ 8.4).
   - Then:
     4. Redraw (`term.draw(|f| ui::draw(f, app))`) **only if `app.needs_redraw`** (then clear the flag), plus one redraw when a status toast expires.
     5. If `app.should_quit`, flush side panes and return.
     6. `crossterm::event::poll(timeout)` where `timeout` = ~70 ms while the graph animates / a search streams, ~200 ms while a toast is up, **1 s while a watcher is active** (so external edits are caught promptly), else **block ~indefinitely** until input (idle = ~0 CPU).
     7. On a key event: `dispatch::on_key`, set `needs_redraw`, opportunistically `save_quicknote`. On resize: set `needs_redraw`. Drain any queued external program (fzf/yazi).

4. **`dispatch::on_key()`** (`src/dispatch.rs:14`)
   - First runs `global_shortcut` for Esc + the `:` ex-line trigger + `Ctrl-*` chords.
   - If not consumed, routes to a focus-specific handler — one per `Focus` variant (`filetree_keys`, `quicknote_keys`, `todo_keys`, `editor_keys`, `sidebar_keys`, `calendar_keys`, `graph_keys`, `palette_keys`, `switcher_keys`, `search_keys`, `prompt_keys`, `confirm_keys`, `cmdline_keys`, `help_keys`).
   - Mutates `App` in place. Never touches the terminal directly.

5. **`ui::draw()`** (`src/ui/mod.rs`)
   - Splits the frame vertically into title (1 row), body, status/cmdline (1 row).
   - `match app.fullscreen`: `Graph`/`Calendar` fill the body; otherwise `draw_body` splits into left column / center / right column.
   - Modal overlays (`Palette`, `Switcher`, `Search`, `Help`, `Prompt`, `Confirm`) paint on top via `Clear` + a centered rect.

The render reads `App` directly; the only "update step" is `tick_graph` (graph physics). Everything else is event-driven.

---

## 5. State — there's exactly one place

```rust
// src/app.rs:237
pub struct App {
    pub config: Config,           // persisted user prefs
    pub theme: Theme,             // resolved palette (derived from config)
    pub vault: Vault,             // the only model of disk + index
    pub doc: Option<Document>,    // the currently-open note, if any
    pub focus: Focus,             // who owns the keyboard
    pub last_focus: Focus,        // restore target after closing an overlay

    // layout toggles (snapshotted from / to config)
    pub show_left, show_right, show_preview: bool,
    pub show_graph_pane, show_calendar, show_quicknote, show_todo: bool,
    pub fullscreen: Option<FullPane>,   // Graph or Calendar filling the body
    pub sidebar_tab: SidebarTab,        // Backlinks | Outline | Tags

    // home start page
    pub home_selected: usize,        // selected row in App::home_items()
    pub link_complete: Option<LinkComplete>,  // [[wikilink]] autocomplete popup

    // file tree state
    pub tree_selected: usize,
    pub expanded_dirs: HashSet<PathBuf>,
    pub expanded_gen: u64,              // + FileTree::gen = visible-rows cache key
    pub tree_view_cache: RefCell<Option<(u64, u64, Vec<TreeRow>)>>,

    // overlay states
    pub palette, switcher: PaletteState,
    pub search: SearchState,
    pub search_epoch: u64,              // background-search generation
    pub search_gen: Arc<AtomicU64>,    // worker cancellation token
    pub search_rx: Option<Receiver<SearchMsg>>, // streamed results
    pub prompt: PromptState,            // {label, value, action, target}
    pub confirm: ConfirmState,          // {message, action} — yes/no dialog
    pub cmdline: CmdlineState,          // vim `:` ex line + history
    pub help_open: bool,

    // graph
    pub graph_focus: Option<PathBuf>,
    pub graph_sim: Option<GraphSim>,    // force-directed layout (persisted)
    pub graph_global: bool,             // whole-vault "earth" vs local

    // left-column side panes
    pub quicknote: QuicknoteState,      // scratch buffer → .onyx/quicknote.md
    pub todos: TodoList,                // checklist → .onyx/todos.md
    pub calendar: CalendarState,

    pub sidebar_selected: usize,
    pub status_msg: Option<(String, Instant)>,  // transient toast
    pub pending_external: Option<PendingExternal>, // fzf/yazi to run

    // filesystem sync (§ 8.4)
    pub watcher: Option<VaultWatcher>,  // notify-based external-change watcher
    pub recent_self_writes: HashMap<PathBuf, Instant>, // suppress self-triggered reindex

    pub needs_redraw: bool,             // dirty-render gate
    pub theme_gen: u64,                 // bumped on theme change (preview cache key)
    pub preview_cache: RefCell<Option<PreviewCache>>,
    pub should_quit: bool,
}
```

Why one big struct: with a single-threaded immediate-mode TUI, the cost of a borrow-checker arena is way higher than the cost of a wide struct. Every handler takes `&mut App` and is free to mutate anything; every renderer takes `&App` (or `&mut App` if it wants to lazy-clamp scroll or selection indices). This is the deliberate design.

Two sub-rules that keep this manageable:

- **Renderers don't mutate model state.** They may clamp transient view state (scroll offsets, selection indices that grew past list length) — that's it. See `editor_pane::draw` (`src/ui/editor_pane.rs:13`) where it adjusts `doc.scroll` to keep the cursor visible before painting.
- **Handlers don't render.** They mutate, set `status_msg`, maybe flip `should_quit`. The next loop iteration draws.

---

## 6. The three model types

### `Vault` — disk + index facade

```rust
// src/vault/mod.rs:18
pub struct Vault {
    pub root: PathBuf,
    pub tree: FileTree,    // recursive folder/file structure (vault/tree.rs)
    pub index: NoteIndex,  // links + tags + backlinks  (vault/index.rs)
}
```

The vault is the only place that touches the filesystem during normal operation. Any time you read/write/delete a note, go through `Vault::read_note`, `write_note`, `delete_note`, `rename_note` — they keep `tree` and `index` in sync. After any structural change call `vault.refresh()` to re-walk and re-index.

**Writes are atomic.** `write_note` goes through `vault::atomic_write` (`src/vault/mod.rs`), which writes a hidden `.<name>.<pid>.<n>.onyxtmp` sibling, fsyncs it, then `rename`s it over the target. A crash mid-write can never truncate the real note. `vault::file_mtime` exposes a note's on-disk modification time for the conflict guard below.

`NoteIndex::resolve(target)` (`src/vault/index.rs:209`) is how a `[[Wikilink]]` becomes a `PathBuf`. It tries an exact relative-path match first, then falls back to basename match.

### `Document` — one open note

```rust
// src/editor/mod.rs:14
pub struct Document {
    pub path: Option<PathBuf>,    // None = unsaved scratch buffer
    pub buffer: Buffer,           // Vec<String> + Cursor
    pub history: History,         // undo/redo snapshots
    pub mode: Mode,               // Normal | Insert | Visual | OpPending
    pub dirty: bool,
    pub scroll: usize,            // top-of-viewport line
    pub anchor: Option<Cursor>,   // selection start (unused today)
    pub pending_op: Option<char>, // operator-pending state ('d' awaiting motion)
    pub last_search: Option<String>,
    pub disk_mtime: Option<SystemTime>, // on-disk mtime when last read/written
}
```

`disk_mtime` is the spine of the **conflict guard** and **live reload** (see § 8.4). It's stamped on `open_note`, after every save, and after a live reload.

`Buffer` is intentionally simple: a `Vec<String>` of lines plus a `Cursor { line, col }` measured in **grapheme clusters**. All motion methods (`move_left`, `move_word_forward`, etc.) operate in grapheme space and convert to bytes only at the edges. See `Buffer::col_to_byte` (`src/editor/buffer.rs:78`) for the conversion.

History is per-document and takes whole-buffer snapshots, coalesced by a 400ms idle window. Cheap because notes are small. See `History::record` (`src/editor/history.rs:69`).

### `Theme` — pure derivation from config

```rust
// src/theme.rs
pub struct Theme { /* 20-ish ColorSpec fields + Style helpers */ }
```

A theme is resolved once at startup (`Config::resolve_theme`, `src/config.rs:182`) and re-resolved when the user switches via the palette (`set_theme`, `src/dispatch.rs:683`). Renderers ask the theme for styled spans via `theme.s_heading(level)`, `theme.s_wikilink()`, etc. — they never construct colors inline.

---

## 7. The render pipeline

```
ui::draw(frame, app)
    │
    ├─ split vertical: [title 1] [body] [status 1]
    │
    ├─ title_bar::draw         ◀── app.vault.root + app.doc.title() + index.stats()
    ├─ status::draw            ◀── app.doc.mode + cursor + status_msg
    │
    ├─ match app.fullscreen:
    │     Some(Graph)    → graph::draw(body, focused=true)   (fills body)
    │     Some(Calendar) → draw_calendar_fullscreen(body)
    │     None           → draw_body(body)
    │
    └─ draw_body(body):
          split horizontal: [left? L cols] [center min(40)] [right? R cols]
          ├─ draw_left_column (if show_left), stacked vertically:
          │    ├─ file_tree::draw   (Min — flexible)   ◀── tree + expanded_dirs
          │    ├─ quicknote::draw   (Length, if show_quicknote)  ◀── app.quicknote.buffer
          │    └─ todo::draw        (Length, if show_todo)       ◀── app.todos
          ├─ center:
          │   if doc.is_none():  home::draw (start page, fills center — see § 7.1)
          │   elif show_preview: [editor 55%] [preview 45%]   else editor_pane only
          └─ sidebar::draw (right column), stacked vertically:
               ├─ draw_tabbed (Min)  — tabs: Backlinks · Outline · Tags
               ├─ graph::draw (Min, if show_graph_pane)   ◀── Focus::Graph
               └─ draw_calendar_pane (Length calendar_height, if show_calendar) ◀── Focus::Calendar

Panes are toggled by `App::show_{left,right,preview,graph_pane,calendar,quicknote,todo}` (all but graph/preview default on). `Focus::{Graph,Calendar}` + Enter sets `App::fullscreen` to expand that pane over the body; Esc clears it. Quicknote/Todo persist to `.onyx/quicknote.md` / `.onyx/todos.md` (hidden dir, skipped by the scanner).

[then overlays:]
    Focus::Palette  → palette::draw  (centered, Clear, then redraw)
    Focus::Switcher → switcher::draw
    Focus::Search   → search::draw
    Focus::Help     → help::draw
    Focus::Prompt   → prompt::draw
```

Two visual conventions every pane shares:
- `ui::pane_block(title, focused, theme)` (`src/ui/mod.rs:161`) — builds the rounded `Block` with the focus-aware border. Use this; don't roll your own border.
- `ui::centered_rect(w, h, outer)` (`src/ui/mod.rs:147`) — used by every modal overlay.

### 7.1 The Home start page

When no note is open (`app.doc.is_none()`), the center renders the **Home start page** (`src/ui/home.rs`) instead of the editor — an interactive menu of quick actions (New note, New folder, Search vault, Open note…, Today's daily note) followed by the most-recent notes. Onyx launches here (`App::new` sets `Focus::Home`, and `main` no longer auto-opens the last note), and falls back here when the open note is deleted.

The rows are produced by `App::home_items()` — the single source of truth that both the renderer and the key handler (`dispatch::home_keys`) read, so the displayed list and the Enter action can't drift. `home_selected` tracks the cursor; `j/k` move, `Enter`/`l`/`Space` activate. Actions delegate to existing flows: `App::activate_home` handles Search/Switcher/DailyNote/OpenRecent, while New note / New folder open a prompt via `dispatch::start_prompt` (dispatch owns that helper). Opening any note sets `doc` + `Focus::Editor`, so Home disappears. The `App::center_focus()` helper returns `Editor` when a doc is open else `Home`, and is used everywhere a pane previously hard-coded "focus the editor".

---

## 8. The event pipeline

```
crossterm::event::read()  →  Event::Key(KeyEvent)
        │
        ▼
dispatch::on_key(app, key)         (src/dispatch.rs:14)
        │
        ▼
global_shortcut(app, key)          (src/dispatch.rs:40)
   ├─ Esc → app.escape()           — closes overlays / leaves insert mode
   ├─ Ctrl-Q → app.should_quit
   ├─ Ctrl-P → app.open_palette()
   ├─ Ctrl-O → app.open_switcher()
   ├─ Ctrl-Shift-F → app.open_search()
   ├─ Ctrl-N → start_prompt(NewNote, ...)
   ├─ Ctrl-S → app.save_current()
   ├─ Ctrl-E/B/R/G/K/T → layout toggles
   ├─ Ctrl-/ → app.open_help()
   ├─ Ctrl-1..4 → focus pane N
   └─ returns true if consumed
        │
        ▼  (if not consumed)
match app.focus:
   FileTree  → filetree_keys      j/k Enter Space d r n …
   Editor    → editor_keys → editor_normal / editor_insert
   Preview   → editor_keys        (Tab cycles back)
   Sidebar   → sidebar_keys       Tab/Shift-Tab/j/k Enter
   Calendar  → calendar_keys      h/j/k/l Enter t
   Palette   → palette_keys       text entry + Up/Down + Enter
   Switcher  → switcher_keys
   Search    → search_keys
   Prompt    → prompt_keys
   Help      → help_keys
   Graph     → graph_keys
   Home      → home_keys          j/k Enter (start page actions), see § 7.1
   CommandLine → cmdline_keys     vim `:` ex commands, see § 8.1
```

### 8.1 Vim ex command line

`:` from any non-text-entry focus opens `Focus::CommandLine`, which replaces the bottom status row with a `:` prompt (`src/ui/cmdline.rs`). It is *not* opened when the editor is in `Mode::Insert` — `:` is a literal character there.

The handler is `dispatch::cmdline_keys` (`src/dispatch.rs`) and the parser is `dispatch::run_ex_command`. Supported forms today:

| Form                   | Action                              |
|------------------------|-------------------------------------|
| `:q`, `:quit`          | Quit (refuses if `doc.dirty`)       |
| `:q!`, `:quit!`        | Force-quit                          |
| `:w`, `:write`         | Save current note (conflict-guarded) |
| `:w!`, `:write!`       | Force-save, overwriting external changes |
| `:wq`, `:x`            | Save and quit                       |
| `:wq!`, `:x!`          | Force-save and quit                 |
| `:e <name-or-path>`    | Open a note (wikilink → abs → relative-to-vault) |
| `:e!`                  | Reload current note from disk (discard buffer) |
| `:new <title>`         | Create a new note and enter insert mode |
| `:rename <title>`      | Rename current note                 |
| `:delete`, `:rm`       | Delete current note                 |
| `:today`               | Open today's daily note             |
| `:help`, `:h`          | Open the help overlay               |
| `:graph`               | Open graph view                     |
| `:calendar`, `:cal`    | Open the calendar pane              |
| `:preview`             | Toggle preview pane                 |
| `:search <q>`          | Vault content search (native)       |
| `:vault <path>`        | Open / create vault                 |
| `:set theme=<name>`    | Switch theme (dark/light/dracula/nord) |
| `:set (no)preview / (no)numbers / (no)wrap / (no)left / (no)right` | Toggle layout/editor switches |
| `:<N>`                 | Jump to line N in current document  |
| `:fzf`, `:files`       | Fuzzy file finder via **fzf** (external) |
| `:rg`, `:grep`         | Live-grep file contents via **fzf+ripgrep** |
| `:yazi`, `:browse`     | File manager via **yazi** (PDF/image preview) |
| `:Telescope <picker>`  | Neovim-Telescope-style aliases (see § 8.2) |

Add a command by appending an arm to the `match cmd { … }` in `run_ex_command`. Also add a row to `keymap::GLOSSARY` so it shows in the help overlay. Up/Down scroll cmdline history (kept in `App::cmdline.history`, capped at 100, dedup'd against the most recent).

### 8.2 Telescope-style aliases

For muscle memory from Neovim's Telescope, `:Telescope <picker> [query]` maps each picker to its Onyx equivalent (`dispatch::run_telescope`):

| Picker | Maps to |
|--------|---------|
| `find_files`, `git_files` | native quick switcher (optionally pre-filled with the query) |
| `fzf` | external fzf picker |
| `live_grep`, `grep_string`, `rg` | external fzf+ripgrep with a bat preview pane |
| `native_grep` | in-process vault search overlay (runs the query if given) |
| `buffers`, `oldfiles` | quick switcher in recency order |
| `help_tags`, `keymaps` | help overlay |
| `file_browser` | yazi |

Bare `:Telescope` prints the available pickers in the status bar.

### 8.3 External tools (fzf / yazi)

External terminal programs run with the Onyx TUI suspended. The flow respects the "handlers don't touch the terminal" invariant:

1. A handler sets `App::pending_external = Some(PendingExternal::…)` (via `dispatch::request_external`, which first checks the tool is on `$PATH`).
2. The event loop (`main::event_loop`) drains it after dispatch and calls `external::handle`.
3. `external::handle` (`src/external.rs`) tears down the alternate screen + raw mode, runs the tool, then restores them and calls `drain_pending_input()` to discard any stray bytes (trailing keystrokes, terminal query replies) so they aren't misread as editor input.
4. The selected path is opened as a note if it's markdown, otherwise handed to the system opener (`wslview`/`xdg-open`).

fzf draws its UI on `/dev/tty`, so its stdout (the selection) is captured cleanly. yazi uses `--chooser-file` to report the chosen path. `external.rs` is the single chokepoint for spawning external programs — add new ones there.

**Scope & opening rules.** `:fzf` and `:rg`/live_grep are scoped to markdown notes (`rg -t markdown`) — this is a notes app, so use `:yazi` to browse PDFs/images/scripts. When a selection comes back: markdown and other plain-text files open in the editor; anything else (PDF, image) is handed to the system opener via `open_external`, which is fully detached (`Stdio::null()` on stdin/stdout/stderr) so it can never corrupt the alternate screen, and is WSL-aware (`wslview`/`explorer.exe` before `xdg-open`).

**Live-grep is real, not fuzzy-over-everything.** `run_fzf_grep` runs fzf in `--disabled` mode with `start`/`change` reload bindings that re-run `rg -t markdown {q}` on each keystroke (Telescope-style) — ripgrep does the matching, fzf just displays + previews. Neither picker passes `--height`, so fzf takes its own fullscreen alternate screen and renders cleanly above the suspended Onyx instead of inline over the shell.


### 8.4 Filesystem sync (watcher, live reload, conflict guard)

Onyx keeps in sync with external editors (Obsidian, VS Code, git, a sync client) instead of going stale. Three cooperating pieces:

- **Watcher** — `vault::VaultWatcher` (`src/vault/watcher.rs`) wraps `notify` (inotify on Linux). It runs on its own thread and pushes each changed *path* over a channel. `drain()` returns the deduped paths.
- **Reaction** — `App::handle_fs_events` runs each loop tick. Because `crossterm::event::poll` only watches stdin, the event loop caps the idle timeout at `watch_poll` (1 s) whenever a watcher is present, so changes are noticed promptly while idle CPU stays ~0 (a per-second empty channel drain). It ignores events for **dot-paths** (`is_internal_path`: `.git`/`.obsidian`/`.onyx`/`.onyxtmp`) and for **Onyx's own writes** (`recent_self_writes`, a path→`Instant` map with a 5 s TTL) so a save never triggers a self-reindex. Any remaining external change triggers `vault.refresh()` + cache invalidation + `reconcile_open_doc`.
- **Reconcile** — `App::reconcile_open_doc` compares the open doc's `disk_mtime` to the file's current mtime. A **clean** buffer reloads seamlessly (`reload_current`); a **dirty** buffer is left untouched with a `⚠ … changed on disk` warning so edits are never lost; a deleted file gets its own warning.

The **conflict guard** lives in `App::save_current_inner(force)`: before writing, if the file's mtime differs from the doc's known `disk_mtime`, it opens a `ConfirmAction::OverwriteNote` dialog instead of clobbering the external version. `:w!`/`:wq!` (and confirming the dialog) call `force_save_current`, which bypasses the check. After any successful write the doc's `disk_mtime` is restamped so the next save doesn't false-positive.

Three patterns to know when adding a binding:

1. **Global chord that always works** → add a branch in `global_shortcut`.
2. **Per-focus binding** → add it in that focus's handler.
3. **Text-entry overlay** → handlers explicitly only treat `Char(c)` as input when `!key.modifiers.contains(CONTROL)` so that `Ctrl-Q` etc. still escape the overlay.

The `in_text_overlay` guard in `global_shortcut` (`src/dispatch.rs:54`) is what prevents `Ctrl-P` from re-opening the palette while you're already typing in it.

---

## 9. The markdown pipeline

Two passes, two purposes:

| Pass | Where | Input | Output | Used for |
|------|-------|-------|--------|----------|
| Inline highlight | `editor_pane::render_line` (`src/ui/editor_pane.rs:135`) | one raw source line | `Vec<Span>` | live editor styling |
| Block render     | `markdown::render_to_text` (`src/markdown/render.rs:17`) | whole document | `Text<'static>` | preview pane |

We intentionally don't run the full CommonMark parser per-keystroke for the editor — that's too slow and visually distracting (it re-flows as you type). Inline highlighting handles headings, lists, wikilinks, tags, code spans, bold/italic on a line-by-line basis.

The preview pane caches its rendered `Text` on `App::preview_cache` (a `RefCell`), keyed by `(note path, buffer revision, width, theme_gen)`. The whole-buffer CommonMark parse runs only when one of those changes — not on cursor moves, graph ticks, or idle redraws. `Buffer::revision` is bumped by every mutating buffer method (and by undo/redo apply).

Wikilinks and tags are not CommonMark constructs. They're extracted by regex in `markdown::parse` and woven into the rendered text in `render::split_into_segments`. When indexing, `extract_links` / `extract_md_links` / `extract_all_tags` (inline `#tags` **and** YAML frontmatter `tags:`) are called on each note's content in `NoteIndex::ingest`.

### 9.1 `[[wikilink]]` autocomplete

While the editor is in insert mode and the cursor sits just after an unclosed `[[`, Onyx shows a fuzzy completion popup of note names (`App::link_complete: Option<LinkComplete>`). After every insert-mode edit, `dispatch::editor_insert` calls `App::refresh_link_complete`, which scans the current line's prefix for the last `[[` (rejecting any `[`/`]` after it) and, if open, fuzzy-ranks note basenames via `compute_link_matches` (the same `SkimMatcherV2` the switcher uses; an empty query lists recent notes). The popup is rendered by `draw_link_popup` in `editor_pane.rs`, anchored under the `[[` at the caret (flips above when there's no room below).

Key handling, while the popup is open: `Up`/`Down` move the selection (intercepted in `editor_insert` before the keystroke types through), `Tab`/`Enter` accept (`accept_link_complete` deletes the typed query and inserts `Name]]`), and `Esc` dismisses it while staying in insert mode — that last one is handled in `global_shortcut` (which sees `Esc` first), so a single `Esc` closes the popup and a second leaves insert mode. Leaving insert mode any other way clears `link_complete` in `App::escape`.

### 9.2 Database / table + board views (Notion hybrid, Phase 2)

A **database view** treats a folder as a Notion-style database: each direct-child note is a row, and the union of the notes' frontmatter properties are the columns. It's driven entirely off facts the index already extracted (`NoteMeta.properties`) — no extra file reads. State + logic live in `src/db_view.rs` (`DatabaseView`, pure and unit-tested); the renderer is `src/ui/database.rs`; key handling is `dispatch::database_keys`.

Open one with `:database [folder]` (aliases `:db`, `:table`; `:board` opens in board mode) or by pressing `t` on a folder in the file tree. With no folder argument the command infers one from the open note's folder, the tree selection, or the vault root (`resolve_db_folder`). `App::open_database` builds the view (`build_database`: filters notes whose parent is exactly the folder, excludes `_schema.md` sidecars) and sets `Focus::Database`; the view is **modal** and fills the whole body (routed in `ui::mod` before the fullscreen match), so `global_shortcut` swallows other ctrl shortcuts while it's open so focus can't drift.

- **Table** (`DbViewMode::Table`): columns ordered by frequency, with "housekeeping" keys (`source`, `notion-url`) pushed right; `h`/`l` scroll columns, `s` cycles the sort column, `S` flips direction (numeric when both cells parse as numbers, empties last).
- **Board** (`DbViewMode::Board`): groups by a select-like property auto-picked by `pick_group_by` (single-valued, 2–12 distinct values, ≥50% coverage); `[`/`]` change the group-by column; `h`/`l` move between groups, `j`/`k` between cards.
- `/` filters live (name + any cell, case-insensitive); `Enter`/`o`/`l` open the selected note (closing the view); `t`/`Tab` toggle table↔board; `Esc` cancels an active filter, then closes the view.

The active view is rebuilt from the index on external changes (`handle_fs_events` → `rebuild_database`, preserving mode/sort/group/filter/selection) and cleared on vault switch. It's closed while a note is open (opening a row sets `doc` and `database = None`).

### 9.3 Nested-structure navigation (Notion hybrid, Phase 3)

The vault's folder hierarchy doubles as a Notion-style **page tree**. A folder's representative "page" is its namesake note (`Foo/Foo.md`), else its database page (`Foo/_schema.md`), else its first contained note. The pure logic lives in `src/page_nav.rs` (`representative_note`, `parent_page`, `page_entries`, `breadcrumb`) over `FileTree` (`node_at` walks to a node); 7 unit tests cover it.

- **Breadcrumbs**: `editor_pane::draw` builds the pane title from `page_nav::breadcrumb(root, path, max)` — the ancestor trail joined with ` › `, fit to the pane width by keeping the trailing segments whole and eliding older ancestors with a leading `…`.
- **Pages sidebar tab** (`SidebarTab::Pages`, first in the tab cycle): `sidebar::draw_pages` lists `page_entries` — an `↑ parent` row, the current folder's child *folders* (each opening that folder's representative page), and its *notes* (the open note marked with `●`). Enter opens the selected row (`dispatch::sidebar_open_selected`), which naturally re-scopes the list to the new note's folder for drill-down/up.
- **`:up` / `:parent`** opens `page_nav::parent_page` — the page containing the current note (from a folder's own page it steps up another level).

---

## 10. Indexing and link resolution

When `Vault::open` runs:

1. `FileTree::scan(root)` walks the tree using `ignore::WalkBuilder` (respects `.gitignore`, skips hidden dirs like `.onyx/`). It collects both notes **and** directories, so empty folders appear in the tree.
2. `NoteIndex::build(root, tree)` reads each `.md` file and calls `ingest()` per note, which records basename/relpath lookups, extracts links (`[[wikilinks]]` **and** `[text](note.md)` markdown links), tags (inline `#tags` **and** YAML frontmatter `tags:`), and **page properties** (all other top-level YAML frontmatter keys → `NoteMeta.properties`, the Notion-hybrid foundation), stores the raw targets, and resolves what it can.
3. `recompute_backlinks()` then re-resolves every note's raw targets (now that all notes are indexed) and rebuilds the inverse map `backlinks: HashMap<PathBuf, Vec<PathBuf>>`.

Link resolution (`resolve` → `resolve_internal`) is **case-insensitive** and tries, in order: full `folder/sub/name` (extension stripped), then basename, then the last path component as a basename. Duplicate basenames in different folders resolve to the first — link by relative path to disambiguate.

The ingestion entry point is `update_note(root, path, content)` — call it after any file write. It's **incremental for existing notes**: it removes the note's old outgoing edges, re-indexes just that note, and adds its new edges (O(note)). A *brand-new* note falls back to a full `recompute_backlinks` (it may resolve other notes' previously-unresolved links). `remove_note` = `unindex_note_meta` + backlink-graph cleanup.

**Interning.** Paths and tags are interned as `Arc<Path>` / `Arc<str>` (`path_interner` / `tag_interner`): each unique value is allocated once and shared across every map by refcount-bump clones, rather than duplicating `PathBuf`/`String` copies. `NoteMeta.outgoing` is `Vec<Arc<Path>>` and `tags` is `Vec<Arc<str>>`. Public methods still return owned `PathBuf`/`String` (a boundary clone) so consumers are unaffected — when reading `index.notes` directly, convert with `.to_path_buf()` / deref. `HashMap<Arc<Path>, _>::get` accepts an `&Path` (via `Borrow`), so most lookups are unchanged.

**Page properties (Notion hybrid).** `markdown::parse::extract_frontmatter_properties` parses *every* top-level YAML frontmatter key into an ordered `Vec<(String, Vec<String>)>` (scalars are single-element; `[a, b]` arrays and `- block` lists are multi; scalars are not comma-split). `tags`/`tag` are excluded (they're surfaced as tags). These land on `NoteMeta.properties` and are cached. The preview pane renders them as a clean **Properties** block on top (`ui/preview.rs::build_preview_text`, which also `strip_frontmatter`s the raw YAML out of the body). This is Phase 1 of the Notion-hybrid epic (see `docs/BACKLOG.md`); Phase 2 (the database/table + board views keyed by these properties) shipped too — see §9.2.

**Persistent cache (startup scalability).** The entire index is derived from a handful of per-note facts — `title`, raw link `targets`, `tags`, `properties`, `size`, `word_count`, plus the file's `mtime` (the `ParsedNote` in `index.rs`). Everything else (resolution, backlinks, `by_tag`, interners) is recomputed in memory, which is cheap; the expensive part was always *reading and regex-parsing every file*. So those facts are cached to `<vault>/.onyx/index-cache.json` (`src/vault/index_cache.rs`). On launch, `NoteIndex::build_with_cache` stats each note and reuses the cached `ParsedNote` for any whose mtime is unchanged — only changed/new notes are read and parsed. Measured **~26× faster** on the 678-note vault (109 ms → 4 ms warm). The flow is centralized in `vault::build_index` (used by both `Vault::open` and `refresh`), which loads the cache, builds, then writes the refreshed cache (best-effort). The cache is **purely an optimization**: missing/stale/corrupt → more re-parsing, never wrong data (validated by `version` + per-note mtime). It lives in `.onyx/` so it's excluded from the scanner and ignored by the watcher (no self-reindex). Notes edited *inside* Onyx go through the incremental `update_note`, not `build_index`, so their cache entry refreshes on the next open (a one-time re-parse of just those notes).

---

## 11. Config and persistence

```toml
# ~/.config/onyx/config.toml
last_vault = "/home/you/Notes"
theme = "dark"            # or "light", "dracula", "nord", "custom"

[daily_notes]
folder = "Daily"
format = "%Y-%m-%d"
template = "..."          # optional; default is generated

[editor]
tab_size = 4
use_spaces = true
line_numbers = true
wrap = true
autosave = false
autosave_idle_ms = 2500

[layout]
sidebar_left_width = 26
sidebar_right_width = 30
editor_split_percent = 55  # editor's share of the center; preview takes the rest. Ctrl-←/→ to resize
show_preview = true
show_left_sidebar = true
show_right_sidebar = true
show_graph_pane = true     # graph in right column
show_calendar = true       # calendar docked bottom-right
show_quicknote = true      # scratch pane, left column
show_todo = true           # checklist pane, left column
quicknote_height = 7
todo_height = 9
calendar_height = 13

[custom_theme]
name = "My Theme"
bg = "#1e1e24"
# ... all ColorSpec fields
```

- `Config::load` is infallible — if the file is missing or corrupt it returns `Default::default()`. This means a partially-written or hand-edited config never bricks Onyx; it just falls back.
- All fields are `#[serde(default)]` — you can hand-write a 3-line `config.toml` and the rest fills in.
- `Config::save` is called automatically after: vault switch, theme change, anything that changes a `last_*` field. It's idempotent — overwrites the file each time.
- Theme resolution: `theme = "custom"` looks at `custom_theme = {...}`; any other value tries to match a built-in preset (case-insensitive).

**Config location override** (`Config::config_dir` / `config_path`): set `ONYX_CONFIG=/path/to/config.toml` to point at a specific file, or `ONYX_CONFIG_DIR=/some/dir` to hold `config.toml` elsewhere. Both reads *and* writes route through `config_path`, so this fully isolates a session — used for throwaway test runs so they never clobber your real `~/.config/onyx/config.toml`. Example: `ONYX_CONFIG=/tmp/onyx-test.toml onyx /tmp/test-vault`.

What is **not** persisted: cursor position per note, expanded folders, sidebar tab. Add a `[session]` table if you want those — but think about whether you actually do; a clean start each session is often the better UX.

---

## 12. Where to add things

A short field guide for the most common changes.

### Adding a keybinding

| Scope | Where to edit |
|-------|---------------|
| Global chord (e.g. `Ctrl-Shift-X`) | `global_shortcut` in `src/dispatch.rs:40` |
| Editor normal-mode key | `editor_normal` in `src/dispatch.rs:363` |
| Editor insert-mode key | `editor_insert` in `src/dispatch.rs:309` |
| File tree key | `filetree_keys` in `src/dispatch.rs:179` |
| Overlay key | the matching `*_keys` function |

Also add an entry to `keymap::GLOSSARY` (`src/keymap.rs:10`) so it shows in the help overlay.

### Adding a palette command

1. Add a variant to `CommandId` in `src/ui/palette.rs:21`.
2. Add a `Command { label, hint, id }` row to `COMMANDS` (`src/ui/palette.rs:43`).
3. Add a match arm in `run_command` (`src/dispatch.rs:629`) for what it does.

That's it — fuzzy filtering is automatic.

### Adding a sidebar tab

1. Add a variant to `SidebarTab` (`src/app.rs`) and update both `next()` and `prev()` to include it in the cycle.
2. Add a tab header in `draw_tabs` (`src/ui/sidebar.rs`).
3. Add a match arm in `draw_tabbed` (`src/ui/sidebar.rs`) that calls your renderer.
4. Add an arm in `sidebar_open_selected` (`src/dispatch.rs`) if Enter should do something for it.

The calendar is *not* a tab — it's a separate pane docked in the lower half of the right sidebar, gated by `App::show_calendar` and focused via `Focus::Calendar`. Toggle it with `App::open_calendar` / `hide_calendar`.

### Adding a theme

Add a `pub fn my_theme() -> Self` constructor on `Theme` in `src/theme.rs`, then add the name to `Theme::preset` (`src/theme.rs:181`). Add a palette command if you want it discoverable in the UI.

### Adding a vault operation (e.g. "move note to folder")

Put the disk operation on `Vault` (`src/vault/mod.rs`). Make sure it calls `self.refresh()` or `self.index.update_note(...)` so the in-memory state stays consistent. Write note **content** through `atomic_write` (which `write_note` already does), never a bare `fs::write`. Then expose it as a palette command or keybinding. If the App writes a note it then keeps open, call `App::record_self_write(path)` after the write so the watcher doesn't replay the save as an external change (§ 8.4).

### Adding a new model field that needs to persist

Add it to `Config` (`src/config.rs`) with `#[serde(default)]` and a `Default` impl. Save via `app.config.save()` at the moment of change (not on a tick — keeps it auditable).

---

## 13. Known shape constraints

These are properties of the codebase you should preserve unless you're explicitly redesigning:

- **One App, one event loop.** Don't introduce a second mutable owner of vault state. For background work, follow the **search pattern**: spawn a worker thread, stream results over an `mpsc` channel tagged with an epoch, drain it each loop tick (`App::drain_search`), and discard stale results via an `Arc<AtomicU64>` cancellation token. While a worker is in flight the loop polls fast so results stream in.
- **Renderers don't `read()` files.** All disk I/O goes through `Vault`. The preview re-renders from the in-memory `Buffer`; backlinks come from `NoteIndex`. If a renderer hits the filesystem, it'll cause hitches at 60Hz.
- **Redraw is dirty-gated.** The loop repaints only when `App::needs_redraw` is set (or the graph is animating). If you add state that changes what's on screen *without* a keypress, set `needs_redraw` (e.g. `set_status` does). Otherwise the change won't show until the next input.
- **Don't re-walk the file tree.** Use `App::visible_tree()` (cached `Vec<TreeRow>`) for the flattened, visible rows; never call `FileTree::flatten` directly in hot paths. It invalidates on rescan (`FileTree::gen`, bumped by every `scan()`) and on expand/collapse (`expanded_gen`, via `App::invalidate_tree_view`).
- **No retained widgets, but cache derived data.** Render builds fresh `Span`/`Line`/`Text` each frame; don't cache widget instances. Heavy derived data *is* cached behind a revision/key — the preview `Text` (`App::preview_cache`) and the graph layout (`App::graph_sim`). The animating graph goes a step further and writes its node field **straight into `frame.buffer_mut()`** (`ui/graph.rs` `put_cell`/`draw_line_buf`) instead of building `Text`, since it's the per-frame hot path — use that pattern only where allocation churn actually matters.
- **Wikilink resolution is centralized.** `NoteIndex::resolve` is the only function that knows the matching rules. Don't reimplement them in renderers or dispatch.
- **The Buffer cursor is in grapheme clusters, not bytes or codepoints.** Conversions happen in `col_to_byte` / `byte_to_col`. New buffer ops must stay in grapheme space at the public API.
- **Note writes are atomic and self-announced.** All note content reaches disk via `vault::atomic_write` (temp + fsync + rename), so a crash can't truncate a note — never `fs::write` a note directly. When the App saves a note it also calls `record_self_write`, so the filesystem watcher (§ 8.4) doesn't mistake the save for an external edit and reload over it. Anything that bypasses `write_note` must uphold both halves.

---

## 14. Quick file index

When you need to find something fast:

| Looking for | Open |
|---|---|
| App entry / event loop | `src/main.rs` |
| All app state | `src/app.rs` (the `App` struct) |
| Any keybinding | `src/dispatch.rs` (start at `on_key`, `:14`) |
| The pane layout | `src/ui/mod.rs` (`draw_body`, `:68`) |
| Theme colors | `src/theme.rs` |
| Filesystem rules | `src/vault/mod.rs` |
| Atomic save / mtime helpers | `src/vault/mod.rs` (`atomic_write`, `file_mtime`) |
| File watcher / live sync | `src/vault/watcher.rs` + `App::handle_fs_events` (`src/app.rs:603`) |
| Link/tag/backlink logic | `src/vault/index.rs` |
| Startup index cache | `src/vault/index_cache.rs` + `vault::build_index` |
| Markdown preview rules | `src/markdown/render.rs` |
| Wikilink/tag extraction | `src/markdown/parse.rs` |
| Text-buffer mechanics | `src/editor/buffer.rs` |
| Undo coalescing | `src/editor/history.rs` |
| Persisted settings | `src/config.rs` |
| Help text | `src/keymap.rs` |

---

## 15. Next docs

This is the architecture quickguide — the "where things live" map. Companion docs to write next, in roughly the order they'd be useful:

- **USER_GUIDE.md** — keybindings, vaults, daily notes, themes — for end users.
- **VAULT_FORMAT.md** — wikilink/tag syntax, daily-notes template variables, what Onyx writes to disk.
- **EXTENDING.md** — deeper than § 12 here: writing a new pane, custom theme files, configuring the keymap.
- **INTERNALS.md** — index data structures, rendering invariants, performance notes. For contributors who'll change core data flow.
