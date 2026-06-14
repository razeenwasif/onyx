# Onyx Backlog

Running list of work to do. Newest items at the top of "Open". Move items to "Done" when shipped (oldest at the bottom).

## Open

### ⭐ EPIC: Notion + Obsidian hybrid (+ migrate the user's Notion) — ✅ COMPLETE (2026-06-14)

**Direction (2026-06-11).** Evolve Onyx from a pure-Obsidian markdown vault into a
**Notion/Obsidian hybrid**, and migrate the user's Notion workspace in. The user
wants all three Notion capabilities: databases+properties, block editing, and
nested-page structure.

**All five phases shipped** (see § Done for each): page properties (1),
database/table + board views (2), nested-structure navigation (3), block editing
— callouts/columns/collapsible toggles/slash menu (4), and a `:notion import`
export importer (5). The user's own Notion workspace was migrated + reorganized
into the vault (below). Nothing in this epic remains open.

**Migration status: ✅ COMPLETE + REORGANIZED (2026-06-13).** 394 notes were
migrated, then relocated out of the temporary `Notion/` staging subtree into the
existing vault structure and `Notion/` was removed (Finance → `07 - Business/
05 - Finance`; Data Science courses → `02 - Data Science`; Cyber Security →
`04 - IT Infrastructure & Networking`; Physics of Quantum Information →
`05 - Physics`; new `11 - Degree Planning/`, `Entertainment/`, `xProjectsx/Work/`).
DB folders kept intact so the Phase 2 database views work on them. Relocation was
collision-safe (one clash kept as `… (Notion).md`); vault `.md` count unchanged at
1071. Spec + per-domain report: `docs/NOTION_MIGRATION.md`; reorg script:
`scripts/reorg_notion.py`. Harness lesson: migration/worker agents must run as
FOREGROUND Agent calls (background agents get auto-denied on every tool).

**Notion → Onyx mapping:**

| Notion | Onyx |
|---|---|
| Page properties (typed fields) | YAML frontmatter properties (generalize beyond `tags:`) |
| Database | A folder whose notes share a property schema |
| Database views (table/board/list) | A pane rendering a folder's notes by their frontmatter |
| Sub-pages | Folders / child notes (already supported) |
| Blocks (callout/toggle/columns) | Markdown extensions |
| Relations/rollups | Wikilinks between entries + computed columns |

**Phased plan:**

1. **Page properties** ✅ DONE (2026-06-11, see § Done) — parse arbitrary YAML
   frontmatter into ordered key→values on `NoteMeta.properties`; cached; rendered
   as a Properties block in the preview.
2. **Database / table + board views** ✅ DONE (2026-06-13, see § Done) —
   `:database <folder>` / `:board` / file-tree `t` shows a folder's notes as a
   table keyed by frontmatter props, or a kanban board grouped by an auto-picked
   select-like property; sort, direction toggle, and live filter.
3. **Nested structure polish** ✅ DONE (2026-06-13, see § Done) — breadcrumb
   trail in the editor title, a "Pages" sidebar tab (parent ↑ / child folders /
   sibling notes, with the current page marked), and `:up` to jump to the
   containing page.
4. **Block editing** ✅ DONE (2026-06-13, see § Done) — styled callouts
   (`> [!note]`/`[!warning]`/…), interactive collapsible callouts (`-`/`+`),
   side-by-side `::: columns` blocks, and a `/` slash-command insert menu.
5. **Notion import** ✅ DONE (2026-06-14, see § Done) — `:notion import <folder>`
   imports an unzipped Notion "Markdown & CSV" export (self-contained, no
   network: the app can't use the MCP, and a static-token API client wouldn't
   share the OAuth stack Google/OneDrive need — so the export route was chosen).

Start at Phase 1; let the user's real Notion structure (once the MCP is live)
refine the property types and view design in Phase 2.

---

### Robustness — file sync & data safety ✅ DONE (see § Done)

The "robustness trio" shipped: atomic saves, external-change conflict guard, and
the live filesystem watcher (live-reload clean buffers, warn on dirty). Remaining
robustness follow-ups, smaller: broaden test coverage to the editor (motions /
undo) and dispatch (ex-commands), which have little today; surface a subtle
indicator (not just a toast) when the open note was deleted on disk.

---

### Startup scalability — persistent index cache ✅ DONE (see § Done)

