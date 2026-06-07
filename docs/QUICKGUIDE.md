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
│   └── watcher.rs       — optional fs watcher (notify) — wired but unused
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

1. **`main()`** (`src/main.rs:31`)
   - Parse argv (`parse_args`, `src/main.rs:85`).
   - Load `Config` from `~/.config/onyx/config.toml` (`Config::load`, `src/config.rs:118`).
   - Resolve the vault path: CLI arg → `config.last_vault` → `~/OnyxVault` (`resolve_vault_path`, `src/main.rs:126`).
   - `Vault::open` or `Vault::create` — both end at a fully-indexed `Vault` (`src/vault/mod.rs:25` / `:34`).
   - Build `App::new(vault, config)` (`src/app.rs:154`) and auto-open the most-recent note.

2. **`run()`** (`src/main.rs:141`)
   - Enables crossterm raw mode, enters the alternate screen, enables mouse capture.
   - Constructs the `CrosstermBackend` + `Terminal`, calls `term.clear()`.
   - Hands control to `event_loop()`. Guarantees that no matter how the loop exits, the terminal is restored.

3. **`event_loop()`** (`src/main.rs`)
   - The only loop in the program. Each iteration:
     1. `app.tick_graph()` — advance the force-directed graph if it's on screen (sets `needs_redraw` when it moves).
     2. Redraw (`term.draw(|f| ui::draw(f, app))`) **only if `app.needs_redraw`** (then clear the flag), plus one redraw when a status toast expires.
     3. If `app.should_quit`, flush side panes and return.
     4. `crossterm::event::poll(timeout)` where `timeout` = ~70 ms while the graph animates, ~200 ms while a toast is up, else **block ~indefinitely** until input (idle = ~0 CPU).
     5. On a key event: `dispatch::on_key`, set `needs_redraw`, opportunistically `save_quicknote`. On resize: set `needs_redraw`. Drain any queued external program (fzf/yazi).

4. **`dispatch::on_key()`** (`src/dispatch.rs`)
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
// src/app.rs:115
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

    // file tree state
    pub tree_selected: usize,
    pub expanded_dirs: HashSet<PathBuf>,
    pub expanded_gen: u64,              // + FileTree::gen = visible-rows cache key
    pub tree_view_cache: RefCell<Option<(u64, u64, Vec<TreeRow>)>>,

    // overlay states
    pub palette, switcher: PaletteState,
    pub search: SearchState,
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
    pub needs_redraw: bool,             // dirty-render gate
    pub theme_gen: u64,                 // bumped on theme change (preview cache key)
    pub preview_cache: RefCell<Option<PreviewCache>>,
    pub should_quit: bool,
}
```

Why one big struct: with a single-threaded immediate-mode TUI, the cost of a borrow-checker arena is way higher than the cost of a wide struct. Every handler takes `&mut App` and is free to mutate anything; every renderer takes `&App` (or `&mut App` if it wants to lazy-clamp scroll or selection indices). This is the deliberate design.

Two sub-rules that keep this manageable:

- **Renderers don't mutate model state.** They may clamp transient view state (scroll offsets, selection indices that grew past list length) — that's it. See `editor_pane::draw` (`src/ui/editor_pane.rs:18`) where it adjusts `doc.scroll` to keep the cursor visible before painting.
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

`NoteIndex::resolve(target)` (`src/vault/index.rs:160`) is how a `[[Wikilink]]` becomes a `PathBuf`. It tries an exact relative-path match first, then falls back to basename match.

### `Document` — one open note

```rust
// src/editor/mod.rs:13
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
}
```

`Buffer` is intentionally simple: a `Vec<String>` of lines plus a `Cursor { line, col }` measured in **grapheme clusters**. All motion methods (`move_left`, `move_word_forward`, etc.) operate in grapheme space and convert to bytes only at the edges. See `Buffer::col_to_byte` (`src/editor/buffer.rs:69`) for the conversion.

History is per-document and takes whole-buffer snapshots, coalesced by a 400ms idle window. Cheap because notes are small. See `History::record` (`src/editor/history.rs:41`).

### `Theme` — pure derivation from config

```rust
// src/theme.rs
pub struct Theme { /* 20-ish ColorSpec fields + Style helpers */ }
```

A theme is resolved once at startup (`Config::resolve_theme`, `src/config.rs:139`) and re-resolved when the user switches via the palette (`set_theme`, `src/dispatch.rs:634`). Renderers ask the theme for styled spans via `theme.s_heading(level)`, `theme.s_wikilink()`, etc. — they never construct colors inline.

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
          │   if show_preview: [editor 55%] [preview 45%]  else editor_pane only
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
- `ui::pane_block(title, focused, theme)` (`src/ui/mod.rs:118`) — builds the rounded `Block` with the focus-aware border. Use this; don't roll your own border.
- `ui::centered_rect(w, h, outer)` (`src/ui/mod.rs:104`) — used by every modal overlay.

---

## 8. The event pipeline

```
crossterm::event::read()  →  Event::Key(KeyEvent)
        │
        ▼
