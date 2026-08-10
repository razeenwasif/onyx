/**
 * Desktop settings, stored next to the TUI's config so both halves of Onyx
 * share a home. The TUI keeps `~/.config/onyx/config.toml`; the desktop app
 * keeps `~/.config/onyx/desktop.json` and, on first run, seeds `lastVault`
 * from the TUI's `last_vault` so opening either one lands in the same vault.
 */

import { promises as fs } from 'node:fs'
import * as fsSync from 'node:fs'
import * as path from 'node:path'
import * as os from 'node:os'

import type { AppSettings } from '../shared/types.js'
import { DEFAULT_GRAPH, DEFAULT_LOCAL_GRAPH } from '../shared/graph-defaults.js'

export function configDir(): string {
  if (process.env.ONYX_CONFIG_DIR) return process.env.ONYX_CONFIG_DIR
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming'), 'onyx')
  }
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'onyx')
  }
  return path.join(process.env.XDG_CONFIG_HOME ?? path.join(os.homedir(), '.config'), 'onyx')
}

export function settingsPath(): string {
  return path.join(configDir(), 'desktop.json')
}

export const DEFAULT_SETTINGS: AppSettings = {
  lastVault: null,
  recentVaults: [],
  theme: 'onyx-dark',
  layout: {
    leftOpen: true,
    rightOpen: true,
    leftWidth: 260,
    rightWidth: 300,
    leftPanel: 'files',
    rightPanel: 'backlinks',
  },
  defaultEditorMode: 'livePreview',
  vimMode: false,
  lineNumbers: false,
  readableLineLength: true,
  spellcheck: false,
  fontSize: 16,
  tabSize: 4,
  useSpaces: true,
  autosave: true,
  autosaveIdleMs: 2000,
  showFrontmatter: true,
  dailyNotes: { folder: 'Daily', format: 'YYYY-MM-DD', template: null },
  attachmentFolder: 'attachments',
  graph: DEFAULT_GRAPH,
  localGraph: DEFAULT_LOCAL_GRAPH,
  google: {
    // Empty means "use the TUI's [google] client from config.toml".
    clientId: '',
    clientSecret: '',
    syncCalendar: true,
    syncTasks: true,
  },
  ai: {
    model: 'gemma4:e4b-it-qat',
    embedModel: 'nomic-embed-text',
    completionModel: 'gemma4:e2b-it-qat',
    autocomplete: true,
    host: 'http://localhost:11434',
  },
}

/** Deep-merge stored settings over the defaults so new keys appear on upgrade. */
function merge<T>(base: T, patch: unknown): T {
  if (patch === undefined) return base
  // `typeof null === 'object'`, so a nullable default (lastVault) has to be
  // handled before the object branch or every write to it is dropped.
  if (base === null || patch === null) return patch as T
  if (Array.isArray(base) || typeof base !== 'object') return patch as T
  if (typeof patch !== 'object' || Array.isArray(patch)) return base
  const out = { ...(base as Record<string, unknown>) }
  for (const [k, v] of Object.entries(patch as Record<string, unknown>)) {
    out[k] = k in out ? merge(out[k], v) : v
  }
  return out as T
}

/** `last_vault = "..."` out of the TUI's config.toml, if present. */
function tuiLastVault(): string | null {
  try {
    const raw = fsSync.readFileSync(path.join(configDir(), 'config.toml'), 'utf8')
    const m = /^\s*last_vault\s*=\s*"((?:[^"\\]|\\.)*)"/m.exec(raw)
    if (m) return m[1].replace(/\\(.)/g, '$1')
  } catch {
    /* no TUI config */
  }
  return null
}

export class SettingsStore {
  private data: AppSettings = DEFAULT_SETTINGS
  private saveTimer: NodeJS.Timeout | null = null

  async load(): Promise<AppSettings> {
    try {
      const raw = await fs.readFile(settingsPath(), 'utf8')
      this.data = merge(DEFAULT_SETTINGS, JSON.parse(raw))
    } catch {
      this.data = { ...DEFAULT_SETTINGS }
    }
    if (!this.data.lastVault) this.data.lastVault = tuiLastVault()
    return this.data
  }

  get(): AppSettings {
    return this.data
  }

  /** Shallow-patch and persist (debounced — settings sliders fire constantly). */
  update(patch: Partial<AppSettings>): AppSettings {
    this.data = merge(this.data, patch)
    this.scheduleSave()
    return this.data
  }

  rememberVault(root: string): void {
    const recents = [root, ...this.data.recentVaults.filter((v) => v !== root)].slice(0, 12)
    this.update({ lastVault: root, recentVaults: recents })
  }

  private scheduleSave(): void {
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => void this.flush(), 400)
  }

  async flush(): Promise<void> {
    if (this.saveTimer) {
      clearTimeout(this.saveTimer)
      this.saveTimer = null
    }
    try {
      await fs.mkdir(configDir(), { recursive: true })
      await fs.writeFile(settingsPath(), JSON.stringify(this.data, null, 2), 'utf8')
    } catch {
      /* settings are best-effort */
    }
  }
}
