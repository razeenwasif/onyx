/**
 * The only bridge between the renderer and Node. Everything the UI can do to
 * the filesystem is enumerated here; the main process re-validates every path.
 */

import { contextBridge, ipcRenderer } from 'electron'
import type {
  AppSettings,
  Backlink,
  GraphData,
  NoteMeta,
  SearchHit,
  VaultSnapshot,
} from '../shared/types.js'

type Unsubscribe = () => void

function on(channel: string, fn: (...args: any[]) => void): Unsubscribe {
  const listener = (_e: Electron.IpcRendererEvent, ...args: any[]): void => fn(...args)
  ipcRenderer.on(channel, listener)
  return () => ipcRenderer.removeListener(channel, listener)
}

export const api = {
  app: {
    info: (): Promise<{ platform: string; version: string; dark: boolean }> =>
      ipcRenderer.invoke('app:info'),
    onMenuCommand: (fn: (id: string) => void): Unsubscribe => on('menu:command', fn),
  },

  settings: {
    get: (): Promise<AppSettings> => ipcRenderer.invoke('settings:get'),
    set: (patch: Partial<AppSettings>): Promise<AppSettings> =>
      ipcRenderer.invoke('settings:set', patch),
  },

  vault: {
    current: (): Promise<{ root: string; name: string } | null> =>
      ipcRenderer.invoke('vault:current'),
    pick: (): Promise<{ root: string; name: string } | null> => ipcRenderer.invoke('vault:pick'),
    open: (root: string): Promise<{ root: string; name: string }> =>
      ipcRenderer.invoke('vault:open', root),
    snapshot: (): Promise<VaultSnapshot> => ipcRenderer.invoke('vault:snapshot'),
    graph: (): Promise<GraphData> => ipcRenderer.invoke('vault:graph'),
    tags: (): Promise<Array<{ tag: string; count: number }>> => ipcRenderer.invoke('vault:tags'),
    backlinks: (rel: string): Promise<Array<{ path: string; title: string }>> =>
      ipcRenderer.invoke('vault:backlinks', rel),
    resolve: (target: string, from?: string): Promise<string | null> =>
      ipcRenderer.invoke('vault:resolve', target, from),
    resolveFile: (target: string): Promise<string | null> =>
      ipcRenderer.invoke('vault:resolve-file', target),
    onChanged: (fn: (kind: 'add' | 'change' | 'unlink', rel: string) => void): Unsubscribe =>
      on('vault:changed', fn),
    onSettled: (fn: () => void): Unsubscribe => on('vault:settled', fn),
  },

  file: {
    read: (rel: string): Promise<string> => ipcRenderer.invoke('file:read', rel),
    readBinary: (rel: string): Promise<string> => ipcRenderer.invoke('file:read-binary', rel),
    write: (rel: string, content: string): Promise<NoteMeta | null> =>
      ipcRenderer.invoke('file:write', rel, content),
    create: (rel: string, content = ''): Promise<string> =>
      ipcRenderer.invoke('file:create', rel, content),
    mkdir: (rel: string): Promise<void> => ipcRenderer.invoke('file:mkdir', rel),
    rename: (from: string, to: string): Promise<string[]> =>
      ipcRenderer.invoke('file:rename', from, to),
    remove: (rel: string): Promise<void> => ipcRenderer.invoke('file:delete', rel),
    exists: (rel: string): Promise<boolean> => ipcRenderer.invoke('file:exists', rel),
    reveal: (rel: string): Promise<void> => ipcRenderer.invoke('file:reveal', rel),
    openExternal: (rel: string): Promise<string> => ipcRenderer.invoke('file:open-external', rel),
  },

  url: {
    open: (url: string): Promise<void> => ipcRenderer.invoke('url:open', url),
  },

  search: {
    query: (q: string): Promise<SearchHit[]> => ipcRenderer.invoke('search:query', q),
    unlinked: (rel: string): Promise<Backlink[]> => ipcRenderer.invoke('search:unlinked', rel),
  },

  ai: {
    models: (): Promise<string[]> => ipcRenderer.invoke('ai:models'),
    chat: (
      id: string,
      messages: Array<{ role: string; content: string }>,
      opts?: { notePath?: string; model?: string },
    ): Promise<void> => ipcRenderer.invoke('ai:chat', id, messages, opts ?? {}),
    summarize: (id: string, rel: string): Promise<void> =>
      ipcRenderer.invoke('ai:summarize', id, rel),
    rewrite: (selection: string, instruction: string): Promise<string> =>
      ipcRenderer.invoke('ai:rewrite', selection, instruction),
    ask: (id: string, question: string): Promise<unknown> => ipcRenderer.invoke('ai:ask', id, question),
    buildRag: (id: string): Promise<{ embedded: number; total: number }> =>
      ipcRenderer.invoke('ai:rag-build', id),
    complete: (before: string, after: string): Promise<string> =>
      ipcRenderer.invoke('ai:complete', before, after),
    cancel: (id: string): Promise<void> => ipcRenderer.invoke('ai:cancel', id),
    onChunk: (
      fn: (id: string, chunk: { content: string; thinking: string; done: boolean }) => void,
    ): Unsubscribe => on('ai:chunk', fn),
    onDone: (fn: (id: string, error: string | null) => void): Unsubscribe => on('ai:done', fn),
    onSources: (fn: (id: string, hits: unknown[]) => void): Unsubscribe => on('ai:sources', fn),
    onProgress: (fn: (id: string, p: { done: number; total: number }) => void): Unsubscribe =>
      on('ai:progress', fn),
  },
}

export type OnyxApi = typeof api

contextBridge.exposeInMainWorld('onyx', api)