Shipped: per-note facts cached to `<vault>/.onyx/index-cache.json`, validated by
mtime, only changed notes re-parsed (~26× faster warm rebuild). Remaining stretch
(not yet needed): **lazy background scan** — show the UI immediately and finish a
*cold* index on a background thread (reuse the search-worker pattern: thread +
`mpsc` + drain-on-tick), so even a first-ever open of a 10k-note vault is instant
and fills in. Today the cache makes warm starts instant but a cold/invalidated
index still builds synchronously. Also optional: write the cache on quit so notes
edited in-session don't re-parse on the next launch.

---

### Obsidian feel — unlinked mentions & search operators ✅ DONE (see § Done)

Both shipped: unlinked mentions now render below real backlinks in the Backlinks
pane (`~` glyph), and vault search supports `tag:`/`path:`/`line:N` operators.

---

### Performance pass — ✅ COMPLETE

All planned optimizations shipped (see Done): dirty-flag rendering, preview
render cache, incremental backlinks, history byte cap, panic hook, Barnes-Hut
graph repulsion, graph render-buffer reuse, file-tree flatten cache,
non-blocking search, and path/tag interning. Idle RSS on the 678-note vault is
~8 MB. Possible future micro-opts if ever needed: prune interner entries on
single-note delete (negligible leak today), SIMD literal search via
`grep-searcher`, multi-threaded search across files.

---

### Google Calendar sync into the calendar pane ✅ DONE (see § Done)

Two-way Calendar shipped: events marked in the pane, a day-agenda overlay (`v`),
create/delete. Follow-ups still open: **event editing** (change a time/title) and
**timed** event creation (today's `a` makes an all-day event); turning an event
into a pre-filled note (`:gcal note`) is also unbuilt.

---

### Google Drive access from within Onyx ✅ DONE (see § Done)

Shipped the native Drive API route: `:drive` opens an in-TUI browser, Enter opens
a text file in the editor (save uploads back) or downloads a PDF/binary to temp
and opens it in the system viewer, and `u` uploads the open note as a new file in
the current folder. Follow-ups still open: uploading binary files, Google-native
doc export, and the optional `rclone mount` docs page.

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

### Make the help overlay scrollable ✅ DONE (see § Done)

`help_scroll` on `App` + a windowed renderer in `ui/help.rs` (position shown in
the title as `start–end/total`); `j/k`/arrows, `d/u`/PageUp·Dn, `g/G` scroll.

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

### Local AI assistant via Ollama (streaming chat)  (2026-06-14)

A local LLM assistant behind a new **`ai`** cargo feature (`full = ["cloud","ai"]`),
talking to Ollama on loopback — no cloud, no keys, notes never leave the machine.

- `integrations/ollama.rs`: pure builders/parsers (`chat_body`, `parse_chat_chunk`
  splitting `content` vs the Gemma `thinking` trace, `parse_models`) unit-tested;
  `#[cfg(feature="ai")]` `chat_stream` (NDJSON line stream via blocking reqwest +
  `BufRead`, `AtomicBool` cancel) and `list_models`; non-ai stubs.
- `[ai]` config (`model` default `gemma4:e4b-it-qat`, `host`).
- `Focus::Ai` chat overlay (`ui/ai.rs`, `AiState`/`AiTurn`): streams tokens live
  (worker `ai_worker` → `AiMsg` over mpsc, epoch-tagged, drained on tick;
  `ai_streaming()` joins the fast-poll), thinking shown dimmed, open note sent as
  context. `Ctrl-A`/`:ai` open; `:ai <prompt>`, `:summarize`, `:ai model <n>`,
  `:ai models`, `:ai clear`.
- 82 tests (3 new Ollama parsers). Default + `ai` + `full` clippy-clean.
  **Verified live e2e** via pyte against real Ollama (overlay streams "Paris"
  for a capital-of-France prompt). Setup: `docs/AI.md`.
- Follow-ups: ask-my-vault (RAG/embeddings), inline autocomplete, apply a
  rewrite back into the note, separate fast completion model.

### Obsidian-feel bundle: unlinked mentions · search operators · scrollable help  (2026-06-14)

Three feel items in one pass.

- **Unlinked mentions.** The Backlinks pane now lists notes that mention the open
  note's name/aliases in plain text without linking it (`~` glyph, below real
  backlinks; legend "N backlinks · M unlinked"). Computed on a background worker
  (`unlinked_worker` + `contains_word` whole-word match, epoch/gen cancellation
  like search), cached per note (`UnlinkedState`), refreshed each tick when the
  open note changes (`maybe_refresh_unlinked`/`drain_unlinked`), gated on the
  right sidebar being visible. `index.meta()` added for alias lookup; both real
  backlinks and mentions are openable via `App::backlink_rows`.
