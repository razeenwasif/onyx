# Onyx — Working Context (handoff)

Pick-up notes for resuming work. For deep architecture see **`docs/QUICKGUIDE.md`**;
for the task queue see **`docs/BACKLOG.md`**. This file is the "where we are right now".

_Last updated: 2026-06-11._

> **Resume here (2026-06-11, evening):** Notion MCP ✅ connected & authed;
> workspace inventoried; migration fully planned in **`docs/NOTION_MIGRATION.md`**
> (conventions + every page/collection ID). The first 4-agent migration run died
> on the session usage limit (resets 6pm Sydney) — **zero files written**. On
> resume: relaunch the 4 background domain agents (Finance, Degree Planning,
> Courses, Entertainment+Work) per that doc (create-only under
> `~/OnyxVault/Notion/`), verify in Onyx, reconcile counts. After migration:
> **Phase 2 — database/table + board views** keyed by frontmatter properties.

---

## What Onyx is

A single-binary **Rust + ratatui TUI** markdown notes app — an Obsidian-inspired
terminal vault. ~8.5k LOC. Stack: `ratatui` 0.29 + `crossterm` (TUI),
`pulldown-cmark` (markdown), `regex` (search/parse), `ignore`/`walkdir` (vault
scan), `serde`+`toml` (config), `chrono` (calendar), `fuzzy-matcher` (palette/switcher).

**Repo:** https://github.com/razeenwasif/onyx (public, `main`), authed as
`razeenwasif` over SSH. Installed on PATH via `cargo install --path .` →
`~/.cargo/bin/onyx`.

---

## Environment / facts

- Working dir: `/home/amaterasu/Onyx`. Platform: WSL2 (Linux). `git` repo.
- **Real vault:** `~/OnyxVault` (~680 markdown notes, imported from the Windows
  Obsidian vault at `/mnt/c/Users/Razeen/Documents/Obsidian`, excluding
  `.obsidian/.claude/.claudian`). `config.toml` `last_vault` points here.
- **Config:** `~/.config/onyx/config.toml`. **Override with `ONYX_CONFIG=/path`**
  (or `ONYX_CONFIG_DIR`) — used for all test runs so they never touch the real
  config. A linter has occasionally reset `last_vault` to `/tmp/onyx-test-vault`;
  if asked, set it back to `/home/amaterasu/OnyxVault`.
- This vault links notes mostly via **YAML frontmatter `tags:`** (677/678 notes)
  and `publish.obsidian.md` web URLs — almost no local `[[wikilinks]]` or
  `[text](note.md)` links. So the graph is **tag-connected**, not link-connected.
- Tools present (for `:fzf`/`:rg`/`:yazi`): `fzf`, `rg`, `bat`, `yazi`,
  `xdg-open`. `fd` is **not** installed (we use `rg --files`/`rg -t markdown`).
- Truecolor terminal needed for the graph's RGB subject colors.

## Build / run / verify

```bash
cargo build --release
cargo clippy --all-targets -- -D warnings   # MUST stay clean (CI-ready)
cargo test                                   # 27 tests, all green
cargo install --path . --force               # reinstall onyx on PATH
onyx                                          # opens last_vault (~/OnyxVault)
```
**Reinstall after every change you want to use from the `onyx` command.**
`cargo build` only refreshes `target/release/onyx`; the PATH binary at
`~/.cargo/bin/onyx` is updated *only* by `cargo install --path . --force`. (This
bit us once: a stale installed binary opened on an old build with no Home screen
even though the source was current.)

There's no GUI here; the app is verified by driving it through a Python **pty**
harness — `ONYX_CONFIG_DIR=/tmp/...` for config isolation, size the pty, send
keys, and reconstruct the screen grid. The most reliable harness uses **`pyte`**
(a real terminal emulator: `pip install --user pyte`) rather than stripping ANSI
by hand — naive stripping mis-reads absolutely-positioned popups. Reuse that.

---

## Feature state (all working)

- **Panes / layout** (all default-on): left column = Files → Quicknote → Todo;
  center = Editor + Preview; right column = tabs (Backlinks/Outline/Tags) →
  Graph → Calendar (fixed height, bottom).
- **Editor:** vim-style modal (normal/insert), motions, undo/redo (byte-capped).
- **Markdown:** live inline highlight in the editor; cached block render in the
  preview. Wikilinks, `[md](links)`, inline `#tags` **and** frontmatter `tags:`.
