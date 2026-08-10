/**
 * The vault: an on-disk folder of markdown notes, plus the in-memory index of
 * links, tags, backlinks and properties built over it.
 *
 * Port of `src/vault/*.rs` + `src/vault/index.rs`. The renderer never touches
 * the filesystem; everything goes through here over IPC.
 */

import { promises as fs, Stats } from 'node:fs'
import * as fsSync from 'node:fs'
import * as path from 'node:path'
import * as os from 'node:os'
import { EventEmitter } from 'node:events'
import chokidar, { FSWatcher } from 'chokidar'

import type { FileNode, GraphData, GraphLink, GraphNode, NoteMeta } from '../shared/types.js'
import {
  extractAllTags,
  extractFrontmatterAliases,
  extractFrontmatterProperties,
  extractLinks,
  extractMdLinks,
  firstHeading,
  noteName,
  wordCount,
} from '../shared/parse.js'

export const MARKDOWN_EXTS = new Set(['md', 'markdown', 'mdx'])
export const IMAGE_EXTS = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'avif'])
export const CANVAS_EXT = 'canvas'
/** Folders never scanned (matches the TUI's ignore rules plus VCS noise). */
const IGNORED_DIRS = new Set(['.git', '.obsidian', '.onyx', '.trash', 'node_modules', '.svn', '.hg'])

export function toPosix(p: string): string {
  return p.split(path.sep).join('/')
}

export function extOf(p: string): string {
  const e = path.extname(p)
  return e ? e.slice(1).toLowerCase() : ''
}

export function isMarkdown(p: string): boolean {
  return MARKDOWN_EXTS.has(extOf(p))
}

/** `Folder/Note.md` → `folder/note` (the key used for relpath resolution). */
function relKey(rel: string): string {
  const e = extOf(rel)
  const stem = MARKDOWN_EXTS.has(e) ? rel.slice(0, rel.length - e.length - 1) : rel
  return stem.toLowerCase()
}

function baseKey(rel: string): string {
  return path.basename(relKey(rel))
}

export interface VaultEvents {
  /** A note's content or metadata changed (index already updated). */
  change: (kind: 'add' | 'change' | 'unlink', relPath: string) => void
  /** Batched: the tree or index settled after a burst of changes. */
  settled: () => void
}

/**
 * Note text kept in memory for bulk scans (search, unlinked mentions).
 *
 * Re-reading 1000+ notes per query costs ~20ms on a local disk and *twelve
 * seconds* over a WSL 9P mount, so the scanners read through this cache while
 * single-file reads still go to disk (see `read` vs `cachedContent`).
 */
const CONTENT_BUDGET_BYTES = 96 * 1024 * 1024
/** Don't spend the budget on one enormous file. */
const CONTENT_MAX_FILE_BYTES = 2 * 1024 * 1024

/** Filesystems where inotify/ReadDirectoryChangesW don't deliver events. */
const NETWORK_FSTYPES = new Set([
  '9p',
  'drvfs',
  'cifs',
  'smb3',
  'nfs',
  'nfs4',
  'fuse.sshfs',
  'fuse.rclone',
  'virtiofs',
  'vboxsf',
])

export type WatchMode = 'native' | 'polling'

/**
 * True when `root` lives on a filesystem that won't deliver change events.
 * On Windows that's any UNC path; on Linux we look the mount point up in
 * /proc/mounts, which catches `/mnt/c` (drvfs) and network shares.
 */
export function isNetworkPath(root: string): boolean {
  if (process.platform === 'win32') return /^\\\\/.test(root)
  try {
    const mounts = fsSync.readFileSync('/proc/mounts', 'utf8')
    let best = ''
    let bestType = ''
    for (const line of mounts.split('\n')) {
      const [, mountPoint, fstype] = line.split(' ')
      if (!mountPoint || !fstype) continue
      const point = mountPoint.replace(/\\040/g, ' ')
      if ((root === point || root.startsWith(point.endsWith('/') ? point : `${point}/`)) &&
        point.length > best.length) {
        best = point
        bestType = fstype
      }
    }
    return NETWORK_FSTYPES.has(bestType)
  } catch {
    return false
  }
}

export class Vault extends EventEmitter {
  readonly root: string
  readonly name: string

  /** vault-relative path → metadata. */
  notes = new Map<string, NoteMeta>()
  /** Non-markdown files (attachments, canvases), vault-relative. */
  files = new Set<string>()

