/**
 * Workspace state: vault snapshot, panes/tabs, sidebars, settings.
 *
 * Modelled on Obsidian's workspace — a row of panes, each holding a stack of
 * tabs, each tab holding one view. Splits are horizontal only (the vast
 * majority of real Obsidian layouts) which keeps the reducer honest.
 */

import { create } from 'zustand'
import type {
  AppSettings,
  DriveFile,
  FileNode,
  GraphData,
  NoteMeta,
  SectionId,
  SectionState,
  SessionState,
  VaultSnapshot,
} from '@shared/types'
import { applyTheme, themeById } from './themes'

export type ViewType =
  | 'markdown'
  | 'graph'
  | 'localgraph'
  | 'canvas'
  | 'database'
  | 'ai'
  | 'search'
  | 'drive'
  | 'image'
  | 'pdf'
  | 'empty'

export interface Tab {
  id: string
  type: ViewType
  /** Vault-relative path for file-backed views. */
  path: string | null
  title: string
  /** Per-view scratch state (scroll offset, board grouping, …). */
  state: Record<string, unknown>
  pinned: boolean
  /** Editing mode for markdown tabs. */
  mode?: 'livePreview' | 'source' | 'reading'
  /** Back/forward history within this tab. */
  history: string[]
  historyIndex: number
}

export interface Pane {
  id: string
  tabs: Tab[]
  activeTabId: string | null
}


export interface UnsavedDoc {
  content: string
  dirty: boolean
  /** mtime the buffer was loaded at, for the external-change conflict guard. */
  baseMtime: number
}

interface State {
  ready: boolean
  vault: { root: string; name: string } | null
  /** 'native' or 'polling' — surfaced in the status bar. */
  watchMode: 'native' | 'polling'
  tree: FileNode | null
  notes: Map<string, NoteMeta>
  attachments: string[]
  graph: GraphData | null
  settings: AppSettings | null

  panes: Pane[]
  activePaneId: string
  leftOpen: boolean
  rightOpen: boolean
  leftWidth: number
  rightWidth: number
  /** Stacked panes per side, in order. */
  sections: { left: SectionState[]; right: SectionState[] }
  /** Full-screen focus on one pane (Onyx's Ctrl-F expand). */
  zenPaneId: string | null

  /** Open buffers keyed by path — survives tab switches. */
  docs: Map<string, UnsavedDoc>

  /**
   * The last markdown note that was focused anywhere in the workspace. Views
   * that follow "the note you're reading" — the local graph, the AI pane —
   * use this so they don't go blank when you focus them.
   */
  lastNotePath: string | null

  modal:
    | null
    | { kind: 'switcher' }
    | { kind: 'palette' }
    | { kind: 'search'; initial?: string }
    | { kind: 'settings'; section?: string }
    | { kind: 'prompt'; title: string; value: string; onSubmit: (v: string) => void }
    | { kind: 'confirm'; title: string; body: string; onConfirm: () => void }
    | { kind: 'tagPicker' }

  status: string
  /** Bookmarked note paths (persisted in the vault's `.onyx/bookmarks.json`). */
  bookmarks: string[]

  /**
   * Drive-backed buffers, keyed by their synthetic `drive:<id>` path. Kept
   * apart from `notes` because they aren't vault files: they never appear in
   * the index or the graph, and saving them goes to Drive, not the disk.
   */
  driveDocs: Map<string, { id: string; name: string; mime: string }>
}

interface Actions {
  init(): Promise<void>
  refreshVault(): Promise<void>
  restoreSession(session: SessionState | null): Promise<void>
  refreshGraph(): Promise<void>
  setSettings(patch: Partial<AppSettings>): Promise<void>