- **Search operators.** Vault search parses `tag:foo`, `path:bar`, `line:N`
  (`parse_search_query` → `SearchQuery`). `tag:`/`path:` pre-filter the file set
  via the index (ANDed); free text still line-scans; filters-only queries list
  one hit per matching note. Highlight uses only the free-text part.
- **Scrollable help.** `help_scroll` + windowed `ui/help.rs` (title shows
  `start–end/total`); `j/k`, `d/u`, `g/G`, arrows, PageUp/Dn.
- 79 tests (3 new: operator parsing ×2, `contains_word` boundaries). Default +
  `--features cloud` clippy-clean; verified e2e via pyte (unlinked mention shows
  for a 2-note vault; help scrolls).

### Two-way Google Drive  (2026-06-14)

`:drive` opens an in-TUI Drive browser; open a text file to edit it, save to
upload it back. Reuses the OAuth foundation (scope broadened to add Drive via
`oauth::SCOPES` — re-auth required) and the background-listing pattern.

- `integrations/gdrive.rs` (pure `parse_files` + classification unit-tested;
  cloud list/download/upload): `list_folder` (`q="'<parent>' in parents and
  trashed=false"`, folders-first sort), `download_text` (`alt=media`),
  `upload_text` (`PATCH upload/files/{id}?uploadType=media`) using the new
  `oauth::send_media` helper. `DriveFile::{is_folder,is_text,is_google_doc}`.
- `App` Drive state (`DriveBrowser` breadcrumb stack) + background folder listing
  (`spawn_drive_list`/`drain_drive` on the event-loop tick, faster poll while
  loading). `open_drive_file` downloads into a buffer tagged with `drive_id`/
  `drive_name` (title `⇪ <name>`, no local path); `save_current_inner` routes
  Drive-backed buffers to `save_drive_doc` (upload) instead of the vault.
- Browser overlay (`Focus::Drive`, `ui/drive.rs`): `j`/`k` move, `Enter`
  enter/open, `Backspace`/`-` up, `Esc` close. Command: `:drive`.
- **Binary files (PDF/image/…):** `Enter` on a non-text file downloads it to
  `$TMPDIR/onyx-drive/<name>` (`gdrive::download_file` → `oauth::download_to_file`,
  binary-safe `alt=media`) and opens it in the system viewer via the now-`pub`
  `external::open_external` (detached — no TUI suspend needed). So PDFs open in
  the OS reader for full-screen reading. Under WSL the temp path is translated
  with `wslpath -w` and opened via `wslview` / `cmd /c start` / `explorer.exe`.
- **Upload a vault note** (`u` / `:drive upload`): `gdrive::create_file` does a
  `multipart/related` upload (JSON metadata + media in one POST) of the open
  note into the browsed folder, then re-lists. Pure body builders
  (`file_metadata`/`multipart_body`/`parse_created_id`) are unit-tested.
- 76 tests (PDF classification + multipart-body/created-id builders). Default +
  `--features cloud` clippy-clean; overlay verified e2e via pyte (guards without
  config). Live list/download/upload need the user's (re-)auth.

### Two-way Google Calendar  (2026-06-14)

Surfaces Calendar events in the calendar pane + a day agenda, with create/delete.
Reuses the OAuth foundation (scope broadened to Tasks **+** Calendar via
`oauth::SCOPES` — re-auth required) and the background-sync + write-helper
patterns.

- `integrations/gcal.rs` (pure parse/body builders unit-tested; cloud
  fetch/create/delete): `parse_calendars`/`parse_events` (all-day + timed via
  chrono, skips cancelled), `month_bounds`, `all_day_event_body`, `fetch_month`
  (across all calendars), `create_all_day`, `delete_event`.
