# Local AI assistant (Ollama) — setup

Onyx can talk to a **local LLM** served by [Ollama](https://ollama.com) — no
cloud, no API keys, your notes never leave the machine. It lives behind the
**`ai`** cargo feature so the default build pulls no HTTP stack.

## 1. Build with the feature

```bash
# AI only:
cargo install --path . --force --features ai
# AI + Google sync (recommended — everything network-backed):
cargo install --path . --force --features full
```

`full = ["cloud", "ai"]`. The plain build (and `--features cloud`) leave the
assistant out; running `:ai` then prints a "rebuild with --features ai" hint.

## 2. Have Ollama running with a model

Ollama serves on `http://localhost:11434` and is usually always running. Pull a
model if you haven't:

```bash
ollama pull gemma3:4b        # or any model; the examples used gemma4:e4b-it-qat
ollama list                  # see what you have
```

## 3. Point Onyx at your model

Defaults live in `~/.config/onyx/config.toml` (created on first run):

```toml
[ai]
model = "gemma4:e4b-it-qat"        # any tag from `ollama list`
host  = "http://localhost:11434"   # change only for a remote Ollama
```

You can also switch at runtime: **`:ai model <name>`** (persists), and
**`:ai models`** lists what's installed.

## 4. Use it

- **`Ctrl-A`** (or **`:ai`**) opens the chat overlay. Type a prompt, **Enter**
  sends, replies **stream in** token-by-token. The **open note is sent as
  context**, so "summarize this", "suggest tags", "rewrite this clearer" all
  work. `PgUp`/`PgDn` scroll, **`Esc`** closes (the conversation is kept).
- **`:ai <prompt>`** opens the overlay and sends `<prompt>` in one step.
- **`:summarize`** summarizes the current note.
- **`:ai clear`** starts a fresh conversation.

### Ask my vault (RAG)

**`:ask <question>`** answers from across your **whole vault** using semantic
search, not just the open note. It chunks every note, embeds the chunks, and
retrieves the most relevant ones to ground the answer — which is streamed into
the AI overlay with a **`— Sources:`** list of the notes it used.

This needs a **dedicated embedding model** (the chat models are generation-only):

```bash
ollama pull nomic-embed-text     # ~274 MB, fast; the default
```

Configure it if you prefer another:

```toml
[ai]
embed_model = "nomic-embed-text"
```

- **First `:ask` indexes the vault** (embeds every note) — this can take a bit on
  a large vault; progress shows in the overlay title (`indexing 120/1071…`). The
  index is cached to `<vault>/.onyx/rag-index.json` (vectors int8-quantized +
  base64-packed to keep it small), so later asks only re-embed notes that changed
  and are near-instant.
- If the answer isn't in your notes, it says so rather than inventing one.

### Rewrite in place

**`:rewrite [instruction]`** rewrites the **paragraph at the cursor** with the AI
and replaces it in the buffer — one undo-able edit (`u` to revert). With no
instruction it does a clarity/grammar cleanup.

- **`:rewrite all [instruction]`** rewrites the **whole note** instead.
- Examples: `:rewrite make this more concise`, `:rewrite fix grammar`,
  `:rewrite all turn this into bullet points`.
- The result is applied when generation finishes (a `rewriting…` status shows
  meanwhile); `u` undoes it if you don't like it.
- **Rewrite a selection:** press **`v`** to start a line-wise Visual selection,
  extend with `j`/`k`, then **`r`** (or **`:rewrite <instruction>`**) to rewrite
  exactly those lines.

These Gemma builds emit a short **reasoning trace** before the answer; it's shown
dimmed/italic above the reply.

The assistant also knows **Onyx's own keybindings** (the full glossary is fed to
it as context), so you can ask things like "what's the shortcut to open the
graph?" or "how do I rewrite a paragraph?" and get the exact keys/commands.

## Notes

- **First request is slow** — Ollama loads the model into memory (seconds), then
  tokens stream quickly. A bigger model = better answers, slower start; pick what
  fits in `[ai] model` (e.g. an `e2b`/4B for snappy, a 12B for quality).
- **Local only.** Requests go to loopback HTTP; nothing is sent to any cloud.
- **Follow-ups (not built yet):** inline autocomplete (ghost text) and a separate
  fast model for completions.