- **Graph:** force-directed (`graph_sim.rs`), **whole-vault "earth" by default**
  (`a` toggles local), Obsidian-style **colored dots, no labels** (colors from
  the vault's GRAPH_COLORS_SETUP subject scheme via `node_color`), animates when
  focused/fullscreen, **compact tiny `·` dots in the sidebar pane**. `Ctrl-G`
  focus, `Enter` fullscreen, `o` open node, `Esc` back.
- **Calendar / daily notes**, **quicknote** scratch (`.onyx/quicknote.md`),
  **todo** checklist (`.onyx/todos.md`) — `.onyx/` is hidden, excluded from the
  tree/index.
- **Folders:** `:mkdir`, file-tree `m`, subfolder notes (`:new Folder/Name`),
  empty folders show in the tree, new note/folder relative to the selection.
- **Delete confirmation:** yes/no dialog before deleting notes/folders (folders
  recursive). `y` confirms; `n`/Esc/anything cancels.
- **Page properties (Notion hybrid, Phase 1):** all top-level YAML frontmatter
  keys (beyond `tags:`) are parsed into `NoteMeta.properties` and shown as a
  clean **Properties** block atop the preview (raw frontmatter stripped from the
  body). Foundation for databases/table views. See QUICKGUIDE § 10 + the
  ⭐ "Notion + Obsidian hybrid" epic in BACKLOG.
- **`[[` wikilink autocomplete:** typing `[[` in the editor (insert mode) pops a
  fuzzy note-name picker; Up/Down select, Enter/Tab insert `[[Name]]`, Esc
  dismisses (stays in insert). `App::link_complete` + `refresh_link_complete`;
  popup drawn by `editor_pane::draw_link_popup`. See QUICKGUIDE § 9.1.
- **Home start page:** Onyx opens on an interactive start page (center pane) —
  New note / New folder / Search / Open note… / Today's daily note, then recent
  notes; `j/k` + Enter. No more auto-opening the last note. Falls back here when
  the open note is deleted. `App::home_items` is the single source of truth; see
  QUICKGUIDE § 7.1.
- **Fast startup (persistent index cache):** the index's per-note facts are
  cached to `<vault>/.onyx/index-cache.json` and reused for notes whose mtime is
  unchanged, so a relaunch only re-parses what changed (~26× faster warm rebuild,
  109 ms → 4 ms on 678 notes). `vault::build_index` (load→build→save) backs both
  open and refresh; pure optimization, never authoritative. See QUICKGUIDE § 10.
- **Filesystem sync (robustness trio):** **atomic saves** (temp + fsync + rename,
  crash-safe); **conflict guard** (prompts before overwriting a note changed on
  disk — `:w!`/`:wq!` force); **live file watcher** (external edits refresh the
  tree/index/graph; a clean open buffer live-reloads, a dirty one warns and keeps
  your edits). `:e!` reloads from disk. Self-writes + dot-paths are filtered so
  there's no self-reindex storm; idle CPU stays ~0. See QUICKGUIDE § 8.4.
- **Command surfaces:** command palette (`Ctrl-P`), quick switcher (`Ctrl-O`),
  vault search (`Ctrl-Shift-F`, non-blocking), vim **ex command line** (`:`),
  Telescope-style aliases (`:Telescope find_files/live_grep/...`), external
  tools (`:fzf`, `:rg`, `:yazi` — suspend TUI, run, resume).
- **Themes:** dark/light/dracula/nord (+ custom). Help overlay `Ctrl-/`.

---

## What we did today (chronological)

1. **Built the whole app from scratch** (initial commit) — vault/editor/markdown/
   ui modules, event loop.
2. **Docs:** wrote `docs/QUICKGUIDE.md` (architecture map).
3. **Installed on PATH** + **imported** the Windows Obsidian vault → `~/OnyxVault`.
4. **Vim ex-command line** (`:q`, `:w`, `:wq`, `:e`, `:new`, `:set`, `:<N>`, …).
5. **`ONYX_CONFIG` override** so tests don't clobber the real config.
6. **Telescope-style commands** + `:calendar` + **fzf/yazi/rg integration**
   (suspend/resume via `external.rs`); remapped `live_grep` to the fzf preview;
   fixed it (was `.output()` piping → fzf couldn't render; now inherits the
   terminal + temp-file selection); scoped pickers to markdown; bulletproof
   `open_external` (detached, WSL-aware).
7. **Calendar → docked pane** in the right column (bottom, fixed height).
8. **Graph overhaul:** colored dots (no labels) by subject → animated
   force-directed → **whole-vault default** → **Barnes-Hut** → compact sidebar.
9. **Frontmatter tags + markdown-link indexing** (the graph was empty because
   the vault uses frontmatter tags; added `extract_frontmatter_tags`,
   `extract_md_links`; graph became tag-aware).
10. **Folders** (subfolder notes, `:mkdir`, `m`, empty folders in tree).
11. **Delete confirmation** dialog (+ recursive folder delete).
12. **Status-bar hints** for the new commands.
13. **Bug fixes** from an external review (rename targeted the wrong note;
    folder-qualified links collapsed; undo marked clean docs dirty; vault-switch
    left stale state) + cleared all clippy lints.
14. **Full performance pass** (see below).
15. **Saved a memory:** always update docs before every commit/push.

## Performance pass — COMPLETE (all shipped & verified)

1. **Dirty-flag rendering** (`App::needs_redraw`) — idle CPU ~0 (loop blocks on
   input; fast poll only while the graph animates / search streams).
2. **Preview render cache** (`App::preview_cache`, keyed by note/`Buffer::revision`/
   width/`theme_gen`).
3. **Incremental backlinks** — editing an existing note is O(note), not O(vault).
4. **History byte cap** (~4 MiB) + **panic hook** (restores terminal on crash).
5. **Barnes-Hut graph repulsion** (`graph_sim.rs`, quadtree, THETA=0.85) —
   ~0.57 ms/frame @678 nodes, ~1.48 ms @1500 (was ~2–15 ms).
6. **Graph render-buffer reuse** — writes node field straight into
   `frame.buffer_mut()` (`put_cell`/`draw_line_buf`), ~0 allocs/frame.
7. **File-tree flatten cache** (`App::visible_tree()`, keyed by `FileTree::gen` +
   `expanded_gen`).
8. **Non-blocking search** — background worker + `regex::bytes` matcher, streamed
   over `mpsc`, epoch/`Arc<AtomicU64>` cancellation.
9. **Path/tag interning** — `Arc<Path>` / `Arc<str>` in the index; public API
   still returns `PathBuf`/`String`. Idle RSS on the 678-note vault ~8 MB.

---

## Conventions to keep (don't regress)

- **Update docs before every commit/push** (QUICKGUIDE/BACKLOG/README) — this is
  a standing rule (saved to memory). This CONTEXT.md too when state changes.
- **Clippy must pass** with `-D warnings`; tests must stay green.
- **Redraw is dirty-gated** — if state changes the screen without a keypress, set
  `app.needs_redraw` (e.g. `set_status` does).
- **No file I/O in renderers** — go through `Vault`; read derived data from
  `NoteIndex` / caches.
- **Don't re-walk the tree** — use `App::visible_tree()`.
- **Wikilink/path resolution is centralized** in `NoteIndex::resolve`.
- **Buffer cursor is in grapheme clusters**, not bytes.
- **Background work pattern:** worker thread + `mpsc` + epoch + `Arc<AtomicU64>`
  cancel, drained each loop tick (see search).
- **Test runs set `ONYX_CONFIG`** to a temp file; never touch `~/.config/onyx`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## What's next (from `docs/BACKLOG.md`)

**Primary direction (2026-06-11): the ⭐ Notion + Obsidian hybrid epic** — make
Onyx a Notion/Obsidian hybrid and migrate the user's Notion in. Phased:

1. **Page properties** ✅ done (Phase 1).
2. **Database / table + board views** over a folder, keyed by frontmatter props
   (`:database <folder>`; board grouped by a select-like property). ← next
3. **Nested structure polish** (child-page nav, breadcrumbs).
4. **Block editing** — callouts (`> [!note]`), toggles, columns, slash-insert.
5. **Notion import** — *blocked on the user connecting the Notion MCP*
   (`claude mcp add --transport http notion https://mcp.notion.com/mcp`, then
   `/mcp` to OAuth). Once live: inventory Notion → map → `:notion import`. Let the
   real Notion structure refine Phase 2's property types/views.

Smaller Obsidian-feel items still open: unlinked mentions in Backlinks, search
operators (`tag:`/`path:`/`line:`). Other backlog: lazy background cold-scan,
Google Calendar/Drive, external-tool config, scrollable help.

---

## Recent commits (newest first)

```
00dd9b2 Notion hybrid Phase 1: page properties
96052d0 Docs: note that `onyx` on PATH needs `cargo install --force` after changes
dd393e5 Add [[wikilink]] autocomplete in the editor
e8f353c Open on an interactive Home start page instead of the last note
6210547 Perf: persistent index cache for fast startup
c5bfdf9 Docs: document filesystem sync + refresh QUICKGUIDE line refs
197854e Robustness: atomic saves, conflict guard, live file watcher
fa14a06 Add CONTEXT.md handoff doc
6b46e23 Perf: intern paths (Arc<Path>) and tags (Arc<str>) in the index
92cfbf7 Perf: non-blocking background vault search
f9fc3c1 Perf: cache the flattened file-tree view
011c37f Graph perf: render node field directly into the frame buffer
afed18a Graph: compact tiny-dot rendering for the sidebar pane; docs refresh
159b32b Graph perf: Barnes-Hut repulsion (O(n log n))
12c93e2 Perf: dirty-flag rendering, preview cache, incremental backlinks, history cap
df0d4b9 Confirm before deleting notes and folders
725a381 Status bar: add hints for new commands
bd59394 Add folder support: subfolder notes, mkdir, folder-aware new note
5d8459f Graph: default to whole-vault "earth" view (all nodes)
4057596 Graph: animated force-directed layout with more nodes
ac6ce6d Graph: Obsidian-style colored node dots (no labels)
0ba15ab Fix 4 bugs found in review + clean up clippy
3a1a521 Initial commit: Onyx — a premium markdown notes TUI
```
