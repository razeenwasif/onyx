/** Settings modal — Obsidian's left-nav + sections layout. */

import { useEffect, useState } from 'react'
import { useStore } from '../store'
import type { GoogleStatus } from '@shared/types'
import { THEMES } from '../themes'

const SECTIONS = [
  'Editor',
  'Appearance',
  'Files & links',
  'Daily notes',
  'Graph',
  'Google',
  'AI',
  'About',
] as const
type Section = (typeof SECTIONS)[number]

export function Settings(): JSX.Element {
  const [section, setSection] = useState<Section>('Editor')
  const settings = useStore((s) => s.settings)
  const set = useStore((s) => s.setSettings)
  const vault = useStore((s) => s.vault)
  const [models, setModels] = useState<string[]>([])
  const [modelError, setModelError] = useState<string | null>(null)

  useEffect(() => {
    if (section !== 'AI') return
    void window.onyx.ai
      .models()
      .then((m) => {
        setModels(m)
        setModelError(null)
      })
      .catch((e: Error) => setModelError(e.message))
  }, [section])

  if (!settings) return <div className="modal" />

  return (
    <div className="modal wide" onMouseDown={(e) => e.stopPropagation()}>
      <div className="settings-modal">
        <div className="settings-nav">
          {SECTIONS.map((s) => (
            <button key={s} className={section === s ? 'is-active' : ''} onClick={() => setSection(s)}>
              {s}
            </button>
          ))}
        </div>
        <div className="settings-body">
          <h2 className="settings-title">{section}</h2>

          {section === 'Editor' && (
            <>
              <Setting name="Default editing mode" desc="How notes open by default.">
                <select
                  value={settings.defaultEditorMode}
                  onChange={(e) => void set({ defaultEditorMode: e.target.value as never })}
                >
                  <option value="livePreview">Live preview</option>
                  <option value="source">Source</option>
                  <option value="reading">Reading</option>
                </select>
              </Setting>
              <Toggle
                name="Vim key bindings"
                desc="Modal editing, like the Onyx TUI."
                on={settings.vimMode}
                onChange={(v) => void set({ vimMode: v })}
              />
              <Toggle
                name="Show line numbers"
                on={settings.lineNumbers}
                onChange={(v) => void set({ lineNumbers: v })}
              />
              <Toggle
                name="Readable line length"
                desc="Constrain the note body to a comfortable measure."
                on={settings.readableLineLength}
                onChange={(v) => void set({ readableLineLength: v })}
              />
              <Toggle
                name="Autosave"
                desc="Write the file after a pause in typing."
                on={settings.autosave}
                onChange={(v) => void set({ autosave: v })}
              />
              <Setting name="Autosave delay" desc="Milliseconds of quiet before saving.">
                <input
                  type="number"
                  min={250}
                  step={250}
                  value={settings.autosaveIdleMs}
                  onChange={(e) => void set({ autosaveIdleMs: Number(e.target.value) })}
                />
              </Setting>
              <Setting name="Tab size">
                <input
                  type="number"
                  min={1}
                  max={8}
                  value={settings.tabSize}
                  onChange={(e) => void set({ tabSize: Number(e.target.value) })}
                />
              </Setting>
              <Toggle
                name="Indent with spaces"
                on={settings.useSpaces}
                onChange={(v) => void set({ useSpaces: v })}
              />
            </>
          )}

          {section === 'Appearance' && (
            <>
              <Setting name="Theme">
                <select value={settings.theme} onChange={(e) => void set({ theme: e.target.value })}>
                  {THEMES.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.name}
                    </option>
                  ))}
                </select>
              </Setting>
              <Setting name="Font size" desc="Editor and reading view, in pixels.">
                <input
                  type="number"
                  min={11}
                  max={28}
                  value={settings.fontSize}
                  onChange={(e) => void set({ fontSize: Number(e.target.value) })}
                />
              </Setting>
              <Toggle
                name="Show frontmatter as properties"
                on={settings.showFrontmatter}
                onChange={(v) => void set({ showFrontmatter: v })}
              />
            </>
          )}

          {section === 'Files & links' && (
            <>
              <Setting name="Vault location">
                <span style={{ color: 'var(--fg-subtle)' }}>{vault?.root}</span>
              </Setting>
              <Setting name="Attachment folder" desc="Where pasted images are stored.">
                <input
                  type="text"
                  value={settings.attachmentFolder}
                  onChange={(e) => void set({ attachmentFolder: e.target.value })}
                />
              </Setting>
              <Setting name="Open another vault">
                <button
                  className="btn"
                  onClick={async () => {
                    const picked = await window.onyx.vault.pick()
                    if (picked) window.location.reload()
                  }}
                >
                  Browse…
                </button>
              </Setting>
            </>
          )}

          {section === 'Daily notes' && (
            <>
              <Setting name="New file location">
                <input
                  type="text"
                  value={settings.dailyNotes.folder}
                  onChange={(e) =>
                    void set({ dailyNotes: { ...settings.dailyNotes, folder: e.target.value } })
                  }
                />
              </Setting>
              <Setting name="Date format" desc="Moment-style tokens, e.g. YYYY-MM-DD.">
                <input
                  type="text"
                  value={settings.dailyNotes.format}
                  onChange={(e) =>
                    void set({ dailyNotes: { ...settings.dailyNotes, format: e.target.value } })
                  }
                />
              </Setting>
            </>
          )}

          {section === 'Graph' && (
            <p style={{ color: 'var(--fg-dim)', lineHeight: 1.6 }}>
              Graph settings live in the graph view itself — open it (Ctrl+G) and use the
              Filters / Groups / Display / Forces panel. Changes are saved per view, and
              "Restore default settings" resets them.
            </p>
          )}

          {section === 'Google' && <GoogleSection />}

          {section === 'AI' && (
            <>
              <Setting name="Ollama host" desc="Local LLM server. No cloud, no keys.">
                <input
                  type="text"
                  value={settings.ai.host}
                  onChange={(e) => void set({ ai: { ...settings.ai, host: e.target.value } })}
                />
              </Setting>
              <Setting name="Chat model">
                <ModelSelect
                  value={settings.ai.model}
                  models={models}
                  onChange={(v) => void set({ ai: { ...settings.ai, model: v } })}
                />
              </Setting>
              <Setting name="Embedding model" desc="Used by “ask my vault” (RAG).">
                <ModelSelect
                  value={settings.ai.embedModel}
                  models={models}
                  onChange={(v) => void set({ ai: { ...settings.ai, embedModel: v } })}
                />
              </Setting>
              <Setting name="Completion model" desc="Fast model for inline ghost text.">
                <ModelSelect
                  value={settings.ai.completionModel}
                  models={models}
                  onChange={(v) => void set({ ai: { ...settings.ai, completionModel: v } })}
                />
              </Setting>
              <Toggle
                name="Inline autocomplete"
                desc="Suggest a continuation after a typing pause; Tab accepts."
                on={settings.ai.autocomplete}
                onChange={(v) => void set({ ai: { ...settings.ai, autocomplete: v } })}
              />
              {modelError && (
                <div className="empty-note" style={{ color: 'var(--warning)' }}>
                  {modelError}
                </div>
              )}
            </>
          )}

          {section === 'About' && (
            <p style={{ color: 'var(--fg-dim)', lineHeight: 1.7 }}>
              <strong>Onyx Desktop</strong> — an Obsidian-style app over the same plain-markdown
              vault the Onyx TUI uses. Notes stay ordinary <code>.md</code> files on disk; nothing is
              stored in a proprietary format, and the two apps can be used on the same vault at the
              same time.
            </p>
          )}
        </div>
      </div>
    </div>
  )
}

