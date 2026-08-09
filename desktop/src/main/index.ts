/**
 * Electron main process: window lifecycle, the application menu, and every IPC
 * handler the renderer uses to reach the vault, the filesystem and Ollama.
 *
 * The renderer runs with `contextIsolation` and no Node integration; all
 * filesystem access is funnelled through the handlers below, which refuse any
 * path outside the open vault.
 */

import { app, BrowserWindow, dialog, ipcMain, Menu, nativeTheme, shell } from 'electron'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'
import { promises as fs } from 'node:fs'

import { Vault, defaultVaultPath, isMarkdown } from './vault.js'
import { SettingsStore } from './settings.js'
import { search, unlinkedMentions } from './search.js'
import {
  RagIndex,
  askPrompt,
  chatStream,
  completionPrompt,
  contextMessage,
  generate,
  listModels,
  rewritePrompt,
  summarizePrompt,
  ONYX_SYSTEM_PROMPT,
  type ChatMessage,
} from './ai.js'
import type { AppSettings } from '../shared/types.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const isDev = !app.isPackaged

let win: BrowserWindow | null = null
let vault: Vault | null = null
let rag: RagIndex | null = null
const settings = new SettingsStore()
/** In-flight AI streams, keyed by the renderer's request id. */
const aiStreams = new Map<string, AbortController>()

function send(channel: string, ...args: unknown[]): void {
  if (win && !win.isDestroyed()) win.webContents.send(channel, ...args)
}

// ---------------------------------------------------------------- window

function createWindow(): void {
  win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 700,
    minHeight: 480,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#1e1e24',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    webPreferences: {
      // ESM preload (`.mjs`) — the package is `"type": "module"`, so
      // electron-vite emits the preload bundle with that extension.
      preload: path.join(__dirname, '../preload/index.mjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: true,
    },
  })

  win.on('ready-to-show', () => {
    win?.show()
    // Dev/CI aid: ONYX_CAPTURE=/path/shot.png renders, screenshots, and quits.
    if (process.env.ONYX_CAPTURE) captureAndQuit(process.env.ONYX_CAPTURE)
  })
  win.on('closed', () => {
    win = null
  })

  win.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
    return { action: 'deny' }
  })

  if (isDev && process.env.ELECTRON_RENDERER_URL) {
    void win.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    void win.loadFile(path.join(__dirname, '../renderer/index.html'))
  }
}

/**
 * Screenshot the window after it settles, then exit. Driven by `ONYX_CAPTURE`
 * so a build machine can prove the UI actually renders. `ONYX_CAPTURE_CMD`
 * runs a renderer command (e.g. `graph:open`) first, and `ONYX_CAPTURE_DELAY`
 * overrides how long to wait.
 */
function captureAndQuit(target: string): void {
  const delay = Number(process.env.ONYX_CAPTURE_DELAY ?? 3500)
  const commands = (process.env.ONYX_CAPTURE_CMD ?? '').split(',').filter(Boolean)
  commands.forEach((cmd, i) => {
    setTimeout(() => send('menu:command', cmd), Math.min(1200 + i * 800, delay - 400))
  })
  setTimeout(() => {
    void win?.webContents
      .capturePage()
      .then((img) => fs.writeFile(target, img.toPNG()))
      .catch(() => undefined)
      .finally(() => app.quit())
  }, delay)
}

