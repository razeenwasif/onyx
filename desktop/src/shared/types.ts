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
  /** Vault-relative path with forward slashes, e.g. `Projects/Onyx.md`. */
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
  /** `note` = a real markdown file, `unresolved` = a link with no file, `tag` = a #tag, `attachment` = image/pdf/etc. */
  kind: 'note' | 'unresolved' | 'tag' | 'attachment'
  degree: number
  /** Vault-relative folder, for group queries. */
  folder: string
  tags: string[]
}

export interface GraphLink {
  source: number
  target: number
  kind: 'link' | 'tag' | 'attachment'
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

export interface SearchHit {
  path: string
  title: string
  matches: Array<{ line: number; text: string; from: number; to: number }>
  score: number
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
  showAttachments: boolean
  existingOnly: boolean
  showOrphans: boolean
  // Groups
  groups: Array<{ query: string; color: string }>
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
}

export interface LocalGraphSettings extends GraphSettings {
  depth: number
  incoming: boolean
  outgoing: boolean
  neighborLinks: boolean
}

export interface AiSettings {
  model: string
  embedModel: string
  completionModel: string
  autocomplete: boolean
  host: string
}

export interface AppSettings {
  lastVault: string | null
  recentVaults: string[]
  theme: string
  /** `livePreview` | `source` | `reading` */
  defaultEditorMode: 'livePreview' | 'source' | 'reading'
  vimMode: boolean
  lineNumbers: boolean
  readableLineLength: boolean
  spellcheck: boolean
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