- `App` calendar state + background sync (`start_calendar_sync`/`drain_calendar`/
  `maybe_autosync_calendar` on the event-loop tick, faster poll while syncing);
  `has_calendar_event` marks event days with `·` in `ui/calendar.rs`.
- Day agenda overlay (`Focus::Agenda`, `ui/agenda.rs`): `v` opens it from the
  calendar, `a` adds an all-day event (`PromptAction::AddEvent`), `d` deletes.
  `:agenda`, `:calendar sync`. Opt-in auto-pull via `[google] sync_calendar`.
- 72 tests (3 new). Default + `--features cloud` clippy-clean; agenda UI verified
  e2e (guards without config). Live fetch/writes need the user's (re-)auth.

### Google Tasks in the Todo pane (synced)  (2026-06-14)

The left-column Todo pane now merges local todos with open Google tasks (marked
`☁`), one cursor over both: `Space` toggles (local → `todos.md`; Google →
PATCH-complete, drops off the pane), `d` deletes (local/Google), `a`/`e` are
local-only, `s` / `:todo sync` pulls Google tasks **in the background** (worker
thread + `App::drain_gtasks` on the event-loop tick, faster poll while syncing).
Opt-in auto-pull at launch via `[google] sync_tasks = true`. `App::todo_rows`
(`TodoRow`/`TodoSource`) is the merged model; `gtasks_set_completed_index` /
`gtasks_delete_index` are the shared by-index writers (overlay + pane). Local
toggle/persist verified e2e; Google writes need the user's auth.

### Two-way Google Tasks  (2026-06-14)

The Tasks overlay now writes back to Google: `Space` toggles complete (PATCH),
`d` deletes (DELETE), `:gtasks add <title>` creates (POST). Built on a shared
write path in `oauth.rs` (`send_json` for PATCH/POST, `delete`) that Calendar/
Drive will reuse. `gtasks.rs` adds `set_completed`/`create_task`/`delete_task`
+ pure body builders (`status_body`, `new_task_body`, tested); `GTask` now
carries `list_id` (needed for the write URLs). The user wants two-way for every
service, so the write helpers are generic. Live writes need the user's auth
(can't run in sandbox); pure logic unit-tested (69 tests).

### Cloud foundation + Google Tasks (read)  (2026-06-14)

First cloud integration, behind the **`cloud`** cargo feature (default build
pulls no network/TLS stack). Setup guide: `docs/CLOUD_SYNC.md`.

- **Architecture**: `src/integrations/` is always compiled (pure OAuth/URL/JSON
  logic via serde + std), with the actual `reqwest` calls `#[cfg(feature="cloud")]`
  and non-cloud stubs that error helpfully — so `app`/`dispatch` need no `cfg`.
  `reqwest` (blocking + rustls-tls) is an optional dep enabled by the feature.
- **OAuth** (`integrations/oauth.rs`): Google installed-app loopback flow —
  `consent_url`, a localhost `TcpListener` catches the redirect
  (`parse_redirect_query`), `exchange_code`/`refresh`, `valid_access_token`
  (auto-refresh), token cache `~/.config/onyx/google.json` (mode 600). The
  interactive consent runs via `PendingExternal::GoogleAuth` (TUI suspended,
  `external::run_google_auth`). `[google]` config table (client_id/secret).
- **Google Tasks** (`integrations/gtasks.rs`): list tasklists + tasks, parse to a
  flat model. `:google auth` / `:google tasks` (`:gtasks`) → `Focus::GoogleTasks`
  overlay (`ui/gtasks.rs`); Enter pulls a task into the quicknote.
- 68 tests (7 new: OAuth URL/redirect/token roundtrip, Tasks JSON parsing).
  Default + `--features cloud` both clippy-clean. The pure logic is unit-tested;
  the live OAuth/fetch requires the user's Google creds + browser (can't run in
  CI/sandbox). **Next**: two-way task toggle, then Calendar, Drive, OneDrive.

### Inline property editing + split view  (2026-06-14)

- **Inline property editing** (`:props`) — a modal over the open note that lists
  its frontmatter properties; `e` edits a value, `a` adds (`key: value`), `d`
  deletes, with inline text fields. Edits go through the *buffer*
  (`App::set_open_doc_property` via `markdown::parse::set_frontmatter_property`),
  so they join the note's undo history and save normally (no disk/buffer races).
  `Focus::Properties`, `PropsEditState`, `ui/props.rs`.