dispatch::on_key(app, key)         (src/dispatch.rs:13)
        │
        ▼
global_shortcut(app, key)          (src/dispatch.rs:35)
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
   CommandLine → cmdline_keys     vim `:` ex commands, see § 8.1
```

### 8.1 Vim ex command line

`:` from any non-text-entry focus opens `Focus::CommandLine`, which replaces the bottom status row with a `:` prompt (`src/ui/cmdline.rs`). It is *not* opened when the editor is in `Mode::Insert` — `:` is a literal character there.

The handler is `dispatch::cmdline_keys` (`src/dispatch.rs`) and the parser is `dispatch::run_ex_command`. Supported forms today:

| Form                   | Action                              |
|------------------------|-------------------------------------|
| `:q`, `:quit`          | Quit (refuses if `doc.dirty`)       |
| `:q!`, `:quit!`        | Force-quit                          |
| `:w`, `:write`         | Save current note                   |
| `:wq`, `:x`, `:wq!`    | Save and quit                       |
| `:e <name-or-path>`    | Open a note (wikilink → abs → relative-to-vault) |
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


Three patterns to know when adding a binding:

1. **Global chord that always works** → add a branch in `global_shortcut`.
2. **Per-focus binding** → add it in that focus's handler.
3. **Text-entry overlay** → handlers explicitly only treat `Char(c)` as input when `!key.modifiers.contains(CONTROL)` so that `Ctrl-Q` etc. still escape the overlay.

The `in_text_overlay` guard in `global_shortcut` (`src/dispatch.rs:55`) is what prevents `Ctrl-P` from re-opening the palette while you're already typing in it.

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

---

## 10. Indexing and link resolution

When `Vault::open` runs:

1. `FileTree::scan(root)` walks the tree using `ignore::WalkBuilder` (respects `.gitignore`, skips hidden dirs like `.onyx/`). It collects both notes **and** directories, so empty folders appear in the tree.
2. `NoteIndex::build(root, tree)` reads each `.md` file and calls `ingest()` per note, which records basename/relpath lookups, extracts links (`[[wikilinks]]` **and** `[text](note.md)` markdown links) and tags (inline `#tags` **and** YAML frontmatter `tags:`), stores the raw targets, and resolves what it can.
3. `recompute_backlinks()` then re-resolves every note's raw targets (now that all notes are indexed) and rebuilds the inverse map `backlinks: HashMap<PathBuf, Vec<PathBuf>>`.

Link resolution (`resolve` → `resolve_internal`) is **case-insensitive** and tries, in order: full `folder/sub/name` (extension stripped), then basename, then the last path component as a basename. Duplicate basenames in different folders resolve to the first — link by relative path to disambiguate.

