# Onyx Backlog

Running list of work to do. Newest items at the top of "Open". Move items to "Done" when shipped (oldest at the bottom).

## Open

### Performance pass — ✅ COMPLETE

All planned optimizations shipped (see Done): dirty-flag rendering, preview
render cache, incremental backlinks, history byte cap, panic hook, Barnes-Hut
graph repulsion, graph render-buffer reuse, file-tree flatten cache,
non-blocking search, and path/tag interning. Idle RSS on the 678-note vault is
~8 MB. Possible future micro-opts if ever needed: prune interner entries on
single-note delete (negligible leak today), SIMD literal search via
`grep-searcher`, multi-threaded search across files.

---

### Google Calendar sync into the calendar pane

**Context.** The calendar pane (`Ctrl-K` / `:calendar`) only knows about daily notes today — a cell is highlighted if a daily note exists for that date. The ask is to also surface Google Calendar events so the pane doubles as an agenda, and/or to two-way sync events with notes.

**Approach (read-only first, the safe MVP).**

- Auth: Google Calendar API via OAuth 2.0 "installed app" / device flow. We're a TUI with no browser, so device flow (show a code + URL the user opens elsewhere) is the right UX. Store the refresh token in `~/.config/onyx/google.json` (mode 600), never in `config.toml`.
- Add an optional `[google]` table to `Config`: `enabled`, `calendar_ids`, `token_path`. Feature-gate the whole thing behind a `google` cargo feature so the default build pulls no network/auth crates.
- New module `src/integrations/gcal.rs`: fetch events for the visible month, cache to `~/.config/onyx/cache/gcal-<month>.json` with a TTL so we're not hitting the network every render. Refresh on a background thread; the event loop drains results on tick (don't block the UI — see the tick placeholder in `event_loop`).
- Render: mark days with events using a distinct glyph/color in `src/ui/calendar.rs`; pressing Enter on a day with events could list them (new sidebar sub-view or a popup).
- Commands: `:gcal sync`, `:gcal today`, `:gcal auth`.

**Stretch.**

- Turn an event into a note (`:gcal note`) — create a note pre-filled from the event.
- Two-way: create/update events from specially-formatted notes. Much more complex (conflict handling); keep out of MVP.

**Risks / notes.**

- Crates: `oauth2`, `reqwest` (or `ureq` to stay lighter/blocking), `serde_json`. Prefer `ureq` + blocking on a worker thread over pulling in tokio.
- Network failures must degrade gracefully — the calendar pane still works offline from cache + daily notes.
- This is the heaviest item here; do the markdown-link and help-scroll items first.

---

### Google Drive access from within Onyx

**Context.** Browse/open Drive files (and ideally edit Drive-hosted markdown) without leaving Onyx.

**Approach.**

- Shares the OAuth/token plumbing with the Google Calendar item above — build that first, reuse `~/.config/onyx/google.json`.
- Simplest useful version: a Drive *picker*. New `PendingExternal`-style flow or an in-TUI list backed by `src/integrations/gdrive.rs` that lists files (Drive `files.list`), and on select downloads to a temp/working dir and opens in the editor. On save, upload back (`files.update`).
- Better long-term: mount Drive via `rclone mount` if the user has rclone, and just point a vault at the mountpoint — then Onyx needs *zero* Drive code and gets full filesystem semantics. Document this as the recommended path; it may make native Drive code unnecessary.
- Commands: `:drive` (open picker), `:drive open <name>`, `:drive sync`.

**Decision to make.**

- Native Drive API (more code, self-contained) vs. lean on `rclone mount` (near-zero code, external dependency). Recommend trying the rclone route first — it likely satisfies the need with a docs page instead of a module.

**Risks / notes.**

- Same crate/threading notes as Google Calendar. Feature-gate behind `google`.
- Editing semantics (download→edit→upload) need conflict/staleness handling; start read-only or single-user-assumption.

---

### External tools: configurability & richer previews (follow-up to fzf/yazi)

**Context.** `:fzf`, `:rg`, `:yazi` are wired with hardcoded commands in `src/external.rs`. Make them configurable and a bit smarter.

**Change.**

- Add a `[tools]` table to `Config`: override the file-list command (default `rg --files`), the previewer (default `bat`), the grep command, and the picker/browser binaries. Lets users swap in `fd`, `eza`, `delta`, etc.
- `:open` / a keybinding to send the *current note's folder* to yazi, not always the vault root.
- WSL image preview: yazi's image preview depends on terminal support (Kitty/Sixel/iTerm protocols). Document what works under WSL; consider a `:preview-image` that shells out to a known-good viewer.
- Let `:fzf` and the native quick switcher be interchangeable via a config flag (`switcher = "native" | "fzf"`), so `Ctrl-O` can route to whichever the user prefers.

