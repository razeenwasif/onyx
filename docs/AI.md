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

These Gemma builds emit a short **reasoning trace** before the answer; it's shown
dimmed/italic above the reply.

## Notes

- **First request is slow** — Ollama loads the model into memory (seconds), then
  tokens stream quickly. A bigger model = better answers, slower start; pick what
  fits in `[ai] model` (e.g. an `e2b`/4B for snappy, a 12B for quality).
- **Local only.** Requests go to loopback HTTP; nothing is sent to any cloud.
- **Follow-ups (not built yet):** "ask my vault" (retrieval over all notes),
  inline autocomplete, applying a rewrite back into the note, and a separate fast
  model for completions.