/**
 * Google Calendar + Tasks. Credentials and the token are shared with the TUI:
 * an empty client id here means "use `[google]` from config.toml", and the
 * token lands in the same `google.json`, so authorizing once covers both.
 */
function GoogleSection(): JSX.Element {
  const settings = useStore((s) => s.settings)!
  const set = useStore((s) => s.setSettings)
  const setStatus = useStore((s) => s.setStatus)
  const [status, setStatusState] = useState<GoogleStatus | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refresh = async (): Promise<void> => {
    try {
      setStatusState(await window.onyx.google.status())
    } catch (e) {
      setError((e as Error).message)
    }
  }

  useEffect(() => {
    void refresh()
  }, [])

  const connect = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    try {
      setStatusState(await window.onyx.google.connect())
      setStatus('Connected to Google')
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const disconnect = async (): Promise<void> => {
    await window.onyx.google.disconnect()
    await refresh()
    setStatus('Signed out of Google')
  }

  const sourceLabel =
    status?.source === 'config.toml'
      ? 'from the TUI’s config.toml'
      : status?.source === 'desktop'
        ? 'set here'
        : 'not configured'

  return (
    <>
      <Setting
        name="Account"
        desc={
          status?.connected
            ? `Connected · OAuth client ${sourceLabel}`
            : `Not connected · OAuth client ${sourceLabel}`
        }
      >
        {busy ? (
          <span className="spinner" />
        ) : status?.connected ? (
          <button className="btn" onClick={() => void disconnect()}>
            Sign out
          </button>
        ) : (
          <button className="btn primary" onClick={() => void connect()}>
            Connect…
          </button>
        )}
      </Setting>

      <Toggle
        name="Sync Google Calendar"
        desc="Show events in the calendar pane, and allow creating and deleting them."
        on={settings.google.syncCalendar}
        onChange={(v) => void set({ google: { ...settings.google, syncCalendar: v } })}
      />
      <Toggle
        name="Sync Google Tasks"
        desc="Merge your task lists into the Todo pane. Prefix a new todo with “g ” to create it in Google."
        on={settings.google.syncTasks}
        onChange={(v) => void set({ google: { ...settings.google, syncTasks: v } })}
      />

      <Setting
        name="OAuth client id"
        desc="From a Google Cloud “Desktop app” client. Leave blank to reuse the TUI's."
      >
        <input
          type="text"
          value={settings.google.clientId}
          placeholder="inherit from config.toml"
          onChange={(e) => void set({ google: { ...settings.google, clientId: e.target.value } })}
        />
      </Setting>
      <Setting name="OAuth client secret" desc="Not truly secret for installed apps.">
        <input
          type="password"
          value={settings.google.clientSecret}
          placeholder="inherit from config.toml"
          onChange={(e) =>
            void set({ google: { ...settings.google, clientSecret: e.target.value } })
          }
        />
      </Setting>

      {error && (
        <div className="empty-note" style={{ color: 'var(--error)' }}>
          {error}
        </div>
      )}
      <p style={{ color: 'var(--fg-subtle)', fontSize: 12, lineHeight: 1.6, marginTop: 16 }}>
        Onyx uses the installed-app loopback flow: connecting opens your browser, and the
        redirect comes back to <code>127.0.0.1</code> on a one-off port. The token is stored at{' '}
        <code>~/.config/onyx/google.json</code> (mode 600) — the same file the TUI uses, so you
        only ever authorize once. See <code>docs/CLOUD_SYNC.md</code> for creating the client.
      </p>
    </>
  )
}

function ModelSelect({
  value,
  models,
  onChange,
}: {
  value: string
  models: string[]
  onChange: (v: string) => void
}): JSX.Element {
  if (!models.length) {
    return <input type="text" value={value} onChange={(e) => onChange(e.target.value)} />
  }
  const options = models.includes(value) ? models : [value, ...models]
  return (
    <select value={value} onChange={(e) => onChange(e.target.value)}>
      {options.map((m) => (
        <option key={m} value={m}>
          {m}
        </option>
      ))}
    </select>
  )
}

function Setting({
  name,
  desc,
  children,
}: {
  name: string
  desc?: string
  children: React.ReactNode
}): JSX.Element {
  return (
    <div className="setting">
      <div className="info">
        <div className="name">{name}</div>
        {desc && <div className="desc">{desc}</div>}
      </div>
      <div className="control">{children}</div>
    </div>
  )
}

function Toggle({
  name,
  desc,
  on,
  onChange,
}: {
  name: string
  desc?: string
  on: boolean
  onChange: (v: boolean) => void
}): JSX.Element {
  return (
    <Setting name={name} desc={desc}>
      <div className={`toggle${on ? ' is-on' : ''}`} onClick={() => onChange(!on)} role="switch" />
    </Setting>
  )
}