**Notes.**

- Keep the suspend/resume + `drain_pending_input` machinery in `src/external.rs` as the single chokepoint for any external program.

---

### Make the help overlay scrollable

**Context.** Help (`Ctrl-/` / `:help`) shows the keybinding glossary in a 32-row centered overlay backed by a plain ratatui `List`. After adding the "Ex commands (vim)" group, the glossary is taller than the viewport and the new section is clipped off-screen. Users can't see `:q`, `:w`, etc.

**Change.**

- In `src/ui/help.rs`, swap the plain `List::new(items)` for a stateful `List` and track a `scroll: usize` on `App` (or `help_scroll` for clarity).
- In `src/dispatch.rs::help_keys`, add `j`/`k` and `Up`/`Down` (plus `PageUp`/`PageDown`, `g`/`G`) to scroll the list.
- Render the current scroll position somewhere unobtrusive ("`12/47`" in the title) so users know there's more below.

**Acceptance.**

- Opening help on an 80×24 terminal can reach the "Ex commands (vim)" group via `j` or `Down`.
- `Esc` / `q` / `Enter` still close.

---

### Index markdown-style links `[text](path.md)` as backlinks  ✅ DONE (see § Done)

**Context.** Today `NoteIndex::ingest` only extracts `[[Wikilinks]]` via `markdown::parse::extract_links`. When importing a real Obsidian vault (`~/OnyxVault`, 678 notes) we saw only 4 links indexed across the whole vault and 16 unresolved — most users write inline markdown links `[label](path.md)` instead. Backlinks, the graph, and the unresolved-links count are all wrong for those vaults.

**Change.**

