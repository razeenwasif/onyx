/** Types shared between the Electron main process and the renderer. */

export interface WikiLink {
  /** Full target with optional `#heading` / `^block`, without the alias. */
  target: string
  alias: string | null
  /** Character offset of the `[[`. */
  start: number
  /** Character offset just past the `]]`. */
  end: number
}

/** A note's content-derived facts, extracted once from its text. */
export interface NoteMeta {
  /** Vault-relative path with forward slashes, e.g. `Projects/Electron.md`. */
  path: string
  /** First H1, else the file basename. */
  title: string
  /** Raw link targets as written, pre-resolution. */
  targets: string[]
  /** Resolved outgoing links (vault-relative paths). */
  outgoing: string[]
  /** Link targets that resolved to nothing. */
  unresolved: string[]
  tags: string[]
  aliases: string[]
  /** Ordered frontmatter properties (tags/aliases excluded). */
  properties: Array<[string, string[]]>
  mtime: number
  size: number
  wordCount: number
}

export interface FileNode {
  /** Vault-relative path, forward slashes. `''` for the vault root. */
  path: string
  name: string
  isDir: boolean
  /** Present for directories. */
  children?: FileNode[]
  mtime?: number
  /** Lowercased extension without the dot, for files only. */
  ext?: string
}

export interface VaultSnapshot {
  root: string
  name: string
  tree: FileNode
  notes: NoteMeta[]
  /** Non-markdown files (attachments), vault-relative. */
  attachments: string[]
}

export interface GraphNode {
  id: string
  /** Display label. */
  title: string
  /**
   * `note` = a real markdown file, `unresolved` = a link with no file, `tag` = a #tag,
   * `attachment` = image/pdf/etc., `scribe` = a Scribe page (id `scribe:<pageId>`).
   */
  kind: 'note' | 'unresolved' | 'tag' | 'attachment' | 'scribe'
  degree: number
  /** Vault-relative folder, for group queries. */
  folder: string
  tags: string[]
}

export interface GraphLink {
  source: number
  target: number
  kind: 'link' | 'tag' | 'attachment' | 'tagParent'
}

export interface GraphData {
  nodes: GraphNode[]
  links: GraphLink[]
}

export interface Backlink {
  path: string
  title: string
  /** Matching context lines with the mention. */
  contexts: Array<{ line: number; text: string }>
}

/** An unticked `- [ ]` task somewhere in the vault (main/search.ts openTasks). */
export interface OpenTask {
  path: string
  title: string
  line: number
  text: string
  mtime: number
}

export interface SearchHit {
  path: string
  title: string
  matches: Array<{ line: number; text: string; from: number; to: number }>
  score: number
}

/** A Scribe page as links see it (macOS, when Scribe is embedded). */
export interface ScribePage {
  /** The page's own id, which `[[scribe:<id>|…]]` links name. */
  id: string
  title: string
  /** The page file's path. */
  path: string
  notebook: string
  section: string
  /** Unix seconds; 0 when unknown. */
  modified: number
  /** `[[…]]` targets typed on the page: note names, or `scribe:` pages. */
  links: string[]
}

/** A note's backlink: another note, or a Scribe page with `[[Note]]` typed on it. */
export interface BacklinkRef {
  path: string
  title: string
  /** Set for a Scribe page; `path` is then the page file. */
  scribe?: { id: string; notebook: string; section: string }
}

/** A Scribe page matching a search (macOS, when Scribe is embedded). */
export interface ScribeHit {
  title: string
  /** The page file's path; open it with apps.scribeOpen. */
  path: string
  notebook: string
  section: string
  /** Unix seconds; 0 when unknown. */
  modified: number
  /** Typed text, or the handwriting when only that matched. */
  snippet: string
}

export interface OutlineItem {
  level: number
  text: string
  line: number
}

// ---------------------------------------------------------------- settings

export interface GraphSettings {
  // Filters
  searchQuery: string
  showTags: boolean
  /**
   * Link `a/b` to `a` so a nested-tag hierarchy shows as one tree instead of
   * unrelated islands. Beyond Obsidian, which treats every tag as its own node.
   */
  linkNestedTags: boolean
  showAttachments: boolean
  existingOnly: boolean
  showOrphans: boolean
  // Groups
  groups: Array<{ query: string; color: string }>
  /** Color every node by its tag (an explicit group still wins). */
  colorByTag: boolean
  // Display
  arrows: boolean
  textFadeThreshold: number
  nodeSize: number
  linkThickness: number
  animate: boolean
  // Forces
  centerForce: number
  repelForce: number
  linkForce: number
  linkDistance: number
  /** Settle the layout into a round globe (a soft circular boundary). */
  globe: boolean
  /** 0–1: how strongly notes sharing a tag family gather into a "continent". */
  continentForce: number
}

export interface LocalGraphSettings extends GraphSettings {
  depth: number
  incoming: boolean
  outgoing: boolean
  neighborLinks: boolean
}

export interface GoogleSettings {
  /** Left empty to inherit the TUI's `[google]` client from config.toml. */
  clientId: string
  clientSecret: string
  /** Pull Calendar events for the visible month automatically. */
  syncCalendar: boolean
  /** Merge Google Tasks into the Todo pane automatically. */
  syncTasks: boolean
}

export interface GoogleStatus {
  connected: boolean
  /** Where the OAuth client came from. */
  source: 'config.toml' | 'desktop' | 'none'
  /** Granted scopes, when connected. */
  scope: string
}

export interface CalEvent {
  id: string
  calendarId: string
  summary: string
  date: string
  allDay: boolean
  timeLabel: string
}