  activePane(): Pane
  activeTab(): Tab | null
  openFile(path: string, opts?: { pane?: string; newTab?: boolean; mode?: Tab['mode'] }): Promise<void>
  /** Open a Drive text file in an editor tab; saving writes back to Drive. */
  openDriveFile(file: DriveFile): Promise<void>
  openView(
    type: ViewType,
    opts?: {
      path?: string | null
      title?: string
      state?: Record<string, unknown>
      newPane?: boolean
    },
  ): void
  closeTab(paneId: string, tabId: string): void
  setActiveTab(paneId: string, tabId: string): void
  moveTab(fromPane: string, tabId: string, toPane: string, index: number): void
  splitPane(): void
  closePane(paneId: string): void
  setTabMode(tabId: string, mode: NonNullable<Tab['mode']>): void
  navigate(delta: number): void

  /** Load a buffer if it isn't already open (restored tabs load lazily). */
  ensureDoc(path: string): Promise<void>
  /** Snapshot the workspace into settings, debounced. */
  persistSession(): void
  setDoc(path: string, content: string, dirty?: boolean): void
  saveDoc(path: string): Promise<void>
  saveAll(): Promise<void>

  toggleLeft(): void
  toggleRight(): void
  setSectionHeight(id: SectionId, height: number): void
  toggleSectionCollapsed(id: SectionId): void
  /** Show/hide a pane; `show` forces a state, otherwise it flips. */
  toggleSection(id: SectionId, show?: boolean): void
  setLeftWidth(w: number): void
  setRightWidth(w: number): void
  persistLayout(patch: Partial<AppSettings['layout']>): void
  updateSection(id: SectionId, patch: (s: SectionState) => Partial<SectionState>): void
  toggleZen(paneId?: string): void

  setModal(m: State['modal']): void
  setStatus(s: string): void
  toggleBookmark(path: string): Promise<void>
}

let seq = 0
let layoutTimer: ReturnType<typeof setTimeout> | null = null
let sessionTimer: ReturnType<typeof setTimeout> | null = null
const uid = (): string => `${Date.now().toString(36)}-${(seq++).toString(36)}`

function newTab(partial: Partial<Tab> = {}): Tab {
  return {
    id: uid(),
    type: 'empty',
    path: null,
    title: 'New tab',
    state: {},
    pinned: false,
    history: [],
    historyIndex: -1,
    ...partial,
  }
}

function titleFor(path: string): string {
  const base = path.split('/').pop() ?? path
  return base.replace(/\.(md|markdown|mdx|canvas)$/i, '')
}

function viewTypeFor(path: string): ViewType {
  if (path.startsWith('drive:')) return 'markdown'
  const ext = (path.split('.').pop() ?? '').toLowerCase()
  if (['md', 'markdown', 'mdx'].includes(ext)) return 'markdown'
  if (ext === 'canvas') return 'canvas'
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'avif'].includes(ext)) return 'image'
  if (ext === 'pdf') return 'pdf'
  return 'empty'
}