  /** How the watcher is running, for the status bar. */
  watchMode: WatchMode = 'native'

  private contents = new Map<string, string>()
  private contentBytes = 0

  private byBasename = new Map<string, string[]>()
  private byRelpath = new Map<string, string>()
  private byAlias = new Map<string, string[]>()
  private backlinksMap = new Map<string, Set<string>>()
  private byTagMap = new Map<string, Set<string>>()

  private watcher: FSWatcher | null = null
  private settleTimer: NodeJS.Timeout | null = null

  constructor(root: string) {
    super()
    this.root = path.resolve(root)
    this.name = path.basename(this.root) || this.root
  }

  abs(rel: string): string {
    return path.join(this.root, rel)
  }

  rel(abs: string): string {
    return toPosix(path.relative(this.root, abs))
  }

  /** True when `abs` is inside the vault (blocks `..` traversal over IPC). */
  contains(abs: string): boolean {
    const r = path.relative(this.root, path.resolve(abs))
    return r === '' || (!r.startsWith('..') && !path.isAbsolute(r))
  }

  // ------------------------------------------------------------- scanning

  async load(): Promise<void> {
    this.notes.clear()
    this.files.clear()
    this.contents.clear()
    this.contentBytes = 0
    const found: string[] = []
    await this.walk(this.root, found)
    for (const rel of found) {
      if (isMarkdown(rel)) {
        try {
          const content = await fs.readFile(this.abs(rel), 'utf8')
          const st = await fs.stat(this.abs(rel))
          this.notes.set(rel, parseNote(rel, content, st))
          this.cacheContent(rel, content)
        } catch {
          /* unreadable — skip */
        }
      } else {
        this.files.add(rel)
      }
    }
    this.reindex()
  }

  // -------------------------------------------------------- content cache

  private cacheContent(rel: string, content: string): void {
    const size = content.length
    if (size > CONTENT_MAX_FILE_BYTES) {
      this.dropContent(rel)
      return
    }
    const previous = this.contents.get(rel)
    if (previous !== undefined) this.contentBytes -= previous.length
    if (this.contentBytes + size > CONTENT_BUDGET_BYTES) {
      // Over budget: keep what's already cached rather than thrashing.
      if (previous !== undefined) this.contents.delete(rel)
      return
    }
    this.contents.set(rel, content)
    this.contentBytes += size
  }

  private dropContent(rel: string): void {
    const previous = this.contents.get(rel)
    if (previous === undefined) return
    this.contentBytes -= previous.length
    this.contents.delete(rel)
  }

  /**
   * Note text for a bulk scan. Served from memory when possible — this is what
   * keeps full-vault search fast on a slow filesystem. Single-file reads that
   * the user can see (opening a note) go through `read` instead, which always
   * hits the disk.
   */
  async cachedContent(rel: string): Promise<string> {
    const hit = this.contents.get(rel)
    if (hit !== undefined) return hit
    const content = await fs.readFile(this.abs(rel), 'utf8')
    this.cacheContent(rel, content)
    return content
  }

  /** Bytes currently held in the content cache (for diagnostics). */
  get cachedBytes(): number {
    return this.contentBytes
  }

  private async walk(dir: string, out: string[]): Promise<void> {
    let entries: fsSync.Dirent[]
    try {
      entries = await fs.readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const e of entries) {
      if (e.name.startsWith('.') && e.name !== '.') {
        if (IGNORED_DIRS.has(e.name)) continue
        if (e.isDirectory()) continue
      }
      const full = path.join(dir, e.name)
      if (e.isDirectory()) {
        if (IGNORED_DIRS.has(e.name)) continue
        await this.walk(full, out)
      } else if (e.isFile()) {
        out.push(this.rel(full))
      }
    }
  }

  /** Rebuild every derived map from `notes`. */
  private reindex(): void {
    this.byBasename.clear()
    this.byRelpath.clear()
    this.byAlias.clear()
    this.byTagMap.clear()

    for (const rel of this.notes.keys()) {
      const bk = baseKey(rel)
      const list = this.byBasename.get(bk)
      if (list) list.push(rel)
      else this.byBasename.set(bk, [rel])
      this.byRelpath.set(relKey(rel), rel)
    }
    for (const [rel, meta] of this.notes) {
      for (const a of meta.aliases) {
        const k = a.toLowerCase()
        const list = this.byAlias.get(k)
        if (list) list.push(rel)
        else this.byAlias.set(k, [rel])
      }
      for (const t of meta.tags) {
        let s = this.byTagMap.get(t)
        if (!s) this.byTagMap.set(t, (s = new Set()))
        s.add(rel)
      }
    }
    this.recomputeLinks()
  }