- In `src/markdown/parse.rs`, add `pub fn extract_md_links(source: &str) -> Vec<MdLink>` that captures `[label](dest)` ranges, with the same code-block/code-span exclusions `extract_links` already uses. Only treat targets that look like a local note (relative path, no scheme, ends in `.md`/`.markdown`/`.mdx` or has no extension and isn't `http://...`/`mailto:...`/`#anchor`).
- In `src/vault/index.rs::ingest`, also call `extract_md_links` and feed the targets through the same `resolve` path as wikilinks. Merge into `meta.outgoing` / `meta.unresolved`.
- URL-decode targets before resolving (Obsidian writes `My%20Note.md`).
- Keep `extract_links` and `extract_md_links` separate — the editor's inline highlighter shouldn't change.

**Acceptance.**

- On `~/OnyxVault`, title-bar link count goes from 4 to a realistic number (hundreds expected).
- Backlinks panel populates for notes that are linked to with the `[label](path.md)` form.
- Existing wikilink tests in `markdown::parse::tests` still pass; add tests covering: simple `[a](b.md)`, percent-encoded targets, links inside code blocks (ignored), `[text](#anchor)` (skipped), `[text](https://...)` (skipped), `[text](path)` with no extension (resolved).
- Graph view edges include both wikilink and markdown-link relations.

**Notes.**

- pulldown-cmark already emits `Tag::Link { dest_url, ... }` events. Using its parser would be cleaner than regex, but then we'd run it once at ingest time per note — fine; it's already what `render_to_text` does. Consider unifying around cmark events for parse instead of two regex paths.
- Decide: do `[label](path.md)` links count as "the same link" as `[[path]]` if both exist in a note? Probably yes — dedup the merged outgoing list.

---

## Done

### Performance: top tier + Barnes-Hut  (2026-06-07)

- **Dirty-flag rendering** — `App::needs_redraw` gates `term.draw`; idle blocks on
  input (idle CPU ~0). Fast poll only while the graph animates.
- **Preview render cache** — `App::preview_cache` keyed by note/revision/width/
  theme; markdown re-parsed only on change. Added `Buffer::revision`.
- **Incremental backlinks** — editing an existing note updates only its own edges
  (O(note)); new notes still do a full recompute. `resolve_targets` helper;
  `remove_note` split into `unindex_note_meta` + backlink cleanup.
- **Passive graph pre-settle** — sidebar graph laid out in one batch, then frozen
  (no startup animation churn); only focused/fullscreen animates.
- **History byte cap** (~4 MiB) + redo-clear fix. **Panic hook** restores the
  terminal on crash.
- **Barnes-Hut repulsion** (`graph_sim.rs`) — quadtree O(n log n), reused arena,
  THETA=0.85; exact O(n²) kept under 96 nodes. ~0.57 ms/frame @678, 1.48 ms @1500.
- **Compact graph** — sidebar pane renders tiny `·` dots so the whole graph fits;
  fullscreen keeps bold degree-scaled dots.
- **Graph render-buffer reuse** — `ui/graph.rs` writes the node field straight
  into `frame.buffer_mut()` (`put_cell` / `draw_line_buf`), eliminating the
  per-frame `Vec<Vec<char>>` + `Vec<Vec<Option<Style>>>` + lines/spans (~130
  allocs/frame → 0; header/legend remain small Paragraphs).
- **File-tree flatten cache** — `App::visible_tree()` caches the flattened,
  visible rows (`Vec<TreeRow>`), rebuilt only when `FileTree::gen` changes (any
  rescan) or a folder is expanded/collapsed (`expanded_gen`). Was re-walked 3×
  per keypress (`draw` + `visible_tree_len` + `selected_node`).
- **Non-blocking search** — `run_search` spawns a worker thread that scans note
  bytes with a `regex::bytes` case-insensitive matcher (no per-line
  `to_lowercase`/`String`) and streams `SearchMsg::Hit/Done` over an `mpsc`
  channel; `drain_search` applies them each loop tick. Epoch + `Arc<AtomicU64>`
  supersede/cancel stale searches. UI no longer freezes on big vaults.
- **Path/tag interning** — `NoteIndex` now interns paths as `Arc<Path>` and tags
  as `Arc<str>` (one shared allocation each; map clones are refcount bumps
  instead of duplicated `PathBuf`/`String` heap copies). `NoteMeta.outgoing:
  Vec<Arc<Path>>`, `tags: Vec<Arc<str>>`; maps keyed by the interned `Arc`s.
  Public methods still return owned `PathBuf`/`String` (boundary clone), so
  callers are unaffected. Cuts index memory and the `PathBuf`-clone churn in
  hot paths (`backlinks_for`, graph build).

### Folders + confirm-delete  (2026-06-07)

- Subfolder notes (`:new Folder/Name`, `Ctrl-N`), `:mkdir` + file-tree `m`, empty
  folders shown in the tree, new note/folder relative to the selected folder.
- Yes/no confirmation before deleting notes/folders (`Focus::Confirm`); folder
  delete is recursive.

### Tag-aware graph + frontmatter tags + markdown-link indexing  (2026-06-06)

Driven by debugging the real `~/OnyxVault` (678 notes), where the graph showed a single node:

- **YAML frontmatter tags** — 677/678 notes tag via frontmatter (`tags:\n  - a`), which Onyx ignored. Added `extract_frontmatter_tags` + `extract_all_tags` (`src/markdown/parse.rs`), handling block-list, inline `[a, b]`, single, and quoted forms. The index and preview footer now use `extract_all_tags`. Tag count went 284 → 378.
- **Markdown-link indexing** — added `extract_md_links` (`[text](note.md)`), URL-decoded, anchor-stripped, web/mailto/non-`.md` skipped, code-fences excluded. Wired into `NoteIndex::ingest` alongside wikilinks; `resolve_internal` now falls back to the last path component so `Sub/Note` / `../Foo/Note` resolve. (NB: this particular vault turned out to link almost entirely via `publish.obsidian.md` URLs, so tags are its real connective tissue — but md-link indexing is correct and helps link-based vaults.)
- **Tag-aware graph** (`src/ui/graph.rs`) — BFS neighbours and edges now combine links *and* shared-tag adjacency (`NoteIndex::shares_tag` / `shared_tag_notes`). Tag-only edges render in the tag colour; link edges stay subtle. The graph went from 1 node to a real neighbourhood (11 for "Presentation").
- Tests: 18 total (added frontmatter + md-link cases).

### live_grep / fzf rendering + config isolation  (2026-06-06)

- **live_grep fixed twice over.** It's now a true Telescope-style live grep: fzf `--disabled` with `start`/`change` reload bindings re-running `rg -t markdown {q}`. Two rendering bugs fixed: (1) dropped `--height` so fzf uses a clean fullscreen alt-screen instead of drawing inline over the suspended terminal; (2) **the real culprit** — `run_capture` used `Command::output()` which pipes stdout and nulls stdin, leaving fzf without a usable terminal (you'd just see the bare shell). Now it inherits the terminal via `Command::status()` and redirects the selection to a temp file (the proven yazi pattern).
- **Pickers scoped to markdown** (`rg -t markdown`), and `open_selection` made bulletproof: text files open in-editor, binaries go to a detached, WSL-aware `open_external` (`Stdio::null()`, `wslview`/`explorer.exe`/`xdg-open`) so it can never corrupt the TUI.
- **Config isolation** — `ONYX_CONFIG` / `ONYX_CONFIG_DIR` env overrides (`src/config.rs`) so throwaway/test sessions never touch `~/.config/onyx/config.toml`.