- **Split view** (`:vsplit [note]`) — the right pane renders a *second* open note
  read-only alongside the editor (instead of the active note's preview);
  `:swap` swaps which note is active/editable, `:only` closes the split.
  `App::split_doc` + `split_content`/`toggle_split`/`swap_split`, `ui/splitview.rs`.

### Editor tabs (multiple open notes)  (2026-06-14)

Open several notes at once with a tab bar above the editor. Design keeps
`App.doc` as the *active* document (so every existing `app.doc` accessor is
unchanged) and stashes the other open docs in `App.tabs` with an ordered
`App.tab_paths`; each tab preserves its own buffer/cursor/scroll/dirty state.
`open_note` stashes/re-activates; `cycle_tab` (Ctrl-PgUp/PgDn, `:tabn`/`:tabp`),
`close_current_tab` (Ctrl-W / `:bd`, `:bd!` to discard unsaved), `tab_infos` for
the bar (`ui/tabline.rs`, shown when ≥2 open, dirty •). Delete/rename/vault-switch
keep the tab set consistent. Verified end-to-end.

### Editable kanban (board view)  (2026-06-14)

In the database board view, `H`/`L` move the selected card to the previous/next
group, rewriting that note's group-by frontmatter property to the new group's
value (the synthetic "—" group clears it). `markdown::parse::set_frontmatter_property`
(in-place set / append / remove, creates a block when absent, YAML-quotes as
needed) + `App::set_note_property` (write + reindex + reload-if-open) +
`App::board_move_card` (relocates the selection to follow the card). Tested + pyte.

### Bookmarks / pinned notes  (2026-06-14)

Pin notes for quick access. `:bookmark`/`:pin` (current note) or file-tree `b`
(selected note) toggles a pin; pinned notes show a `★` in the file tree and a
**Bookmarks** section atop the Home page. Persisted to `.onyx/bookmarks.json`
(`App::bookmarks`, `Vault::bookmarks_path`, `HomeAction::OpenBookmark`).

### Vault task rollup (`:tasks`)  (2026-06-14)

`:tasks` scans every note for `- [ ]`/`- [x]` checkboxes and shows them in a
centered overlay (open first, then done), each with its `note:line`; Enter jumps
to the task. `markdown::parse::task_line` parses a checkbox line; `App::open_tasks`
+ `TasksState` + `ui/tasks.rs` + `Focus::Tasks`. Synchronous scan (capped at
5000); skips fenced code. (Future: background the scan; toggle from the rollup.)

### Safe rename — rewrite backlinks  (2026-06-14)

Renaming a note (`:rename <new>` or file-tree `r`) now rewrites every link that
pointed at it across the vault, so backlinks never dangle.
`markdown::parse::rename_link_targets` rewrites `[[old]]`, `[[folder/old]]`,
`[[old|alias]]`, `[[old#heading]]`, and `[text](folder/old.md)` (basename match,
case-insensitive, web links untouched). `Vault::rename_with_backlinks` renames
the file then atomically rewrites each affected note, returning the relink count
(shown in the status). Replaced the old link-blind `rename_note`. Tested + pyte.

### Editing polish: aliases, outline jump, #tag autocomplete, task toggle, word count  (2026-06-14)

A bundle of Obsidian-staple quality-of-life features.

- **Aliases** — `aliases:` frontmatter is indexed as extra basenames, so
  `[[Alt Name]]`, the quick switcher, and `[[`-autocomplete all resolve a note
  by its alternate names (`markdown::parse::extract_frontmatter_aliases`,
  `NoteMeta.aliases`, `CacheEntry.aliases`, cache version 2→3). Excluded from
  the Properties block.
- **Clickable outline** — the Outline sidebar tab now jumps the editor to the
  selected heading on Enter (`App::outline_headings` is the shared source of
  truth; `App::jump_to_heading`).
- **`#tag` autocomplete** — typing `#word` in insert mode opens a fuzzy popup
  over existing vault tags (`App::tag_complete`, mirrors the `[[` / `/` popups).
- **Task toggle** — `t` in normal mode (or `:task`) flips a `- [ ]` ↔ `- [x]`
  checkbox on the current line (`markdown::parse::toggle_task_marker`,
  `Buffer::replace_line`).
- **Word count** in the status bar.
- 58 tests; verified end-to-end via pyte.

### Notion hybrid — Phase 5: `:notion import` export importer  (2026-06-14)

A self-contained importer for a Notion "Export → Markdown & CSV" dump (unzipped).
Chosen over a live API client because Onyx can't reach the MCP and Notion's
static-token auth wouldn't share the OAuth stack Google/OneDrive will need — so
no network deps were added.

- New `src/notion_import.rs` (pure helpers + a 2-pass driver, 5 tests):
  `clean_component` (strips ` <32-hex>` Notion ids, keeping extensions),
  `parse_csv` (RFC-4180), `rewrite_links` (internal `.md` → `[[wikilink]]`,
  attachments → cleaned relative path, web links untouched, percent-decoded,
  anchors dropped), `csv_row_frontmatter` (CSV columns → YAML, multi-value →
  inline list, title column skipped). `import_export` walks the export:
  pass 1 turns each CSV into a `_schema.md` + a row→frontmatter map; pass 2
  rewrites/links each `.md`, injects the matching row's frontmatter, and copies
  attachments — all create-only (collisions kept as ` (Notion)`), nothing
  outside the destination touched.
- `App::import_notion` writes under `<vault>/Notion Import/`, refreshes the
  index/graph, and reports counts; `:notion import <folder>` (dispatch, `~`
  expanded; a `.zip` path gets an "unzip first" hint). Glossary entry added.
- Verified end-to-end: a synthetic export → cleaned names, `[[Claude]]`
  wikilink, injected `Type`/`Amount`/`Tags` frontmatter, `_schema.md`, copied
  attachment.

### Notion hybrid — Phase 4: block editing (callouts, columns, fold, slash menu)  (2026-06-13)

Notion-style block extensions on top of CommonMark, plus a slash-command inserter.

- **Callouts**: `> [!note] Title` / `[!warning]` / `[!tip]` / `[!danger]` / … render
  as a styled block (type icon + colored bar). Detected by a line-level pre-pass
  (`markdown::render::split_blocks`) so cmark's inline tokenization can't break
  them; the body is rendered as markdown and barred. Editor inline-highlights the
  `[!type]` marker. `markdown::parse::parse_callout_header` is the shared parser.
- **Collapsible toggles**: `[!note]-` (start collapsed) / `[!note]+`. The preview
  is now navigable — `j`/`k` move a fold cursor among foldable callouts, `Space`/
  `Enter` collapse/expand. State on `App::{preview_collapsed, preview_fold_sel}`,
  seeded from the markers on open; `render_to_text_with(collapsed, selected)`
  hides collapsed bodies and shows `▸`/`▾`; the preview cache key includes a fold
  signature so toggles re-render.
- **Columns**: `::: columns` … `+++` … `:::` renders each column at a sub-width
  and stitches them side-by-side with a separator (`stitch_columns`/`fit_line`).
- **Slash menu**: `/` at a word boundary in insert mode opens a fuzzy block
  picker (`App::slash_complete`, mirrors the `[[` popup) — callouts, columns,
  code block, table, to-do, lists, headings, divider, today's date. Accepting
  inserts the snippet and places the caret inside it.
- 50 tests (callout parse + render, collapse, columns); verified end-to-end via
  pyte. Help glossary + status hints updated.

### Resizable editor | preview split  (2026-06-13)

The center editor/preview divider was a hardcoded 55/45. Now it's adjustable
and persisted.

- `LayoutConfig.editor_split_percent` (default 55); `ui::mod::draw_body` uses it
  (clamped 20–80) instead of the fixed percentages.
- `App::resize_editor_split(delta)` nudges it ±, clamps, persists, and reports
  the ratio in the status bar. Bound to **Ctrl-←/→** in `global_shortcut`
  (works from any non-overlay focus, intercepted before the editor sees the
  arrows). Also `:set editor-width=<20-80>`.
- Glossary entries added (help overlay + palette).

### Notion hybrid — Phase 3: nested-structure navigation  (2026-06-13)

Treat the folder hierarchy as a Notion page tree (a folder's "page" = its
namesake note `Foo/Foo.md`, else `_schema.md`, else its first note).

- New `src/page_nav.rs` (pure, 7 unit tests): `representative_note`,
  `parent_page`, `page_entries` (Up / child-folder / sibling-note rows, current
  marked), and `breadcrumb`/`join_breadcrumb` (trailing-segments-kept, leading
  `…` elision to fit width). `FileTree::node_at(path)` added to walk to a node.
- **Breadcrumbs**: the editor pane title shows the note's trail, e.g.
  `… › Anime Watchlist - Tracker › Animes › Oshi no Ko`, width-fitted
  (`editor_pane::draw`).
- **Pages sidebar tab** (`SidebarTab::Pages`, now first in the tab cycle):
  lists ↑ parent, child folders (drill in), and sibling notes; Enter opens.
  Rendered by `sidebar::draw_pages`, handled in `dispatch::sidebar_open_selected`.
- **`:up` / `:parent`** ex-command jumps to the containing page.
- Verified end-to-end (pyte): breadcrumb on a deep note, the Pages tab on a
  parent page (↑ + 5 child DB folders + current ●), and Enter drilling into a
  child (breadcrumb follows).

### Notion hybrid — Phase 2: database / table + board views  (2026-06-13)

A folder rendered as a Notion-style database: each direct-child note is a row,
its frontmatter properties are columns.

- New `src/db_view.rs`: `DatabaseView` (folder + computed columns/rows + UI
  state) and pure logic — `build_rows` (columns ordered by frequency, housekeeping
  keys `source`/`notion-url` pushed right), `pick_group_by` (auto-select a
  select-like board column), `visible_indices` (filter + numeric/lexical sort,
  empties last), `groups`, and clamped no-wrap navigation. 8 unit tests.
- New `src/ui/database.rs`: table renderer (frequency-ordered columns, sort
  arrows, selected-row highlight, horizontal column scroll) and board renderer
  (windowed group columns, per-group card lists). Modal, fills the body.
- `App::{open_database, build_database, rebuild_database, close_database}` +
  `Focus::Database`; rebuilt on external change, cleared on vault switch.
- `dispatch::database_keys` (j/k, h/l, g/G, s/S sort, [/] group-by, t/Tab mode,
  `/` live filter, Enter open) + ex-commands `:database`/`:db`/`:table`/`:board`
  + file-tree `t`. `global_shortcut` swallows stray ctrl keys while it's open.
- Verified end-to-end (pyte): table/board/sort/filter/open on the migrated
  Expenses DB (auto-grouped Needs/Wants/Savings) and on relocated folders.

### Notion hybrid — Phase 1: page properties  (2026-06-11)

First step of the Notion/Obsidian hybrid epic: surface arbitrary YAML frontmatter
as Notion-style page properties.

- `markdown::parse::extract_frontmatter_properties` → ordered `(key, values)`
  (scalars single-element, `[a,b]`/block-lists multi, scalars not comma-split,
  quotes stripped, top-level keys only) + `strip_frontmatter`. Tests added.
- `NoteMeta.properties: Vec<(String, Vec<String>)>` (tags/tag excluded — those
  are handled as tags); threaded through `ParsedNote` + `ingest_parsed`; cached
  in `CacheEntry` (cache version bumped 1→2).
- `ui/preview.rs::build_preview_text` renders a **Properties** block at the top
  of the preview and strips the raw frontmatter from the body. Notes without
  frontmatter render exactly as before.
- 30 tests; verified in a pyte harness (Status/Priority/Due shown as properties).

### `[[wikilink]]` autocomplete  (2026-06-09)

The headline Obsidian interaction: typing `[[` in the editor pops a fuzzy
note-name picker that inserts a wikilink.

- `App::link_complete: Option<LinkComplete>` + `refresh_link_complete`
  (scans the line prefix for an open `[[`, rejects `[`/`]` after it),
  `compute_link_matches` (SkimMatcherV2 over note basenames; empty query →
  recent notes), `link_complete_move` / `accept_link_complete` (deletes the
  typed query, inserts `Name]]`) / `cancel_link_complete`.
- `dispatch::editor_insert` intercepts Up/Down/Tab/Enter when the popup is open
  and refreshes it after every edit; `Esc` is handled in `global_shortcut`
  (dismiss popup, stay in insert; second Esc leaves insert). `App::escape`
  clears the popup defensively.
- `editor_pane::draw_link_popup` renders the list anchored under the `[[`
  (flips above the caret when there's no room below).
- Verified end-to-end with a pyte terminal harness (popup shows + filters,
  Enter inserts `[[Meeting Notes]]`, Esc dismisses but stays in insert).

### Home start page  (2026-06-09)

Onyx used to auto-open whatever note was most recent on launch. Now it opens on
an interactive **Home** start page in the center pane.

- New `Focus::Home` + `home_selected`; `App::home_items()` builds the rows
  (New note · New folder · Search vault · Open note… · Today's daily note, then
  up to 8 recent notes) — one source of truth for both the renderer and the key
  handler. `App::activate_home` delegates to existing flows; `App::center_focus`
  returns Editor-or-Home so panes stop hard-coding "focus the editor".
- `src/ui/home.rs` renders the menu (selection highlight when focused); the
  compositor routes the center to it whenever `doc.is_none()`. Removed the old
  static `editor_pane::draw_empty` splash it replaces.
- `dispatch::home_keys` (j/k/g/G move, Enter/l/Space activate, Tab cycles);
  New note/folder open a prompt. `main` no longer auto-opens a note; deleting the
  open note falls back to Home. Status-bar hint added.

### Persistent index cache (fast startup)  (2026-06-09)

Every launch used to read + regex-parse all ~680 notes. Now the index's
content-derived facts are cached and reused for notes whose mtime is unchanged.

- Refactored `NoteIndex::ingest` into `ParsedNote::from_content` (pure extraction)
  + `ingest_parsed` (insertion), so the insert path is fed identically from a
  fresh parse or a cache hit.
- New `src/vault/index_cache.rs`: `IndexCache` (version + relpath→`CacheEntry`
  map of title/targets/tags/size/word_count/mtime), `load` (version-checked,
  empty on any failure), per-note `fresh()` mtime check, `write`.
- `NoteIndex::build_with_cache` stats each note and reuses the cached
  `ParsedNote` on an mtime match, else reads + parses; `export_cache` snapshots
  the index back out. `vault::build_index` centralizes load→build→save and backs
  both `Vault::open` and `refresh`.
- Cache lives in `<vault>/.onyx/index-cache.json` — travels with the vault,
  excluded from the scanner, ignored by the watcher (no self-reindex), and
  isolated in tests. Pure optimization: stale/corrupt → re-parse, never wrong.
- Measured **~26× faster** warm rebuild on the 678-note vault (109 ms → 4 ms).
- Added `serde_json`. Tests: 27 total (cache round-trip vs full build; stale
  entry re-parsed) + a self-skipping `bench_cache` (`ONYX_BENCH_VAULT=…`).

### Robustness trio: atomic saves + conflict guard + file watcher  (2026-06-08)

Made Onyx trustworthy with a real, externally-edited vault.

- **Atomic saves** — `vault::atomic_write` writes a hidden `.<name>.<pid>.<n>.onyxtmp`
  sibling, flushes + fsyncs, then `rename`s over the target. `write_note` routes
  through it, so a crash mid-write can never truncate a note. Temp files are
  dot-prefixed (ignored by the scanner) and cleaned up on error. Added
  `vault::file_mtime`.
- **External-change conflict guard** — `Document.disk_mtime` records the on-disk
  mtime at open/save. `save_current_inner(force)` compares it before writing; if
  the file changed underneath us it opens a `ConfirmAction::OverwriteNote` dialog
  instead of clobbering. `:w!` / `:wq!` / confirming → `force_save_current`.
- **Filesystem watcher** — wired the previously-dead `VaultWatcher` (now reports
  changed *paths*) into `App`/event loop. `handle_fs_events` filters dot-paths
  (`.git`/`.obsidian`/`.onyx`/`.onyxtmp`) and Onyx's own writes (`recent_self_writes`,
  5 s TTL) so saves don't self-trigger a reindex; real external changes refresh
  the tree/index/graph. `reconcile_open_doc` live-reloads a clean buffer
  seamlessly and warns (keeping edits) on a dirty one. Idle poll capped at 1 s
  while a watcher is active so changes are caught promptly with ~0 idle CPU.
- **Ex-commands** — added `:e!` (reload from disk), `:w!`/`:wq!`/`:x!` (force-save).
- Tests: 24 total (added atomic-write content/overwrite/no-temp + file_mtime).
  Verified end-to-end via the pty harness (live reload, dirty-warn, conflict
  dialog, force-overwrite preserving the user's edit).

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
