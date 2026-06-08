# Onyx

A modern, premium markdown notes TUI — an Obsidian-inspired terminal vault.

## Features

- Vault-based markdown notes with live file tree
- Live-rendered preview pane (headings, bold/italic, code blocks, lists, task lists, blockquotes, wikilinks, tags)
- `[[Wikilinks]]` with autocompletion-aware resolution and `Ctrl-Enter` to follow
- Backlinks panel, outline panel, and tag panel in the right sidebar
- Command palette (`Ctrl-P`) and quick switcher (`Ctrl-O`) with fuzzy matching
- Full-vault content search (`Ctrl-Shift-F`)
- ASCII graph view (`Ctrl-G`) centered on the current note
- Monthly calendar with daily-notes (`Ctrl-K`)
- Vim-style modal editing in the editor pane, with a `:` ex command line (`:w`, `:e`, `:e!`, `:w!`, …)
- Crash-safe **atomic saves** and an external-change **conflict guard** (prompts before overwriting a note edited elsewhere)
- **Live filesystem sync** — edits from Obsidian/another editor/git refresh the tree, index, and graph; a clean open note reloads automatically
- **Fast startup** — a persistent index cache re-parses only the notes that changed since last launch (~26× faster on a 680-note vault)
- Themes: Onyx Dark · Onyx Light · Dracula · Nord (plus user-defined)
- Persistent config at `~/.config/onyx/config.toml`

## Build

```bash
cargo build --release
```

## Run

```bash
# Open the last vault (or create ~/OnyxVault on first launch).
./target/release/onyx

# Open or create a specific vault.
./target/release/onyx /path/to/vault
```

Press `Ctrl-/` or `F1` inside Onyx for the full keybinding glossary.
Press `Ctrl-Q` to quit.