export interface GTask {
  id: string
  listId: string
  listTitle: string
  title: string
  notes: string
  due: string | null
  completed: boolean
}

export interface DriveFile {
  id: string
  name: string
  mimeType: string
  isFolder: boolean
  /** Electron can open this as editable text. */
  isText: boolean
  /** A Google-native doc — needs export rather than download. */
  isGoogleDoc: boolean
  modifiedTime: string | null
  size: number | null
}

/** The coding agents Electron can run on the vault (main/agents.ts). */
export type AgentId = 'claude' | 'antigravity'

export interface AgentSettings {
  /** The agent a new conversation starts with. */
  default: AgentId
  /** Model names passed to each CLI; empty for its own default. */
  claudeModel: string
  antigravityModel: string
  /** Let agents edit notes (otherwise they only read and plan). */
  allowEdits: boolean
}

/** One turn of an agent conversation, from the renderer. */
export interface AgentRunRequest {
  runId: string
  agent: AgentId
  prompt: string
  /** The conversation to continue, or null for a new one. */
  sessionId: string | null
  model: string
  /** The note open in the editor (vault-relative), as context. */
  notePath: string | null
  allowEdits: boolean
}

/** What a running agent reports, normalised across CLIs. */
export type AgentEvent =
  | { kind: 'session'; id: string; model?: string }
  | { kind: 'text'; delta: string }
  | { kind: 'thinking' }
  | {
      kind: 'tool'
      id: string
      name: string
      summary: string
      state: 'running' | 'done' | 'error'
      detail?: string
      /** The tool changes files. */
      writes: boolean
    }
  | { kind: 'done'; sessionId?: string; costUsd?: number; error?: string; denied?: string[] }
  | { kind: 'error'; message: string }

export interface AiSettings {
  model: string
  embedModel: string
  completionModel: string
  autocomplete: boolean
  host: string
}

/** One stacked pane in a sidebar. `height: 0` means "share the leftover space". */
export interface SectionState {
  id: SectionId
  visible: boolean
  collapsed: boolean
  height: number
}

export type SectionId =
  | 'files'
  | 'bookmarks'
  | 'quicknote'
  | 'todo'
  | 'backlinks'
  | 'graph'
  | 'calendar'
  | 'outline'
  | 'tags'
  | 'properties'

/**
 * Sidebar layout, remembered between sessions. Each side is a vertical stack
 * of panes in order, following the TUI's layout rather than Obsidian's
 * one-tab-at-a-time sidebars.
 */
export interface LayoutSettings {
  leftOpen: boolean
  rightOpen: boolean
  leftWidth: number
  rightWidth: number
  left: SectionState[]
  right: SectionState[]
}

/** Window geometry, restored on the next launch. */
export interface WindowState {
  width: number
  height: number
  /** Undefined until the window has been moved; Electron centers it then. */
  x?: number
  y?: number
  maximized: boolean
}

/**
 * A restorable workspace: which tabs were open, in which panes, and which was
 * in front. Tab ids are not persisted — they're regenerated on restore — and
 * neither is buffer content, which is re-read from disk (or Drive) lazily.
 */
export interface SessionTab {
  type: string
  path: string | null
  title: string
  mode?: 'livePreview' | 'source' | 'reading'
  pinned: boolean
  state: Record<string, unknown>
  history: string[]
  historyIndex: number
}

export interface SessionPane {
  tabs: SessionTab[]
  /** Index into `tabs`; -1 when the pane is somehow empty. */
  activeIndex: number
}

export interface SessionState {
  /** The vault this layout belongs to; a different one discards it. */
  vault: string
  panes: SessionPane[]
  activePaneIndex: number
  /** Metadata for open Drive buffers, keyed by their `drive:<id>` path. */
  driveDocs: Array<{ key: string; id: string; name: string; mime: string }>
}

export interface AppSettings {
  /** Bumped when stored settings need a one-off migration (see settings.ts). */
  settingsVersion: number
  lastVault: string | null
  window: WindowState
  recentVaults: string[]
  theme: string
  /** Which app was on screen last: Electron's notes, or the embedded Scribe (macOS). */
  activeApp: 'electron' | 'scribe'
  layout: LayoutSettings
  /** The workspace as it was when the app last closed. */
  session: SessionState | null
  /** `livePreview` | `source` | `reading` */
  defaultEditorMode: 'livePreview' | 'source' | 'reading'
  vimMode: boolean
  lineNumbers: boolean
  readableLineLength: boolean
  /** Notes in a serif face (the reading column); off for the UI's sans. */
  serifText: boolean
  spellcheck: boolean
  /**
   * Filesystem watching. `auto` polls when the vault is on a filesystem that
   * doesn't deliver change events (WSL shares, /mnt/c, SMB).
   */
  watchMode: 'auto' | 'native' | 'polling'
  fontSize: number
  tabSize: number
  useSpaces: boolean
  autosave: boolean
  autosaveIdleMs: number
  showFrontmatter: boolean
  dailyNotes: { folder: string; format: string; template: string | null }
  attachmentFolder: string
  graph: GraphSettings
  localGraph: LocalGraphSettings
  ai: AiSettings
  agents: AgentSettings
  google: GoogleSettings
}

export type ThemeName = string

export interface ThemePalette {
  name: string
  dark: boolean
  bg: string
  bgAlt: string
  bgSel: string
  fg: string
  fgDim: string
  fgSubtle: string
  accent: string
  accentAlt: string
  link: string
  wikilink: string
  tag: string
  code: string
  heading: string
  headingAlt: string
  success: string
  warning: string
  error: string
  info: string
  border: string
  borderFocus: string
}
