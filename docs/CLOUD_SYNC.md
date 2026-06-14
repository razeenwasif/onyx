# Cloud sync (Google) — setup

Onyx's cloud integrations live behind the **`cloud`** cargo feature so the
default build pulls no network/TLS stack. Currently shipped: **Google Tasks**
(read into Onyx). Google Calendar, Drive, and OneDrive are planned and will
reuse the same OAuth foundation. **Google Keep is not supported** — it has no
official API for personal accounts (see the note at the bottom).

## 1. Build with the feature

```bash
cargo install --path . --force --features cloud
```

> The plain `cargo install --path . --force` (used after normal updates) builds
> *without* cloud. Add `--features cloud` whenever you want the Google features.

## 2. Create Google OAuth credentials (one-time)

Onyx talks to Google with *your* OAuth client — Onyx ships none.

1. Go to <https://console.cloud.google.com/> and create (or pick) a project.
2. **APIs & Services → Enabled APIs → Enable APIs** → enable **Google Tasks API**.
3. **APIs & Services → OAuth consent screen** → configure (External is fine for a
   personal `@gmail.com`; add yourself as a Test user).
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID** →
   application type **Desktop app**. Copy the **Client ID** and **Client secret**.

## 3. Put the credentials in config

Edit `~/.config/onyx/config.toml`:

```toml
[google]
client_id = "xxxxxxxx.apps.googleusercontent.com"
client_secret = "xxxxxxxxxxxxxxxxxxxx"
```

## 4. Authorize and use

- `:google auth` — Onyx opens your browser to Google's consent screen, catches
  the redirect on a localhost loopback port, and saves the token to
  `~/.config/onyx/google.json` (mode 600). The refresh token is reused, so you
  only do this once.
- `:google tasks` (or `:gtasks`) — fetches your task lists and shows every task
  in an overlay (open first, then completed) with its due date and list.
  - `j`/`k` move, `Esc` close.
  - **`Space`** toggles a task complete/incomplete — **writes back to Google**.
  - **`d`** deletes the task on Google.
  - `Enter` pulls the task into the quicknote scratch as a `- [ ]` line.
- `:gtasks add <title>` — create a task in your default Google list.

### In the Todo pane

Your open Google tasks also show up in the left-column **Todo pane**, merged with
your local checklist and marked `☁`. One cursor spans both:

- `Space` toggles — a local todo flips in `.onyx/todos.md`; a `☁` task is
  **completed on Google** (and drops off the pane).
- `d` deletes (local → file; `☁` → deleted on Google).
- `a` adds a *local* todo; `e` edits a local one (use `:gtasks` for Google).
- **`s`** (or `:todo sync`) pulls fresh Google tasks **in the background** (no lag).

To pull them automatically every launch, opt in:

```toml
[google]
sync_tasks = true
```

## Google Calendar

> **Enable it first:** in your Google Cloud project, **enable the Google
> Calendar API**, then **re-run `:google auth`** — Onyx now requests the Calendar
> scope too, so the old (Tasks-only) token must be refreshed with the broader
> consent.

- Days with events get a `·` mark in the calendar pane (bottom-right).
- In the calendar pane: **`v`** opens the **day agenda** for the selected day,
  **`g`** re-syncs the visible month.
- In the agenda overlay: `j`/`k` move, **`a`** adds an all-day event on that day
  (writes to your primary calendar), **`d`** deletes the selected event, `Esc`
  closes.
- `:agenda` opens the agenda directly; `:calendar sync` re-pulls the month.
- Auto-pull the visible month every launch / on month-change:

```toml
[google]
sync_calendar = true
```

## Notes

- **Two-way.** Toggling/deleting/adding tasks and adding/deleting events write
  straight to Google. Re-sync (`s` / `g` / `:todo sync` / `:calendar sync`) to
  reflect changes made elsewhere.
- **Event editing** (changing a time/title) and **timed** event creation are
  follow-ups; today's create makes an all-day event.
- **Token storage.** Only `~/.config/onyx/google.json` holds secrets (mode 600);
  `config.toml` holds just the client id/secret you pasted.
- **Google Keep.** Intentionally unsupported: Google provides no Keep API for
  personal Gmail accounts (the Keep API is Workspace/enterprise-only via a
  service account). A `:keep import` from a Google Takeout export — like the
  Notion importer — is the realistic offline route if it's ever wanted.
