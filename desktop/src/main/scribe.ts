/**
 * Scribe, the pen-first notebook app, inside Electron's window (macOS).
 *
 * Scribe's SwiftUI interface is built from ../scribe into libScribeEmbed.dylib
 * and staged, with the addon that loads it (native/scribe-bridge), by
 * scripts/build-scribe.sh. The addon lays Scribe's view over the web
 * contents; switching apps shows or hides that view, moves keyboard focus,
 * and swaps the menu bar for the app on screen.
 *
 * On Linux and Windows, or in a build without Scribe staged, `available` is
 * false and the app behaves exactly as before.
 */

import { app, BrowserWindow, Menu } from 'electron'
import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import * as path from 'node:path'

import { isPackaged } from './packaged.js'
import { scribeQuery } from '../shared/scribe-query.js'
import { parseScribeTarget } from '../shared/scribe-link.js'
import type { ScribeHit, ScribePage } from '../shared/types.js'

export type AppId = 'electron' | 'scribe'

interface Bridge {
  load(dylib: string): void
  attach(handle: Buffer, hostName: string, hostIcon: string, scribeIcon: string): void
  setVisible(visible: boolean): void
  perform(action: string): boolean
  menu(): string
  onSwitch(fn: () => void): void
  snapshot(png: string): boolean
  search(query: string): string
  open(pagePath: string): void
  links(): string
  onLinksChanged(fn: () => void): void
  openLink(pageId: string, x: number, y: number, width: number, height: number): void
  setVault(path: string): void
  onOpenNote(fn: (rel: string) => void): void
}

/** One entry of Scribe's menu JSON (see scribe/macos/Scribe/App/ScribeMenu.swift). */
interface MenuSpec {
  id?: string
  label?: string
  accelerator?: string
  role?: string
  type?: string
  submenu?: MenuSpec[]
}

/** Where build-scribe.sh staged Scribe: inside the app when packaged, desktop/scribe-embed in dev. */
function stageDir(): string {
  return isPackaged
    ? path.join(process.resourcesPath, 'scribe')
    : path.join(app.getAppPath(), 'scribe-embed')
}

let bridge: Bridge | null = null
let current: AppId = 'electron'
let host: BrowserWindow | null = null
let menus: Record<AppId, () => Electron.Menu> | null = null
let changed: (id: AppId) => void = () => {}
let pages: ScribePage[] = []
let pagesChanged: () => void = () => {}

/**
 * Load Scribe if it's here. `electronMenu` builds Electron's own menu bar;
 * `onChange` hears every switch (to tell the renderer and remember it).
 * Returns why Scribe isn't available, or null when it is.
 */
export function initScribe(options: {
  electronMenu: () => Electron.Menu
  onChange: (id: AppId) => void
  /** Scribe's pages or the links on them changed (see scribePages). */
  onPagesChanged: () => void
  /** A note in a Scribe page's "Linked from" list was picked. */
  onOpenNote: (rel: string) => void
}): string | null {
  changed = options.onChange
  pagesChanged = options.onPagesChanged
  menus = { electron: options.electronMenu, scribe: scribeMenu }
  if (process.platform !== 'darwin') return 'Scribe is macOS-only'
  const dir = stageDir()
  const addon = path.join(dir, 'scribe_bridge.node')
  const dylib = path.join(dir, 'libScribeEmbed.dylib')
  if (!existsSync(addon) || !existsSync(dylib)) return `Scribe isn't built (run scripts/build-scribe.sh)`
  try {
    const loaded = createRequire(import.meta.url)(addon) as Bridge
    loaded.load(dylib)
    loaded.onSwitch(() => switchApp('electron'))
    loaded.onLinksChanged(() => {
      if (readPages()) pagesChanged()
    })
    loaded.onOpenNote((rel) => {
      switchApp('electron')
      options.onOpenNote(rel)
    })
    bridge = loaded
    readPages()
    return null
  } catch (err) {
    return `Scribe failed to load: ${(err as Error).message}`
  }
}

export function scribeAvailable(): boolean {
  return bridge !== null
}

export function currentApp(): AppId {
  return current
}

/**
 * Put Scribe's view (hidden unless it's the current app) into `window`.
 * Called for every new window: macOS re-creates it after the last one closes.
 */
export function attachScribe(window: BrowserWindow, hostIcon: string): void {
  host = window
  if (!bridge) return
  bridge.attach(window.getNativeWindowHandle(), 'Electron', hostIcon, path.join(stageDir(), 'scribe-icon.png'))
  // Scribe's layout needs this much room before its panels fold away.
  window.setMinimumSize(760, 560)
  if (current === 'scribe') bridge.setVisible(true)
}

