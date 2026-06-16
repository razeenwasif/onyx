# Onyx

A modern, premium markdown notes TUI — an Obsidian-inspired terminal vault.

## Features

- Interactive **start page** on launch — new note/folder, search, open recent, daily note, and **bookmarked** notes
- **Bookmarks** — pin notes (`:bookmark` or file-tree `b`); pinned notes show `★` and appear on the Home page
- Vault-based markdown notes with live file tree
- Live-rendered preview pane (headings, bold/italic, code blocks, lists, task lists, blockquotes, wikilinks, tags)
- `[[Wikilinks]]` with **inline autocomplete** (type `[[`, fuzzy-pick a note) and `Ctrl-Enter` to follow; `#tag` autocomplete too
- **Aliases** — `aliases:` in frontmatter let a note be linked/found by alternate names
- Clickable **outline** (jump to heading), `t` to **toggle task checkboxes**, and a live **word count**
- **Page properties** — Notion-style typed frontmatter shown as a clean properties block in the preview
- **Database views** — render any folder as a Notion-style table or kanban **board** keyed by frontmatter properties (`:database`/`:board`, or `t` on a folder), with sort and live filter
- **Nested-page navigation** — a breadcrumb trail in the editor and a **Pages** sidebar tab for jumping between a note's parent, child, and sibling pages (`:up` to go to the containing page)
- **Blocks** — styled **callouts** (`> [!note]`/`[!warning]`/`[!tip]`/…), **collapsible** callouts (`[!note]-`, toggled in the preview), side-by-side **columns** (`::: columns … +++ … :::`), and a **`/` slash menu** in the editor to insert any of them
- **Notion import** — `:notion import <folder>` cleans an unzipped Notion "Markdown & CSV" export into the vault (strips id suffixes, links → wikilinks, CSV databases → note folders with frontmatter + `_schema.md`)
- **Editor tabs** (`Ctrl-PgUp/PgDn`, `Ctrl-W`) and a **split view** (`:vsplit`) to read a second note beside the one you're editing
- **Editable properties** — `:props` edits a note's frontmatter inline; database **board** cards move between groups (`H`/`L`) by rewriting their property
- Backlinks (plus **unlinked mentions** — notes that name this one without linking it), outline (click to jump), tag, and **Pages** (parent/child) panels in the right sidebar
- Command palette (`Ctrl-P`) and quick switcher (`Ctrl-O`) with fuzzy matching
- Full-vault content search (`Ctrl-Shift-F`) with **`tag:` / `path:` / `line:N` operators**, and a vault-wide **task rollup** (`:tasks`) of every `- [ ]` checkbox
- Left-column **Quicknote** scratch pad and **Todo** checklist (autosaved to the vault); focus either and press `Ctrl-F` to expand it full-screen, `Esc`/`Ctrl-F` to collapse
- ASCII graph view (`Ctrl-G`) centered on the current note
- Monthly calendar with daily-notes (`Ctrl-K`), plus optional **Google Calendar** events (`·` marks, `v` day agenda, two-way create/delete)
- Optional **Google Drive** browser (`:drive`) — open a Drive text file in the editor (save uploads it straight back, two-way), open a PDF/image in your system viewer, or `u` to upload the open note as a new Drive file; plus **Google Tasks** merged into the Todo pane
- Optional **local AI assistant** (`Ctrl-A` / `:ai`) — a streaming chat over your notes powered by a **local LLM via Ollama** (e.g. Gemma); the open note is sent as context, plus `:summarize`, **`:ask` (semantic RAG over your whole vault, with cited sources)**, **`:rewrite` (AI-rewrite a paragraph/selection/note in place, undoable)**, and **inline autocomplete** (ghost text, Tab to accept). It even knows Onyx's own shortcuts. No cloud, no keys. See `docs/AI.md`
- Vim-style modal editing — normal/insert/**visual** (line-wise select → yank `y` / delete `d` / paste `p` / AI-rewrite `r`), with a `:` ex command line (`:w`, `:e`, `:e!`, `:w!`, …)
- Crash-safe **atomic saves** and an external-change **conflict guard** (prompts before overwriting a note edited elsewhere)
- **Live filesystem sync** — edits from Obsidian/another editor/git refresh the tree, index, and graph; a clean open note reloads automatically
- **Fast startup** — a persistent index cache re-parses only the notes that changed since last launch (~26× faster on a 680-note vault)
- Themes: Onyx Dark · Onyx Light · Dracula · Nord (plus user-defined)
- Persistent config at `~/.config/onyx/config.toml`

## Build

```bash
cargo build --release
```

## Install (run `onyx` from anywhere)

**Recommended — everything enabled (Google sync + local AI):**

```bash
cargo install --path . --force --features full
```

This puts `onyx` on your PATH (`~/.cargo/bin/onyx`). `full = ["cloud", "ai"]`.

Prefer a leaner build? Pick the features you want:

```bash
cargo install --path . --force                    # core only (no network)
cargo install --path . --force --features cloud   # + Google Tasks/Calendar/Drive  (docs/CLOUD_SYNC.md)
cargo install --path . --force --features ai      # + local AI assistant (Ollama)  (docs/AI.md)
cargo install --path . --force --features full    # + both (recommended)
```

> **After pulling or making changes, re-run the same install command** (use
> `--features full` to keep Google sync + AI). `cargo build` only updates
> `target/release/onyx` — it does **not** update the `onyx` command on your PATH,
> so the installed binary stays on the old version until you reinstall.

## Run

```bash
# Installed on PATH — open the last vault (or create ~/OnyxVault on first launch).
onyx

# Open or create a specific vault.
onyx /path/to/vault

# Or run the build directly without installing.
./target/release/onyx
```

Press `Ctrl-/` or `F1` inside Onyx for the full keybinding glossary.
Press `Ctrl-Q` to quit.