  /** Resolve every note's raw targets and rebuild the backlink map. */
  private recomputeLinks(): void {
    this.backlinksMap.clear()
    for (const [rel, meta] of this.notes) {
      const outgoing: string[] = []
      const unresolved: string[] = []
      for (const raw of meta.targets) {
        const hit = this.resolve(raw, rel)
        if (hit) {
          if (!outgoing.includes(hit)) outgoing.push(hit)
        } else if (!unresolved.includes(raw)) {
          unresolved.push(raw)
        }
      }
      meta.outgoing = outgoing
      meta.unresolved = unresolved
      for (const target of outgoing) {
        let s = this.backlinksMap.get(target)
        if (!s) this.backlinksMap.set(target, (s = new Set()))
        s.add(rel)
      }
    }
  }

  /**
   * Resolve a link target to a note path, Obsidian-style.
   *
   * A *path-qualified* target (`Projects/Roadmap`) resolves by exact relative
   * path. A *bare* name resolves to the nearest match: the linking note's own
   * folder first, then the shallowest path, then an alias — so `[[Onyx]]` from
   * `Projects/Roadmap.md` finds `Projects/Onyx.md` rather than the one at the
   * vault root. Checking the exact relpath first would always hand back the
   * root note, which is not how Obsidian behaves.
   */
  resolve(target: string, from?: string): string | null {
    const name = noteName(target).trim()
    if (!name) return null
    const key = name.toLowerCase().replace(/^\.\//, '')

    if (key.includes('/')) {
      const exact = this.byRelpath.get(key)
      if (exact) return exact
    }

    const candidates = this.byBasename.get(path.basename(key))
    if (candidates && candidates.length) {
      if (candidates.length === 1) return candidates[0]
      if (from) {
        const dir = path.posix.dirname(from)
        const sameFolder = candidates.find((c) => path.posix.dirname(c) === dir)
        if (sameFolder) return sameFolder
      }
      // Shallowest, then alphabetical — deterministic.
      return [...candidates].sort((a, b) => {
        const da = a.split('/').length
        const db = b.split('/').length
        return da !== db ? da - db : a.localeCompare(b)
      })[0]
    }

    // A bare name that matched no basename may still be a relpath (a folder
    // named like a note), so fall back to the exact lookup here.
    const exact = this.byRelpath.get(key)
    if (exact) return exact

    const aliased = this.byAlias.get(key)
    if (aliased && aliased.length) return aliased[0]

    return null
  }

  /** Attachment lookup for `![[image.png]]` / `[](image.png)`. */
  resolveFile(target: string): string | null {
    const key = target.toLowerCase().replace(/^\.\//, '')
    for (const f of this.files) {
      if (f.toLowerCase() === key) return f
    }
    const base = path.basename(key)
    for (const f of this.files) {
      if (path.basename(f).toLowerCase() === base) return f
    }
    return null
  }

  backlinks(rel: string): string[] {
    return [...(this.backlinksMap.get(rel) ?? [])].sort()
  }

  tags(): Array<{ tag: string; count: number }> {
    return [...this.byTagMap.entries()]
      .map(([tag, set]) => ({ tag, count: set.size }))
      .sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag))
  }

  notesWithTag(tag: string): string[] {
    return [...(this.byTagMap.get(tag) ?? [])].sort()
  }

  // ------------------------------------------------------------ file tree

