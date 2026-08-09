/**
 * The command registry behind the command palette, the menu bar and every
 * hotkey. One place so a command's name, shortcut and behaviour can't drift.
 */

import { useStore } from './store'
import { dailyNotePath, uniqueUntitled } from './lib/notes'

export interface Command {
  id: string
  name: string
  /** Display form of the hotkey, e.g. `Ctrl+P`. */
  hotkey?: string
  /** Matcher against a normalized key string like `mod+p` / `mod+shift+f`. */
  keys?: string[]
  run: () => void | Promise<void>
  /** Hide from the palette when false. */
  enabled?: () => boolean
}

const mod = navigator.platform.toLowerCase().includes('mac') ? 'Cmd' : 'Ctrl'

function s() {
  return useStore.getState()
}

export const COMMANDS: Command[] = [
  {
    id: 'file:new',
    name: 'Create new note',
    hotkey: `${mod}+N`,
    keys: ['mod+n'],
    run: async () => {
      const st = s()
      const active = st.activeTab()
      const folder = active?.path ? active.path.split('/').slice(0, -1).join('/') : ''
      const path = uniqueUntitled(folder, st.notes)
      await window.onyx.file.create(path, '')
      await st.refreshVault()
      await st.openFile(path)
    },
  },
  {
    id: 'file:new-folder',
    name: 'Create new folder',
    run: () => {
      const st = s()
      st.setModal({
        kind: 'prompt',
        title: 'New folder',
        value: '',
        onSubmit: async (v) => {
          if (!v.trim()) return
          await window.onyx.file.mkdir(v.trim())
          await st.refreshVault()
        },
      })
    },
  },
  {
    id: 'file:save',
    name: 'Save current file',
    hotkey: `${mod}+S`,
    keys: ['mod+s'],
    run: async () => {
      const st = s()
      const tab = st.activeTab()
      if (tab?.path) await st.saveDoc(tab.path)
      st.setStatus('Saved')
    },
  },
  {
    id: 'file:rename',
    name: 'Rename current file',
    hotkey: 'F2',
    keys: ['f2'],
    run: () => {
      const st = s()
      const tab = st.activeTab()
      if (!tab?.path) return
      const base = tab.path.split('/').pop()!
      st.setModal({
        kind: 'prompt',
        title: 'Rename note',
        value: base.replace(/\.md$/i, ''),
        onSubmit: async (v) => {
          if (!v.trim()) return
          const dir = tab.path!.split('/').slice(0, -1).join('/')
          const to = (dir ? `${dir}/` : '') + v.trim() + '.md'
          const touched = await window.onyx.file.rename(tab.path!, to)
          await st.refreshVault()
          await st.refreshGraph()
          await st.openFile(to)
          st.setStatus(touched.length ? `Renamed — updated ${touched.length} link(s)` : 'Renamed')
        },
      })
    },
  },
  {
    id: 'file:delete',
    name: 'Delete current file',
    run: () => {
      const st = s()
      const tab = st.activeTab()
      if (!tab?.path) return
      st.setModal({
        kind: 'confirm',
        title: 'Delete note?',
        body: `"${tab.path}" will be moved to the system trash.`,
        onConfirm: async () => {
          await window.onyx.file.remove(tab.path!)
          st.closeTab(st.activePaneId, tab.id)
          await st.refreshVault()
          await st.refreshGraph()
        },
      })
    },
  },
  {
    id: 'file:daily',
    name: "Open today's daily note",
    run: async () => {
      const st = s()
      const cfg = st.settings
      if (!cfg) return
      const path = dailyNotePath(new Date(), cfg.dailyNotes.folder, cfg.dailyNotes.format)
      if (!(await window.onyx.file.exists(path))) {
        const title = path.split('/').pop()!.replace(/\.md$/, '')
        await window.onyx.file.create(path, `# ${title}\n\n`)
        await st.refreshVault()
      }
      await st.openFile(path)
    },
  },
  {
    id: 'palette:open',
    name: 'Open command palette',
    hotkey: `${mod}+P`,
    keys: ['mod+p'],
    run: () => s().setModal({ kind: 'palette' }),
  },
  {
    id: 'switcher:open',
    name: 'Open quick switcher',
    hotkey: `${mod}+O`,
    keys: ['mod+o'],
    run: () => s().setModal({ kind: 'switcher' }),
  },
  {
    id: 'search:open',
    name: 'Search in all files',
    hotkey: `${mod}+Shift+F`,
    keys: ['mod+shift+f'],
    run: () => s().setLeftPanel('search'),
  },
  {
    id: 'graph:open',
    name: 'Open graph view',
    hotkey: `${mod}+G`,
    keys: ['mod+g'],
    run: () => s().openView('graph'),
  },
  {
    id: 'graph:local',
    name: 'Open local graph',
    hotkey: `${mod}+Shift+G`,
    keys: ['mod+shift+g'],
    run: () => {
      const st = s()
      st.openView('localgraph', { path: st.activeTab()?.path ?? null })
    },
  },
  {
    id: 'canvas:new',
    name: 'Create new canvas',
    run: async () => {
      const st = s()
      let n = 1
      let path = 'Untitled.canvas'
      while (st.notes.has(path) || st.attachments.includes(path)) path = `Untitled ${++n}.canvas`
      await window.onyx.file.create(path, JSON.stringify({ nodes: [], edges: [] }, null, 2))
      await st.refreshVault()
      await st.openFile(path)
    },
  },
  {
    id: 'ai:open',
    name: 'Open Onyx AI assistant',
    hotkey: `${mod}+Shift+A`,
    keys: ['mod+shift+a'],
    run: () => s().openView('ai'),
  },
  {
    id: 'ai:summarize',
    name: 'AI: summarize this note',
    run: () => {
      const st = s()
      st.openView('ai', { state: { pending: { kind: 'summarize', path: st.activeTab()?.path } } })
    },
  },
  {
    id: 'ai:ask',
    name: 'AI: ask my vault (RAG)',
    run: () => s().openView('ai', { state: { pending: { kind: 'ask' } } }),
  },
  {
    id: 'db:open',
    name: 'Open folder as database',
    run: () => {
      const st = s()
      const tab = st.activeTab()
      const folder = tab?.path ? tab.path.split('/').slice(0, -1).join('/') : ''
      st.openView('database', { path: folder, title: `Database: ${folder || st.vault?.name}` })
    },
  },
  {
    id: 'sidebar:left',
    name: 'Toggle left sidebar',
    hotkey: `${mod}+B`,
    keys: ['mod+b'],
    run: () => s().toggleLeft(),
  },
  {
    id: 'sidebar:right',
    name: 'Toggle right sidebar',
    hotkey: `${mod}+Alt+B`,
    keys: ['mod+alt+b'],
    run: () => s().toggleRight(),
  },
  {
    id: 'editor:toggle-mode',
    name: 'Toggle reading view',
    hotkey: `${mod}+E`,
    keys: ['mod+e'],
    run: () => {
      const st = s()
      const tab = st.activeTab()
      if (!tab || tab.type !== 'markdown') return
      st.setTabMode(tab.id, tab.mode === 'reading' ? 'livePreview' : 'reading')
    },
  },
  {
    id: 'editor:source-mode',
    name: 'Toggle source mode',
    run: () => {
      const st = s()
      const tab = st.activeTab()
      if (!tab || tab.type !== 'markdown') return
      st.setTabMode(tab.id, tab.mode === 'source' ? 'livePreview' : 'source')
    },
  },
  {
    id: 'pane:split',
    name: 'Split right',
    hotkey: `${mod}+\\`,
    keys: ['mod+\\'],
    run: () => s().splitPane(),
  },
  {
    id: 'pane:zen',
    name: 'Toggle full-screen focus on this pane',
    hotkey: `${mod}+F`,
    keys: ['mod+f'],
    run: () => s().toggleZen(),
  },
  {
    id: 'tab:close',
    name: 'Close current tab',
    hotkey: `${mod}+W`,
    keys: ['mod+w'],
    run: () => {
      const st = s()
      const tab = st.activeTab()
      if (tab) st.closeTab(st.activePaneId, tab.id)
    },
  },
  {
    id: 'tab:next',
    name: 'Go to next tab',
    hotkey: `${mod}+PageDown`,
    keys: ['mod+pagedown'],
    run: () => {
      const st = s()
      const pane = st.activePane()
      const i = pane.tabs.findIndex((t) => t.id === pane.activeTabId)
      st.setActiveTab(pane.id, pane.tabs[(i + 1) % pane.tabs.length].id)
    },
  },
  {
    id: 'tab:prev',
    name: 'Go to previous tab',
    hotkey: `${mod}+PageUp`,
    keys: ['mod+pageup'],
    run: () => {
      const st = s()
      const pane = st.activePane()
      const i = pane.tabs.findIndex((t) => t.id === pane.activeTabId)
      st.setActiveTab(pane.id, pane.tabs[(i - 1 + pane.tabs.length) % pane.tabs.length].id)
    },
  },
  {
    id: 'nav:back',
    name: 'Navigate back',
    hotkey: 'Alt+Left',
    keys: ['alt+arrowleft'],
    run: () => s().navigate(-1),
  },
  {
    id: 'nav:forward',
    name: 'Navigate forward',
    hotkey: 'Alt+Right',
    keys: ['alt+arrowright'],
    run: () => s().navigate(1),
  },
  {
    id: 'bookmark:toggle',
    name: 'Bookmark / unbookmark current note',
    run: () => {
      const st = s()
      const tab = st.activeTab()
      if (tab?.path) void st.toggleBookmark(tab.path)
    },
  },
  {
    id: 'vault:open',
    name: 'Open another vault…',
    run: async () => {
      const picked = await window.onyx.vault.pick()
      if (picked) window.location.reload()
    },
  },
  {
    id: 'settings:open',
    name: 'Open settings',
    hotkey: `${mod}+,`,
    keys: ['mod+,'],
    run: () => s().setModal({ kind: 'settings' }),
  },
  {
    id: 'theme:cycle',
    name: 'Cycle theme',
    run: async () => {
      const st = s()
      const { THEMES } = await import('./themes')
      const i = THEMES.findIndex((t) => t.id === st.settings?.theme)
      const next = THEMES[(i + 1) % THEMES.length]
      await st.setSettings({ theme: next.id })
      st.setStatus(`Theme: ${next.name}`)
    },
  },
]

export const COMMAND_BY_ID = new Map(COMMANDS.map((c) => [c.id, c]))

/** Normalize a keyboard event into `mod+shift+p` form. */
export function keyString(e: KeyboardEvent): string {
  const parts: string[] = []
  if (e.ctrlKey || e.metaKey) parts.push('mod')
  if (e.altKey) parts.push('alt')
  if (e.shiftKey) parts.push('shift')
  const k = e.key.toLowerCase()
  parts.push(k === ' ' ? 'space' : k)
  return parts.join('+')
}

export function runCommand(id: string): void {
  void COMMAND_BY_ID.get(id)?.run()
}