export const useStore = create<State & Actions>((set, get) => ({
  ready: false,
  vault: null,
  watchMode: 'native',
  tree: null,
  notes: new Map(),
  attachments: [],
  graph: null,
  settings: null,

  panes: [{ id: 'p0', tabs: [newTab()], activeTabId: null }],
  activePaneId: 'p0',
  leftOpen: true,
  rightOpen: true,
  leftWidth: 260,
  rightWidth: 300,
  sections: { left: [], right: [] },
  zenPaneId: null,

  docs: new Map(),
  lastNotePath: null,
  modal: null,
  status: '',
  bookmarks: [],
  driveDocs: new Map(),

  // ------------------------------------------------------------------ init

  async init() {
    const settings = await window.onyx.settings.get()
    applyTheme(themeById(settings.theme))
    const current = await window.onyx.vault.current()
    const vault = current ? { root: current.root, name: current.name } : null
    set({
      settings,
      vault,
      watchMode: (current?.watchMode as 'native' | 'polling') ?? 'native',
      leftOpen: settings.layout.leftOpen,
      rightOpen: settings.layout.rightOpen,
      leftWidth: settings.layout.leftWidth,
      rightWidth: settings.layout.rightWidth,
      sections: { left: settings.layout.left, right: settings.layout.right },
    })
    if (vault) {
      await get().refreshVault()
      await get().refreshGraph()
      try {
        const raw = await window.onyx.file.read('.onyx/bookmarks.json')
        set({ bookmarks: JSON.parse(raw) as string[] })
      } catch {
        /* no bookmarks yet */
      }
    }
    await get().restoreSession(settings.session)

    const pane = get().panes[0]
    if (pane.tabs.length && pane.activeTabId === null) {
      set({ panes: [{ ...pane, activeTabId: pane.tabs[0].id }] })
    }
    set({ ready: true })
  },

  async refreshVault() {
    const snap: VaultSnapshot = await window.onyx.vault.snapshot()
    set({
      vault: { root: snap.root, name: snap.name },
      tree: snap.tree,
      notes: new Map(snap.notes.map((n) => [n.path, n])),
      attachments: snap.attachments,
    })
  },

  /**
   * Rebuild the workspace saved by `persistSession`. Anything that no longer
   * makes sense is dropped rather than restored broken: a session from another
   * vault, a tab whose file was deleted, a view type this build doesn't have.
   */
  async restoreSession(session) {
    const s = get()
    if (!session || !s.vault || session.vault !== s.vault.root) return
    if (!session.panes.length) return

    const driveDocs = new Map(session.driveDocs.map((d) => [d.key, { id: d.id, name: d.name, mime: d.mime }]))
    const known = new Set<ViewType>([
      'markdown', 'graph', 'localgraph', 'canvas', 'database', 'ai', 'search', 'drive', 'image', 'pdf', 'empty',
    ])
    const exists = (path: string | null): boolean => {
      if (!path) return true
      if (path.startsWith('drive:')) return driveDocs.has(path)
      return s.notes.has(path) || s.attachments.includes(path)
    }

    const panes: Pane[] = []
    for (const saved of session.panes) {
      const tabs = saved.tabs
        .filter((t) => known.has(t.type as ViewType) && exists(t.path))
        .map((t) =>
          newTab({
            type: t.type as ViewType,
            path: t.path,
            title: t.title,
            mode: t.mode,
            pinned: t.pinned,
            state: t.state ?? {},
            history: t.history ?? [],
            historyIndex: t.historyIndex ?? -1,
          }),
        )
      if (!tabs.length) continue
      const active = tabs[Math.min(Math.max(saved.activeIndex, 0), tabs.length - 1)]
      panes.push({ id: uid(), tabs, activeTabId: active.id })
    }
    if (!panes.length) return

    const activePane = panes[Math.min(Math.max(session.activePaneIndex, 0), panes.length - 1)]
    set({ panes, activePaneId: activePane.id, driveDocs })

    // Only the visible tab of each pane needs its buffer now; the rest load
    // when they're selected.
    for (const pane of panes) {
      const tab = pane.tabs.find((t) => t.id === pane.activeTabId)
      if (tab?.type === 'markdown' && tab.path) await get().ensureDoc(tab.path)
      if (tab?.type === 'markdown' && tab.path) set({ lastNotePath: tab.path })
    }
  },

  async refreshGraph() {
    set({ graph: await window.onyx.vault.graph() })
  },

  async setSettings(patch) {
    const next = await window.onyx.settings.set(patch)
    if (patch.theme) applyTheme(themeById(next.theme))
    set({ settings: next })
  },

  // ----------------------------------------------------------- pane / tab

  activePane() {
    const s = get()
    return s.panes.find((p) => p.id === s.activePaneId) ?? s.panes[0]
  },

  activeTab() {
    const pane = get().activePane()
    return pane.tabs.find((t) => t.id === pane.activeTabId) ?? null
  },

  async openFile(path, opts = {}) {
    const s = get()
    const paneId = opts.pane ?? s.activePaneId
    const pane = s.panes.find((p) => p.id === paneId) ?? s.panes[0]
    const type = viewTypeFor(path)

    // Already open in this pane? Just focus it.
    const existing = pane.tabs.find((t) => t.path === path)
    if (existing && !opts.newTab) {
      set({
        activePaneId: pane.id,
        panes: s.panes.map((p) => (p.id === pane.id ? { ...p, activeTabId: existing.id } : p)),
      })
      return
    }

    if (type === 'markdown' && !s.docs.has(path)) {
      try {
        const content = await window.onyx.file.read(path)
        const meta = get().notes.get(path)
        const docs = new Map(get().docs)
        docs.set(path, { content, dirty: false, baseMtime: meta?.mtime ?? Date.now() })
        set({ docs })
      } catch {
        get().setStatus(`Can't read ${path}`)
        return
      }
    }

    const current = pane.tabs.find((t) => t.id === pane.activeTabId)
    const reuse = !opts.newTab && current && !current.pinned && (current.type === 'empty' || current.path === null)

    const tab: Tab = reuse
      ? {
          ...current!,
          type,
          path,
          title: titleFor(path),
          mode: opts.mode ?? s.settings?.defaultEditorMode ?? 'livePreview',
          history: [...current!.history.slice(0, current!.historyIndex + 1), path],
          historyIndex: current!.historyIndex + 1,
        }
      : newTab({
          type,
          path,
          title: titleFor(path),
          mode: opts.mode ?? s.settings?.defaultEditorMode ?? 'livePreview',
          history: [path],
          historyIndex: 0,
        })

    set({
      activePaneId: pane.id,
      lastNotePath: type === 'markdown' ? path : s.lastNotePath,
      panes: s.panes.map((p) =>
        p.id !== pane.id
          ? p
          : {
              ...p,
              tabs: reuse ? p.tabs.map((t) => (t.id === tab.id ? tab : t)) : [...p.tabs, tab],
              activeTabId: tab.id,
            },
      ),
    })
  },

  async openDriveFile(file) {
    const key = `drive:${file.id}`
    const s = get()
    if (!s.docs.has(key)) {
      let content: string
      try {
        content = await window.onyx.drive.read(file.id)
      } catch (e) {
        s.setStatus((e as Error).message)
        return
      }
      const docs = new Map(s.docs)
      docs.set(key, { content, dirty: false, baseMtime: Date.now() })
      const driveDocs = new Map(s.driveDocs)
      driveDocs.set(key, { id: file.id, name: file.name, mime: file.mimeType || 'text/plain' })
      set({ docs, driveDocs })
    }
    const pane = get().activePane()
    const existing = pane.tabs.find((t) => t.path === key)
    if (existing) {
      get().setActiveTab(pane.id, existing.id)
      return
    }
    const tab = newTab({
      type: 'markdown',
      path: key,
      title: file.name,
      mode: get().settings?.defaultEditorMode ?? 'livePreview',
      history: [key],
      historyIndex: 0,
    })
    set({
      panes: get().panes.map((p) =>
        p.id === pane.id ? { ...p, tabs: [...p.tabs, tab], activeTabId: tab.id } : p,
      ),
    })
  },

  openView(type, opts = {}) {
    const s = get()
    if (opts.newPane) get().splitPane()
    const st = get()
    const paneId = st.activePaneId
    const pane = st.panes.find((p) => p.id === paneId)!

    // Graph/AI views are singletons per pane, like Obsidian's.
    const existing = pane.tabs.find((t) => t.type === type && (opts.path ?? null) === t.path)
    if (existing) {
      set({ panes: st.panes.map((p) => (p.id === paneId ? { ...p, activeTabId: existing.id } : p)) })
      return
    }

    const titles: Record<string, string> = {
      graph: 'Graph view',
      localgraph: 'Local graph',
      ai: 'Onyx AI',
      database: 'Database',
      canvas: 'Canvas',
      empty: 'New tab',
    }
    const tab = newTab({
      type,
      path: opts.path ?? null,
      title: opts.title ?? titles[type] ?? type,
      state: opts.state ?? {},
    })
    const current = pane.tabs.find((t) => t.id === pane.activeTabId)
    const reuse = current && current.type === 'empty' && !current.pinned
    set({
      panes: st.panes.map((p) =>
        p.id !== paneId
          ? p
          : {
              ...p,
              tabs: reuse
                ? p.tabs.map((t) => (t.id === current!.id ? { ...tab, id: current!.id } : t))
                : [...p.tabs, tab],
              activeTabId: reuse ? current!.id : tab.id,
            },
      ),
    })
    void s
  },

  closeTab(paneId, tabId) {
    const s = get()
    const pane = s.panes.find((p) => p.id === paneId)
    if (!pane) return
    const idx = pane.tabs.findIndex((t) => t.id === tabId)
    if (idx < 0) return
    const tabs = pane.tabs.filter((t) => t.id !== tabId)

    if (!tabs.length) {
      if (s.panes.length > 1) {
        const panes = s.panes.filter((p) => p.id !== paneId)
        set({ panes, activePaneId: panes[0].id, zenPaneId: null })
        return
      }
      const blank = newTab()
      set({ panes: [{ ...pane, tabs: [blank], activeTabId: blank.id }] })
      return
    }
    const nextActive =
      pane.activeTabId === tabId ? tabs[Math.min(idx, tabs.length - 1)].id : pane.activeTabId
    set({
      panes: s.panes.map((p) => (p.id === paneId ? { ...p, tabs, activeTabId: nextActive } : p)),
    })
  },

  setActiveTab(paneId, tabId) {
    const s = get()
    const tab = s.panes.find((p) => p.id === paneId)?.tabs.find((t) => t.id === tabId)
    if (tab?.type === 'markdown' && tab.path) void get().ensureDoc(tab.path)
    set({
      activePaneId: paneId,
      lastNotePath: tab?.type === 'markdown' && tab.path ? tab.path : s.lastNotePath,
      panes: s.panes.map((p) => (p.id === paneId ? { ...p, activeTabId: tabId } : p)),
    })
  },

  moveTab(fromPane, tabId, toPane, index) {
    const s = get()
    const src = s.panes.find((p) => p.id === fromPane)
    const dst = s.panes.find((p) => p.id === toPane)
    if (!src || !dst) return
    const tab = src.tabs.find((t) => t.id === tabId)
    if (!tab) return
    const srcTabs = src.tabs.filter((t) => t.id !== tabId)
    const dstTabs = fromPane === toPane ? srcTabs : [...dst.tabs]
    dstTabs.splice(Math.max(0, Math.min(index, dstTabs.length)), 0, tab)

    let panes = s.panes.map((p) => {
      if (p.id === toPane) return { ...p, tabs: dstTabs, activeTabId: tab.id }
      if (p.id === fromPane)
        return {
          ...p,
          tabs: srcTabs,
          activeTabId: srcTabs.length ? (p.activeTabId === tabId ? srcTabs[0].id : p.activeTabId) : null,
        }
      return p
    })
    panes = panes.filter((p) => p.tabs.length > 0)
    if (!panes.length) panes = [{ id: 'p0', tabs: [newTab()], activeTabId: null }]
    set({ panes, activePaneId: toPane })
  },

  splitPane() {
    const s = get()
    const src = s.activePane()
    const active = src.tabs.find((t) => t.id === src.activeTabId)
    const clone: Tab = active
      ? { ...active, id: uid() }
      : newTab()
    const pane: Pane = { id: uid(), tabs: [clone], activeTabId: clone.id }
    const idx = s.panes.findIndex((p) => p.id === src.id)
    const panes = [...s.panes]
    panes.splice(idx + 1, 0, pane)
    set({ panes, activePaneId: pane.id })
  },

  closePane(paneId) {
    const s = get()
    if (s.panes.length === 1) return
    const panes = s.panes.filter((p) => p.id !== paneId)
    set({
      panes,
      activePaneId: s.activePaneId === paneId ? panes[0].id : s.activePaneId,
      zenPaneId: s.zenPaneId === paneId ? null : s.zenPaneId,
    })
  },

  setTabMode(tabId, mode) {
    set({
      panes: get().panes.map((p) => ({
        ...p,
        tabs: p.tabs.map((t) => (t.id === tabId ? { ...t, mode } : t)),
      })),
    })
  },

  navigate(delta) {
    const s = get()
    const pane = s.activePane()
    const tab = pane.tabs.find((t) => t.id === pane.activeTabId)
    if (!tab) return
    const next = tab.historyIndex + delta
    if (next < 0 || next >= tab.history.length) return
    const path = tab.history[next]
    set({
      panes: s.panes.map((p) =>
        p.id !== pane.id
          ? p
          : {
              ...p,
              tabs: p.tabs.map((t) =>
                t.id !== tab.id
                  ? t
                  : { ...t, path, title: titleFor(path), type: viewTypeFor(path), historyIndex: next },
              ),
            },
      ),
    })
    if (!s.docs.has(path)) void get().openFile(path)
  },

  // ------------------------------------------------------------ documents

  async ensureDoc(path) {
    const s = get()
    if (s.docs.has(path)) return
    try {
      const drive = s.driveDocs.get(path)
      const content = drive
        ? await window.onyx.drive.read(drive.id)
        : await window.onyx.file.read(path)
      const docs = new Map(get().docs)
      docs.set(path, { content, dirty: false, baseMtime: get().notes.get(path)?.mtime ?? Date.now() })
      set({ docs })
    } catch {
      // The file moved or vanished since the session was saved; the tab stays
      // open and empty rather than the restore failing wholesale.
    }
  },

  persistSession() {
    const s = get()
    if (!s.vault || !s.ready) return
    if (sessionTimer) clearTimeout(sessionTimer)
    sessionTimer = setTimeout(() => {
      const state = useStore.getState()
      if (!state.vault) return
      const session: SessionState = {
        vault: state.vault.root,
        activePaneIndex: Math.max(
          0,
          state.panes.findIndex((p) => p.id === state.activePaneId),
        ),
        panes: state.panes.map((pane) => ({
          activeIndex: pane.tabs.findIndex((t) => t.id === pane.activeTabId),
          tabs: pane.tabs.map((tab) => ({
            type: tab.type,
            path: tab.path,
            title: tab.title,
            mode: tab.mode,
            pinned: tab.pinned,
            // `pending` is a one-shot instruction (run a summary, say); it must
            // not fire again on every restore.
            state: Object.fromEntries(
              Object.entries(tab.state).filter(([k]) => k !== 'pending'),
            ),
            history: tab.history,
            historyIndex: tab.historyIndex,
          })),
        })),
        driveDocs: [...state.driveDocs.entries()].map(([key, d]) => ({ key, ...d })),
      }
      void window.onyx.settings.set({ session })
    }, 600)
  },

  setDoc(path, content, dirty = true) {
    const docs = new Map(get().docs)
    const prev = docs.get(path)
    docs.set(path, { content, dirty, baseMtime: prev?.baseMtime ?? Date.now() })
    set({ docs })
  },

  async saveDoc(path) {
    const doc = get().docs.get(path)
    if (!doc || !doc.dirty) return

    // Drive-backed buffer: PATCH it back instead of writing to the vault.
    const drive = get().driveDocs.get(path)
    if (drive) {
      try {
        await window.onyx.drive.write(drive.id, doc.content, drive.mime)
      } catch (e) {
        get().setStatus((e as Error).message)
        return
      }
      const docs = new Map(get().docs)
      docs.set(path, { ...doc, dirty: false })
      set({ docs })
      get().setStatus(`Saved "${drive.name}" to Google Drive`)
      return
    }

    const meta = await window.onyx.file.write(path, doc.content)
    const docs = new Map(get().docs)
    docs.set(path, { ...doc, dirty: false, baseMtime: meta?.mtime ?? Date.now() })
    set({ docs })
    if (meta) {
      const notes = new Map(get().notes)
      notes.set(path, meta)
      set({ notes })
    }
  },

  async saveAll() {
    for (const [path, doc] of get().docs) if (doc.dirty) await get().saveDoc(path)
  },

  // ---------------------------------------------------------------- chrome

  toggleLeft: () => {
    const leftOpen = !get().leftOpen
    set({ leftOpen })
    get().persistLayout({ leftOpen })
  },
  toggleRight: () => {
    const rightOpen = !get().rightOpen
    set({ rightOpen })
    get().persistLayout({ rightOpen })
  },
  setSectionHeight: (id, height) => get().updateSection(id, () => ({ height })),
  toggleSectionCollapsed: (id) =>
    get().updateSection(id, (sec) => ({ collapsed: !sec.collapsed })),
  toggleSection: (id, show) =>
    get().updateSection(id, (sec) => {
      const visible = show ?? !sec.visible
      // Revealing a pane in a closed sidebar should open that sidebar too.
      return { visible, collapsed: visible ? false : sec.collapsed }
    }),
  setLeftWidth: (w) => {
    const leftWidth = Math.max(180, Math.min(560, w))
    set({ leftWidth })
    get().persistLayout({ leftWidth })
  },
  setRightWidth: (w) => {
    const rightWidth = Math.max(200, Math.min(620, w))
    set({ rightWidth })
    get().persistLayout({ rightWidth })
  },

  /** Apply a patch to one section and persist both stacks. */
  updateSection(id, patch) {
    const s = get()
    const apply = (list: SectionState[]): SectionState[] =>
      list.map((sec) => (sec.id === id ? { ...sec, ...patch(sec) } : sec))
    const left = apply(s.sections.left)
    const right = apply(s.sections.right)
    const inLeft = s.sections.left.some((sec) => sec.id === id)
    const revealed = (inLeft ? left : right).find((sec) => sec.id === id)?.visible
    set({
      sections: { left, right },
      ...(revealed ? (inLeft ? { leftOpen: true } : { rightOpen: true }) : {}),
    })
    get().persistLayout({
      left,
      right,
      ...(revealed ? (inLeft ? { leftOpen: true } : { rightOpen: true }) : {}),
    })
  },

  /** Debounced write-through of the sidebar layout (drags fire constantly). */
  persistLayout(patch) {
    const s = get()
    if (!s.settings) return
    const layout = { ...s.settings.layout, ...patch }
    set({ settings: { ...s.settings, layout } })
    if (layoutTimer) clearTimeout(layoutTimer)
    layoutTimer = setTimeout(() => void window.onyx.settings.set({ layout }), 300)
  },
  toggleZen: (paneId) => {
    const s = get()
    const id = paneId ?? s.activePaneId
    set({ zenPaneId: s.zenPaneId === id ? null : id })
  },

  setModal: (m) => set({ modal: m }),
  setStatus: (s) => {
    set({ status: s })
    if (s) setTimeout(() => useStore.getState().status === s && set({ status: '' }), 4000)
  },

  async toggleBookmark(path) {
    const s = get()
    const next = s.bookmarks.includes(path)
      ? s.bookmarks.filter((b) => b !== path)
      : [...s.bookmarks, path]
    set({ bookmarks: next })
    try {
      await window.onyx.file.write('.onyx/bookmarks.json', JSON.stringify(next, null, 2))
    } catch {
      /* best-effort */
    }
  },
}))

export { titleFor, viewTypeFor, uid }