  tree(): FileNode {
    const root: FileNode = { path: '', name: this.name, isDir: true, children: [] }
    const dirs = new Map<string, FileNode>([['', root]])

    const ensureDir = (rel: string): FileNode => {
      const existing = dirs.get(rel)
      if (existing) return existing
      const parent = ensureDir(path.posix.dirname(rel) === '.' ? '' : path.posix.dirname(rel))
      const node: FileNode = { path: rel, name: path.posix.basename(rel), isDir: true, children: [] }
      parent.children!.push(node)
      dirs.set(rel, node)
      return node
    }

    const all = [...this.notes.keys(), ...this.files]
    all.sort()
    for (const rel of all) {
      const dir = path.posix.dirname(rel)
      const parent = ensureDir(dir === '.' ? '' : dir)
      const meta = this.notes.get(rel)
      parent.children!.push({
        path: rel,
        name: path.posix.basename(rel),
        isDir: false,
        ext: extOf(rel),
        mtime: meta?.mtime,
      })
    }

    const sortNode = (n: FileNode): void => {
      if (!n.children) return
      n.children.sort((a, b) => {
        if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
        return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })
      })
      n.children.forEach(sortNode)
    }
    sortNode(root)
    return root
  }

  // ---------------------------------------------------------------- graph

  /**
   * The full graph. Unresolved links become phantom nodes and tags become tag
   * nodes so the renderer can toggle them without a round trip — filtering
   * happens client-side, exactly like Obsidian.
   */
  graph(): GraphData {
    const nodes: GraphNode[] = []
    const index = new Map<string, number>()

    const add = (id: string, node: Omit<GraphNode, 'degree'>): number => {
      const hit = index.get(id)
      if (hit !== undefined) return hit
      const i = nodes.length
      nodes.push({ ...node, degree: 0 })
      index.set(id, i)
      return i
    }

    for (const [rel, meta] of this.notes) {
      add(rel, {
        id: rel,
        // Graph labels are filenames, like Obsidian's — not the first heading.
        title: path.posix.basename(rel).replace(/\.[^.]+$/, ''),
        kind: 'note',
        folder: path.posix.dirname(rel) === '.' ? '' : path.posix.dirname(rel),
        tags: meta.tags,
      })
    }
    for (const f of this.files) {
      add(f, {
        id: f,
        title: path.posix.basename(f),
        kind: 'attachment',
        folder: path.posix.dirname(f) === '.' ? '' : path.posix.dirname(f),
        tags: [],
      })
    }

    const links: GraphLink[] = []
    const seen = new Set<string>()
    const pushLink = (a: number, b: number, kind: GraphLink['kind']): void => {
      if (a === b) return
      const key = `${a} ${b} ${kind}`
      if (seen.has(key)) return
      seen.add(key)
      links.push({ source: a, target: b, kind })
      nodes[a].degree++
      nodes[b].degree++
    }

    for (const [rel, meta] of this.notes) {
      const from = index.get(rel)!
      for (const target of meta.outgoing) {
        const to = index.get(target)
        if (to !== undefined) pushLink(from, to, 'link')
      }
      for (const raw of meta.unresolved) {
        const name = noteName(raw).trim()
        if (!name) continue
        // An unresolved target may still be an attachment or a phantom note.
        const file = this.resolveFile(name)
        if (file) {
          pushLink(from, index.get(file)!, 'attachment')
          continue
        }
        const id = `unresolved:${name.toLowerCase()}`
        const to = add(id, { id, title: name, kind: 'unresolved', folder: '', tags: [] })
        pushLink(from, to, 'link')
      }
      for (const tag of meta.tags) {
        const id = `tag:${tag}`
        const to = add(id, { id, title: `#${tag}`, kind: 'tag', folder: '', tags: [tag] })
        pushLink(from, to, 'tag')

        // Nested tags also get their ancestors as nodes, joined parent → child.
        // The renderer decides whether to show those edges (`linkNestedTags`);
        // emitting them here keeps the walk out of the render loop.
        const parts = tag.split('/')
        for (let i = parts.length - 1; i > 0; i--) {
          const childTag = parts.slice(0, i + 1).join('/')
          const parentTag = parts.slice(0, i).join('/')
          const childId = `tag:${childTag}`
          const parentId = `tag:${parentTag}`
          const childIdx = add(childId, {
            id: childId,
            title: `#${childTag}`,
            kind: 'tag',
            folder: '',
            tags: [childTag],
          })
          const parentIdx = add(parentId, {
            id: parentId,
            title: `#${parentTag}`,
            kind: 'tag',
            folder: '',
            tags: [parentTag],
          })
          pushLink(parentIdx, childIdx, 'tagParent')
        }
      }
    }

    return { nodes, links }
  }

  // ------------------------------------------------------------- mutation

  /**
   * Read a single file from disk. Deliberately *not* served from the content
   * cache: this backs opening a note, and it has to be correct even when the
   * watcher can't see external edits (network filesystems).
   */
  async read(rel: string): Promise<string> {
    const content = await fs.readFile(this.abs(rel), 'utf8')
    if (isMarkdown(rel)) this.cacheContent(rel, content)
    return content
  }

  /**
   * Crash-safe save: write a sibling temp file, fsync, then rename over the
   * target (mirrors the TUI's atomic saves).
   */
  async write(rel: string, content: string): Promise<NoteMeta | null> {
    const target = this.abs(rel)
    await fs.mkdir(path.dirname(target), { recursive: true })
    const tmp = path.join(path.dirname(target), `.${path.basename(target)}.onyx-tmp`)
    const handle = await fs.open(tmp, 'w')
    try {
      await handle.writeFile(content, 'utf8')
      await handle.sync()
    } finally {
      await handle.close()
    }
    await fs.rename(tmp, target)
    if (isMarkdown(rel)) {
      const st = await fs.stat(target)
      this.notes.set(rel, parseNote(rel, content, st))
      this.cacheContent(rel, content)
      this.reindex()
      return this.notes.get(rel) ?? null
    }
    this.files.add(rel)
    return null
  }

  async create(rel: string, content = ''): Promise<void> {
    const target = this.abs(rel)
    await fs.mkdir(path.dirname(target), { recursive: true })
    try {
      await fs.access(target)
      throw new Error(`${rel} already exists`)
    } catch (e: unknown) {
      if ((e as NodeJS.ErrnoException).code !== 'ENOENT') {
        if (e instanceof Error && e.message.endsWith('already exists')) throw e
      }
    }
    await this.write(rel, content)
  }

  async mkdir(rel: string): Promise<void> {
    await fs.mkdir(this.abs(rel), { recursive: true })
  }

  /** Move a note or folder to the OS trash if possible, else delete. */
  async remove(rel: string, trash: (p: string) => Promise<void>): Promise<void> {
    await trash(this.abs(rel))
    this.notes.delete(rel)
    this.files.delete(rel)
    this.dropContent(rel)
    for (const key of [...this.notes.keys(), ...this.files]) {
      if (key.startsWith(`${rel}/`)) {
        this.notes.delete(key)
        this.files.delete(key)
        this.dropContent(key)
      }
    }
    this.reindex()
  }

  /**
   * Rename a note and update every `[[wikilink]]` pointing at it, the way
   * Obsidian's "Automatically update internal links" does.
   */
  async rename(from: string, to: string): Promise<string[]> {
    const src = this.abs(from)
    const dst = this.abs(to)
    await fs.mkdir(path.dirname(dst), { recursive: true })
    await fs.rename(src, dst)

    const isDir = !this.notes.has(from) && !this.files.has(from)
    if (isDir) {
      const remap = (m: Map<string, NoteMeta> | Set<string>): void => {
        const keys = m instanceof Map ? [...m.keys()] : [...m]
        for (const k of keys) {
          if (k === from || k.startsWith(`${from}/`)) {
            const next = to + k.slice(from.length)
            if (m instanceof Map) {
              const v = m.get(k)!
              v.path = next
              m.delete(k)
              m.set(next, v)
            } else {
              m.delete(k)
              m.add(next)
            }
          }
        }
      }
      remap(this.notes)
      remap(this.files)
      this.reindex()
      return []
    }

    if (this.notes.has(from)) {
      const meta = this.notes.get(from)!
      meta.path = to
      this.notes.delete(from)
      this.notes.set(to, meta)
    } else {
      this.files.delete(from)
      this.files.add(to)
    }

    // `relKey` lowercases for comparison, so the *replacement* text has to come
    // from the path as written — otherwise renaming to `Onyx Desktop.md`
    // rewrites every link as `[[onyx desktop]]`.
    const stripExt = (rel: string): string => {
      const e = extOf(rel)
      return MARKDOWN_EXTS.has(e) ? rel.slice(0, rel.length - e.length - 1) : rel
    }
    const oldName = path.posix.basename(relKey(from))
    const newName = path.posix.basename(stripExt(to))
    const oldRel = relKey(from)
    const newRel = stripExt(to)
    const touched: string[] = []

    if (oldName !== newName || oldRel !== newRel) {
      const referrers = this.backlinks(from)
      for (const ref of referrers) {
        const abs = this.abs(ref)
        let text: string
        try {
          text = await fs.readFile(abs, 'utf8')
        } catch {
          continue
        }
        const updated = rewriteLinks(text, (target) => {
          const nm = noteName(target)
          const rest = target.slice(nm.length)
          const k = nm.toLowerCase()
          if (k === oldRel) return newRel + rest
          if (k === oldName) return newName + rest
          return null
        })
        if (updated !== text) {
          await this.write(ref, updated)
          touched.push(ref)
        }
      }
    }
    this.reindex()
    return touched
  }

  // -------------------------------------------------------------- watching

  /**
   * Start watching the vault.
   *
   * `mode: 'auto'` polls when the vault sits on a filesystem that doesn't
   * deliver change events — a WSL 9P share, `/mnt/c`, an SMB mount. Neither
   * direction of the WSL boundary propagates inotify or
   * ReadDirectoryChangesW, so without this a vault opened across it would
   * silently never refresh.
   */
  watch(mode: 'auto' | 'native' | 'polling' = 'auto'): void {
    if (this.watcher) return
    const polling = mode === 'polling' || (mode === 'auto' && isNetworkPath(this.root))
    this.watchMode = polling ? 'polling' : 'native'
    this.watcher = chokidar.watch(this.root, {
      ignoreInitial: true,
      ignored: (p: string) => {
        const base = path.basename(p)
        return IGNORED_DIRS.has(base) || base.startsWith('.') || base.endsWith('.onyx-tmp')
      },
      awaitWriteFinish: { stabilityThreshold: 120, pollInterval: 40 },
      // Polling a big vault is not free; 2s keeps it responsive enough to feel
      // live without spinning the CPU on a thousand stat() calls.
      usePolling: polling,
      interval: 2000,
      binaryInterval: 4000,
    })
    const onEvent = (kind: 'add' | 'change' | 'unlink') => async (abs: string) => {
      if (!this.contains(abs)) return
      const rel = this.rel(abs)
      if (kind === 'unlink') {
        this.notes.delete(rel)
        this.files.delete(rel)
        this.dropContent(rel)
      } else if (isMarkdown(rel)) {
        try {
          const content = await fs.readFile(abs, 'utf8')
          const st = await fs.stat(abs)
          this.notes.set(rel, parseNote(rel, content, st))
          this.cacheContent(rel, content)
        } catch {
          return
        }
      } else {
        this.files.add(rel)
      }
      this.emit('change', kind, rel)
      this.scheduleSettle()
    }
    this.watcher.on('add', onEvent('add'))
    this.watcher.on('change', onEvent('change'))
    this.watcher.on('unlink', onEvent('unlink'))
    this.watcher.on('addDir', () => this.scheduleSettle())
    this.watcher.on('unlinkDir', () => this.scheduleSettle())
  }

  private scheduleSettle(): void {
    if (this.settleTimer) clearTimeout(this.settleTimer)
    this.settleTimer = setTimeout(() => {
      this.settleTimer = null
      this.reindex()
      this.emit('settled')
    }, 180)
  }

  async close(): Promise<void> {
    if (this.settleTimer) clearTimeout(this.settleTimer)
    await this.watcher?.close()
    this.watcher = null
  }
}