/** Menu accelerators just forward a command id; the renderer owns the commands. */
function buildMenu(): void {
  const cmd = (id: string) => () => send('menu:command', id)
  const isMac = process.platform === 'darwin'
  const template: Electron.MenuItemConstructorOptions[] = [
    ...(isMac ? [{ role: 'appMenu' as const }] : []),
    {
      label: 'File',
      submenu: [
        { label: 'New note', accelerator: 'CmdOrCtrl+N', click: cmd('file:new') },
        { label: 'New folder', click: cmd('file:new-folder') },
        { label: 'Open vault…', accelerator: 'CmdOrCtrl+Shift+O', click: cmd('vault:open') },
        { type: 'separator' },
        { label: 'Save', accelerator: 'CmdOrCtrl+S', click: cmd('file:save') },
        { label: 'Close tab', accelerator: 'CmdOrCtrl+W', click: cmd('tab:close') },
        { type: 'separator' },
        isMac ? { role: 'close' as const } : { role: 'quit' as const },
      ],
    },
    { role: 'editMenu' },
    {
      label: 'View',
      submenu: [
        { label: 'Command palette', accelerator: 'CmdOrCtrl+P', click: cmd('palette:open') },
        { label: 'Quick switcher', accelerator: 'CmdOrCtrl+O', click: cmd('switcher:open') },
        { label: 'Search', accelerator: 'CmdOrCtrl+Shift+F', click: cmd('search:open') },
        { type: 'separator' },
        { label: 'Graph view', accelerator: 'CmdOrCtrl+G', click: cmd('graph:open') },
        { label: 'Local graph', accelerator: 'CmdOrCtrl+Shift+G', click: cmd('graph:local') },
        { label: 'Canvas', click: cmd('canvas:new') },
        { type: 'separator' },
        { label: 'Toggle left sidebar', accelerator: 'CmdOrCtrl+B', click: cmd('sidebar:left') },
        { label: 'Toggle right sidebar', accelerator: 'CmdOrCtrl+Alt+B', click: cmd('sidebar:right') },
        { label: 'Toggle reading view', accelerator: 'CmdOrCtrl+E', click: cmd('editor:toggle-mode') },
        { type: 'separator' },
        { role: 'reload' },
        { role: 'toggleDevTools' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { role: 'togglefullscreen' },
      ],
    },
    { role: 'windowMenu' },
    {
      role: 'help',
      submenu: [
        { label: 'Onyx help', click: () => void shell.openExternal('https://github.com/') },
        { label: 'Settings', accelerator: 'CmdOrCtrl+,', click: cmd('settings:open') },
      ],
    },
  ]
  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

// ----------------------------------------------------------------- vault

async function openVault(root: string): Promise<AppSettings['lastVault']> {
  await vault?.close()
  vault = new Vault(root)
  await fs.mkdir(root, { recursive: true })
  await vault.load()
  vault.watch()
  vault.on('change', (kind, rel) => send('vault:changed', kind, rel))
  vault.on('settled', () => send('vault:settled'))
  rag = new RagIndex(vault)
  await rag.load(settings.get().ai.embedModel)
  settings.rememberVault(root)
  return root
}

function requireVault(): Vault {
  if (!vault) throw new Error('no vault is open')
  return vault
}

/** Reject any renderer-supplied path that escapes the vault. */
function safeRel(rel: string): string {
  const v = requireVault()
  const abs = path.resolve(v.root, rel)
  if (!v.contains(abs)) throw new Error(`path outside the vault: ${rel}`)
  return v.rel(abs)
}

// ------------------------------------------------------------------- IPC

function registerIpc(): void {
  ipcMain.handle('app:info', () => ({
    platform: process.platform,
    version: app.getVersion(),
    dark: nativeTheme.shouldUseDarkColors,
  }))

  ipcMain.handle('settings:get', () => settings.get())
  ipcMain.handle('settings:set', (_e, patch: Partial<AppSettings>) => settings.update(patch))

  ipcMain.handle('vault:current', () =>
    vault ? { root: vault.root, name: vault.name } : null,
  )

  ipcMain.handle('vault:pick', async () => {
    const res = await dialog.showOpenDialog({
      title: 'Open vault',
      properties: ['openDirectory', 'createDirectory'],
    })
    if (res.canceled || !res.filePaths[0]) return null
    await openVault(res.filePaths[0])
    return { root: vault!.root, name: vault!.name }
  })

  ipcMain.handle('vault:open', async (_e, root: string) => {
    await openVault(root)
    return { root: vault!.root, name: vault!.name }
  })

  ipcMain.handle('vault:snapshot', () => {
    const v = requireVault()
    return {
      root: v.root,
      name: v.name,
      tree: v.tree(),
      notes: [...v.notes.values()],
      attachments: [...v.files],
    }
  })

  ipcMain.handle('vault:graph', () => requireVault().graph())
  ipcMain.handle('vault:tags', () => requireVault().tags())
  ipcMain.handle('vault:backlinks', (_e, rel: string) => {
    const v = requireVault()
    return v.backlinks(safeRel(rel)).map((p) => ({ path: p, title: v.notes.get(p)?.title ?? p }))
  })
  ipcMain.handle('vault:resolve', (_e, target: string, from?: string) =>
    requireVault().resolve(target, from),
  )
  ipcMain.handle('vault:resolve-file', (_e, target: string) => requireVault().resolveFile(target))

  ipcMain.handle('file:read', (_e, rel: string) => requireVault().read(safeRel(rel)))
  ipcMain.handle('file:read-binary', async (_e, rel: string) => {
    const v = requireVault()
    const buf = await fs.readFile(v.abs(safeRel(rel)))
    return buf.toString('base64')
  })
  ipcMain.handle('file:write', (_e, rel: string, content: string) =>
    requireVault().write(safeRel(rel), content),
  )
  ipcMain.handle('file:create', async (_e, rel: string, content: string) => {
    const v = requireVault()
    const target = safeRel(rel)
    await v.create(target, content)
    return target
  })
  ipcMain.handle('file:mkdir', (_e, rel: string) => requireVault().mkdir(safeRel(rel)))
  ipcMain.handle('file:rename', (_e, from: string, to: string) =>
    requireVault().rename(safeRel(from), safeRel(to)),
  )
  ipcMain.handle('file:delete', (_e, rel: string) =>
    requireVault().remove(safeRel(rel), async (abs) => {
      const err = await shell.trashItem(abs).then(
        () => null,
        (e: Error) => e,
      )
      if (err) await fs.rm(abs, { recursive: true, force: true })
    }),
  )
  ipcMain.handle('file:exists', async (_e, rel: string) => {
    try {
      await fs.access(requireVault().abs(safeRel(rel)))
      return true
    } catch {
      return false
    }
  })
  ipcMain.handle('file:reveal', (_e, rel: string) => {
    shell.showItemInFolder(requireVault().abs(safeRel(rel)))
  })
  ipcMain.handle('file:open-external', (_e, rel: string) =>
    shell.openPath(requireVault().abs(safeRel(rel))),
  )
  ipcMain.handle('url:open', (_e, url: string) => {
    if (/^https?:\/\//i.test(url)) return shell.openExternal(url)
    return null
  })

  ipcMain.handle('search:query', (_e, q: string) => search(requireVault(), q))
  ipcMain.handle('search:unlinked', (_e, rel: string) =>
    unlinkedMentions(requireVault(), safeRel(rel)),
  )

  // ------------------------------------------------------------------ AI

  ipcMain.handle('ai:models', () => listModels(settings.get().ai.host))

  ipcMain.handle(
    'ai:chat',
    async (
      _e,
      id: string,
      messages: ChatMessage[],
      opts: { notePath?: string; model?: string } = {},
    ) => {
      const cfg = settings.get().ai
      const ctrl = new AbortController()
      aiStreams.set(id, ctrl)
      const full: ChatMessage[] = [{ role: 'system', content: ONYX_SYSTEM_PROMPT }]
      if (opts.notePath && vault) {
        try {
          full.push(contextMessage(opts.notePath, await vault.read(safeRel(opts.notePath))))
        } catch {
          /* note vanished — carry on without context */
        }
      }
      full.push(...messages)
      try {
        await chatStream(cfg.host, opts.model ?? cfg.model, full, ctrl.signal, (c) =>
          send('ai:chunk', id, c),
        )
        send('ai:done', id, null)
      } catch (e) {
        send('ai:done', id, (e as Error).message)
      } finally {
        aiStreams.delete(id)
      }
    },
  )

  ipcMain.handle('ai:cancel', (_e, id: string) => {
    aiStreams.get(id)?.abort()
    aiStreams.delete(id)
  })

  ipcMain.handle('ai:summarize', async (_e, id: string, rel: string) => {
    const cfg = settings.get().ai
    const content = await requireVault().read(safeRel(rel))
    const ctrl = new AbortController()
    aiStreams.set(id, ctrl)
    try {
      await chatStream(cfg.host, cfg.model, summarizePrompt(content), ctrl.signal, (c) =>
        send('ai:chunk', id, c),
      )
      send('ai:done', id, null)
    } catch (e) {
      send('ai:done', id, (e as Error).message)
    } finally {
      aiStreams.delete(id)
    }
  })

  ipcMain.handle('ai:rewrite', async (_e, selection: string, instruction: string) => {
    const cfg = settings.get().ai
    const ctrl = new AbortController()
    let out = ''
    await chatStream(cfg.host, cfg.model, rewritePrompt(selection, instruction), ctrl.signal, (c) => {
      out += c.content
    })
    return out.trim()
  })

  ipcMain.handle('ai:rag-build', async (_e, id: string) => {
    const cfg = settings.get().ai
    const index = rag ?? (rag = new RagIndex(requireVault()))
    await index.load(cfg.embedModel)
    return index.build(cfg.host, cfg.embedModel, (done, total) =>
      send('ai:progress', id, { done, total }),
    )
  })

  ipcMain.handle('ai:ask', async (_e, id: string, question: string) => {
    const cfg = settings.get().ai
    const index = rag ?? (rag = new RagIndex(requireVault()))
    if (!index.size) await index.load(cfg.embedModel)
    const hits = await index.query(cfg.host, cfg.embedModel, question)
    send('ai:sources', id, hits)
    const ctrl = new AbortController()
    aiStreams.set(id, ctrl)
    try {
      await chatStream(cfg.host, cfg.model, askPrompt(question, hits), ctrl.signal, (c) =>
        send('ai:chunk', id, c),
      )
      send('ai:done', id, null)
    } catch (e) {
      send('ai:done', id, (e as Error).message)
    } finally {
      aiStreams.delete(id)
    }
    return hits
  })

  ipcMain.handle('ai:complete', async (_e, before: string, after: string) => {
    const cfg = settings.get().ai
    if (!cfg.autocomplete) return ''
    const ctrl = new AbortController()
    // Ghost text must never outlive the keystroke that asked for it.
    const timer = setTimeout(() => ctrl.abort(), 8000)
    try {
      const out = await generate(
        cfg.host,
        cfg.completionModel,
        completionPrompt(before, after),
        ctrl.signal,
        { temperature: 0.2, num_predict: 48, stop: ['\n\n'] },
      )
      return out.replace(/^["'`]+|["'`]+$/g, '').trimEnd()
    } catch {
      return ''
    } finally {
      clearTimeout(timer)
    }
  })
}

// ------------------------------------------------------------------ boot

void app.whenReady().then(async () => {
  await settings.load()
  registerIpc()
  buildMenu()

  const start = settings.get().lastVault ?? defaultVaultPath()
  try {
    await openVault(start)
  } catch {
    /* the renderer shows the vault picker */
  }

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', async () => {
  await settings.flush()
  await vault?.close()
})

export { isMarkdown }