The ingestion entry point is `update_note(root, path, content)` — call it after any file write. It's **incremental for existing notes**: it removes the note's old outgoing edges, re-indexes just that note, and adds its new edges (O(note)). A *brand-new* note falls back to a full `recompute_backlinks` (it may resolve other notes' previously-unresolved links). `remove_note` = `unindex_note_meta` + backlink-graph cleanup.

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
| Global chord (e.g. `Ctrl-Shift-X`) | `global_shortcut` in `src/dispatch.rs:35` |
| Editor normal-mode key | `editor_normal` in `src/dispatch.rs:316` |
| Editor insert-mode key | `editor_insert` in `src/dispatch.rs:262` |
| File tree key | `filetree_keys` in `src/dispatch.rs:152` |
| Overlay key | the matching `*_keys` function |

Also add an entry to `keymap::GLOSSARY` (`src/keymap.rs:8`) so it shows in the help overlay.

### Adding a palette command

1. Add a variant to `CommandId` in `src/ui/palette.rs:18`.
2. Add a `Command { label, hint, id }` row to `COMMANDS` (`src/ui/palette.rs:41`).
3. Add a match arm in `run_command` (`src/dispatch.rs:578`) for what it does.

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

Put the disk operation on `Vault` (`src/vault/mod.rs`). Make sure it calls `self.refresh()` or `self.index.update_note(...)` so the in-memory state stays consistent. Then expose it as a palette command or keybinding.

### Adding a new model field that needs to persist

Add it to `Config` (`src/config.rs`) with `#[serde(default)]` and a `Default` impl. Save via `app.config.save()` at the moment of change (not on a tick — keeps it auditable).

---

## 13. Known shape constraints

These are properties of the codebase you should preserve unless you're explicitly redesigning:

- **One App, one event loop.** Don't introduce a second mutable owner of vault state. If you need background work (search indexing, file watching), use a channel and drain it on tick (see the placeholder in `event_loop`).
- **Renderers don't `read()` files.** All disk I/O goes through `Vault`. The preview re-renders from the in-memory `Buffer`; backlinks come from `NoteIndex`. If a renderer hits the filesystem, it'll cause hitches at 60Hz.
- **Redraw is dirty-gated.** The loop repaints only when `App::needs_redraw` is set (or the graph is animating). If you add state that changes what's on screen *without* a keypress, set `needs_redraw` (e.g. `set_status` does). Otherwise the change won't show until the next input.
- **Don't re-walk the file tree.** Use `App::visible_tree()` (cached `Vec<TreeRow>`) for the flattened, visible rows; never call `FileTree::flatten` directly in hot paths. It invalidates on rescan (`FileTree::gen`, bumped by every `scan()`) and on expand/collapse (`expanded_gen`, via `App::invalidate_tree_view`).
- **No retained widgets, but cache derived data.** Render builds fresh `Span`/`Line`/`Text` each frame; don't cache widget instances. Heavy derived data *is* cached behind a revision/key — the preview `Text` (`App::preview_cache`) and the graph layout (`App::graph_sim`). The animating graph goes a step further and writes its node field **straight into `frame.buffer_mut()`** (`ui/graph.rs` `put_cell`/`draw_line_buf`) instead of building `Text`, since it's the per-frame hot path — use that pattern only where allocation churn actually matters.
- **Wikilink resolution is centralized.** `NoteIndex::resolve` is the only function that knows the matching rules. Don't reimplement them in renderers or dispatch.
- **The Buffer cursor is in grapheme clusters, not bytes or codepoints.** Conversions happen in `col_to_byte` / `byte_to_col`. New buffer ops must stay in grapheme space at the public API.

---

## 14. Quick file index

When you need to find something fast:

| Looking for | Open |
|---|---|
| App entry / event loop | `src/main.rs` |
| All app state | `src/app.rs` (the `App` struct) |
| Any keybinding | `src/dispatch.rs` (start at `on_key`, `:13`) |
| The pane layout | `src/ui/mod.rs` (`draw_body`, `:59`) |
| Theme colors | `src/theme.rs` |
| Filesystem rules | `src/vault/mod.rs` |
| Link/tag/backlink logic | `src/vault/index.rs` |
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