/** Extract every index-relevant fact from a note's text. */
export function parseNote(rel: string, content: string, st?: Stats): NoteMeta {
  const links = extractLinks(content)
  const targets = links.map((l) => noteName(l.target))
  targets.push(...extractMdLinks(content))
  const properties = extractFrontmatterProperties(content).filter(([k]) => {
    const lk = k.toLowerCase()
    return lk !== 'tags' && lk !== 'tag' && lk !== 'aliases' && lk !== 'alias'
  })
  return {
    path: rel,
    title: firstHeading(content) ?? path.posix.basename(rel).replace(/\.[^.]+$/, ''),
    targets: [...new Set(targets.filter(Boolean))],
    outgoing: [],
    unresolved: [],
    tags: extractAllTags(content),
    aliases: extractFrontmatterAliases(content),
    properties,
    mtime: st ? st.mtimeMs : Date.now(),
    size: st ? st.size : Buffer.byteLength(content),
    wordCount: wordCount(content),
  }
}

/**
 * Rewrite every wikilink target in `text` through `map`; returning null from
 * `map` leaves that link alone. Code spans and fences are skipped because
 * `extractLinks` already skips them.
 */
export function rewriteLinks(text: string, map: (target: string) => string | null): string {
  const links = extractLinks(text)
  let out = ''
  let last = 0
  for (const l of links) {
    const next = map(l.target)
    if (next === null) continue
    const bang = l.embed ? '!' : ''
    const alias = l.alias !== null ? `|${l.alias}` : ''
    out += text.slice(last, l.start) + `${bang}[[${next}${alias}]]`
    last = l.end
  }
  return out + text.slice(last)
}

/** Best-effort default vault location, matching the TUI's `~/OnyxVault`. */
export function defaultVaultPath(): string {
  return path.join(os.homedir(), 'OnyxVault')
}