/** Show `id`'s interface, with its menu bar and the keyboard. */
export function switchApp(id: AppId): void {
  if (id === current || (id === 'scribe' && !bridge)) return
  current = id
  bridge?.setVisible(id === 'scribe')
  if (id === 'electron' && host && !host.isDestroyed()) host.webContents.focus()
  applyMenu()
  changed(id)
}

/** Rebuild the menu bar for whichever app is on screen. */
export function applyMenu(): void {
  if (menus) Menu.setApplicationMenu(menus[current]())
}

/**
 * The Window menu both apps share: switch between them (⌃⌘1 / ⌃⌘2), then
 * the usual window items. Only offered when Scribe is available.
 */
export function windowMenu(): Electron.MenuItemConstructorOptions {
  if (!bridge) return { role: 'windowMenu' }
  return {
    label: 'Window',
    submenu: [
      { role: 'minimize' },
      { role: 'zoom' },
      { type: 'separator' },
      {
        label: 'Electron',
        type: 'checkbox',
        checked: current === 'electron',
        accelerator: 'Ctrl+Cmd+1',
        click: () => switchApp('electron'),
      },
      {
        label: 'Scribe',
        type: 'checkbox',
        checked: current === 'scribe',
        accelerator: 'Ctrl+Cmd+2',
        click: () => switchApp('scribe'),
      },
      { type: 'separator' },
      { role: 'front' },
    ],
  }
}

/** Scribe's own menus, from its JSON, framed by the app and Window menus. */
function scribeMenu(): Electron.Menu {
  const specs = JSON.parse(bridge!.menu()) as MenuSpec[]
  const toItem = (spec: MenuSpec): Electron.MenuItemConstructorOptions => {
    if (spec.type === 'separator') return { type: 'separator' }
    if (spec.role) return { role: spec.role as Electron.MenuItemConstructorOptions['role'] }
    if (spec.submenu) return { label: spec.label, submenu: spec.submenu.map(toItem) }
    const action = spec.id!
    return { label: spec.label, accelerator: spec.accelerator, click: () => bridge?.perform(action) }
  }
  const scribeMenus = specs.map(toItem)
  // Scribe's File menu, like the standalone app's, ends with Close (⌘W).
  const file = scribeMenus.find((m) => m.label === 'File')
  if (file && Array.isArray(file.submenu)) file.submenu.push({ type: 'separator' }, { role: 'close' })
  return Menu.buildFromTemplate([{ role: 'appMenu' }, ...scribeMenus, windowMenu()])
}

/**
 * Scribe pages matching `query`: titles, typed text, tables and handwriting.
 * Queries using Electron's search operators skip Scribe (see scribeQuery).
 */
export function searchScribe(query: string): ScribeHit[] {
  const q = scribeQuery(query)
  if (!bridge || !q) return []
  try {
    return JSON.parse(bridge.search(q)) as ScribeHit[]
  } catch {
    return []
  }
}

/** Open one of Scribe's pages and show Scribe. */
export function openScribePage(pagePath: string): void {
  if (!bridge || !host) return
  bridge.open(pagePath)
  switchApp('scribe')
}

/**
 * Every Scribe page with its id and the links typed on it, as last read.
 * Reading happens in Scribe's background; when it finds a change,
 * onPagesChanged fires and this has the new list.
 */
export function scribePages(): ScribePage[] {
  return pages
}

let pagesJson = '[]'

/** Reads the index as Scribe last read it; true if it differs from before. */
function readPages(): boolean {
  const json = bridge?.links() ?? '[]'
  if (json === pagesJson) return false
  pagesJson = json
  try {
    pages = JSON.parse(json) as ScribePage[]
  } catch {
    pages = []
  }
  return true
}

/** Ask Scribe to read its pages again (e.g. after it was on screen). */
export function refreshScribePages(): void {
  readPages()
}

/**
 * Open the page a `scribe:` link target names and show Scribe; a link to an
 * area zooms to it. False when it isn't a Scribe link or Scribe isn't here.
 */
export function openScribeLink(target: string): boolean {
  const link = parseScribeTarget(target)
  if (!bridge || !host || !link) return false
  const a = link.area
  bridge.openLink(link.pageId, a?.x ?? 0, a?.y ?? 0, a?.width ?? 0, a?.height ?? 0)
  switchApp('scribe')
  return true
}

/** Tell Scribe where the vault is, so a page can list the notes linking to it. */
export function setScribeVault(root: string): void {
  bridge?.setVault(root)
}

/** Render Scribe's view to a PNG (capturePage only sees the web layer under it). */
export function snapshotScribe(png: string): boolean {
  return bridge?.snapshot(png) ?? false
}
