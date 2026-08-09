/** Left sidebar: file explorer, search, bookmarks, tags — Obsidian's four. */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { FileNode, SearchHit } from '@shared/types'
import { useStore, type LeftPanel } from '../store'
import { Icon, type IconName } from './Icon'
import { runCommand } from '../commands'
import { dirname, joinPath, stem } from '../lib/notes'
import { Resizer } from './Resizer'

const TABS: Array<{ id: LeftPanel; icon: IconName; title: string }> = [
  { id: 'files', icon: 'files', title: 'Files' },
  { id: 'search', icon: 'search', title: 'Search' },
  { id: 'bookmarks', icon: 'star', title: 'Bookmarks' },
  { id: 'tags', icon: 'tag', title: 'Tags' },
]

export function LeftSidebar(): JSX.Element {
  const panel = useStore((s) => s.leftPanel)
  const width = useStore((s) => s.leftWidth)
  const setPanel = useStore((s) => s.setLeftPanel)
  const setWidth = useStore((s) => s.setLeftWidth)

  return (
    <div className="sidebar left" style={{ width, flex: `0 0 ${width}px` }}>
      <div className="sidebar-tabs">
        {TABS.map((t) => (
          <button
            key={t.id}
            className={`sidebar-tab${panel === t.id ? ' is-active' : ''}`}
            title={t.title}
            onClick={() => setPanel(t.id)}
          >
            <Icon name={t.icon} size={15} />
          </button>
        ))}
      </div>
      <div className="sidebar-body">
        {panel === 'files' && <FileExplorer />}
        {panel === 'search' && <SearchPane />}
        {panel === 'bookmarks' && <BookmarksPane />}
        {panel === 'tags' && <TagsPane />}
      </div>
      <Resizer edge="right" value={width} onChange={setWidth} />
    </div>
  )
}

// ---------------------------------------------------------- file explorer

export function FileExplorer(): JSX.Element {
  const tree = useStore((s) => s.tree)
  const vault = useStore((s) => s.vault)
  const activePath = useStore((s) => s.activeTab()?.path)
  const bookmarks = useStore((s) => s.bookmarks)
  const openFile = useStore((s) => s.openFile)
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [renaming, setRenaming] = useState<string | null>(null)
  const [menu, setMenu] = useState<{ x: number; y: number; node: FileNode } | null>(null)
  const [dragOver, setDragOver] = useState<string | null>(null)

  useEffect(() => {
    if (!menu) return
    const close = (): void => setMenu(null)
    window.addEventListener('click', close)
    return () => window.removeEventListener('click', close)
  }, [menu])

  const toggle = (path: string): void => {
    const next = new Set(collapsed)
    if (next.has(path)) next.delete(path)
    else next.add(path)
    setCollapsed(next)
  }

  const rename = async (node: FileNode, name: string): Promise<void> => {
    setRenaming(null)
    if (!name.trim() || name === node.name) return
    const to = joinPath(dirname(node.path), node.isDir ? name.trim() : ensureExt(name.trim(), node.name))
    const touched = await window.onyx.file.rename(node.path, to)
    const st = useStore.getState()
    await st.refreshVault()
    await st.refreshGraph()
    if (st.activeTab()?.path === node.path) void st.openFile(to)
    if (touched.length) st.setStatus(`Updated ${touched.length} link(s)`)
  }

  const move = async (from: string, toFolder: string): Promise<void> => {
    if (from === toFolder || dirname(from) === toFolder) return
    if (toFolder.startsWith(`${from}/`)) return
    const to = joinPath(toFolder, from.split('/').pop()!)
    await window.onyx.file.rename(from, to)
    const st = useStore.getState()
    await st.refreshVault()
    await st.refreshGraph()
  }

  const renderNode = (node: FileNode, depth: number): JSX.Element | null => {
    if (node.path === '' ) {
      return (
        <div key="root">{(node.children ?? []).map((c) => renderNode(c, 0))}</div>
      )
    }
    const isCollapsed = collapsed.has(node.path)
    const isActive = node.path === activePath
    const indent = 6 + depth * 13

    return (
      <div key={node.path}>
        <div
          className={`tree-item${node.isDir ? ' is-folder' : ''}${isActive ? ' is-active' : ''}${dragOver === node.path ? ' is-active' : ''}`}
          style={{ paddingLeft: indent }}
          draggable={renaming !== node.path}
          onDragStart={(e) => e.dataTransfer.setData('text/onyx-path', node.path)}
          onDragOver={(e) => {
            if (!node.isDir) return
            e.preventDefault()
            setDragOver(node.path)
          }}
          onDragLeave={() => setDragOver((d) => (d === node.path ? null : d))}
          onDrop={(e) => {
            setDragOver(null)
            if (!node.isDir) return
            const from = e.dataTransfer.getData('text/onyx-path')
            if (from) void move(from, node.path)
          }}
          onClick={() => (node.isDir ? toggle(node.path) : void openFile(node.path))}
          onContextMenu={(e) => {
            e.preventDefault()
            setMenu({ x: e.clientX, y: e.clientY, node })
          }}
        >
          {node.isDir ? (
            <Icon
              name="chevronDown"
              size={12}
              className={`twisty${isCollapsed ? ' collapsed' : ''}`}
            />
          ) : (
            <span className="twisty" />
          )}
          {renaming === node.path ? (
            <input
              autoFocus
              defaultValue={node.isDir ? node.name : stem(node.name)}
              onBlur={(e) => void rename(node, e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') (e.target as HTMLInputElement).blur()
                if (e.key === 'Escape') setRenaming(null)
              }}
              onClick={(e) => e.stopPropagation()}
            />
          ) : (
            <span className="label">{node.isDir ? node.name : stem(node.name)}</span>
          )}
          {bookmarks.includes(node.path) && <span className="star">★</span>}
        </div>
        {node.isDir && !isCollapsed && (node.children ?? []).map((c) => renderNode(c, depth + 1))}
      </div>
    )
  }

  return (
    <div>
      <div className="pane-title">
        <span>{vault?.name}</span>
        <span className="actions">
          <button title="New note" onClick={() => runCommand('file:new')}>
            <Icon name="newNote" size={14} />
          </button>
          <button title="New folder" onClick={() => runCommand('file:new-folder')}>
            <Icon name="newFolder" size={14} />
          </button>
          <button
            title="Collapse all"
            onClick={() => {
              const all = new Set<string>()
              const walk = (n: FileNode): void => {
                if (n.isDir && n.path) all.add(n.path)
                n.children?.forEach(walk)
              }
              if (tree) walk(tree)
              setCollapsed(collapsed.size ? new Set() : all)
            }}
          >
            <Icon name="collapse" size={14} />
          </button>
        </span>
      </div>
      <div className="tree">{tree ? renderNode(tree, 0) : null}</div>

      {menu && (
        <div className="context-menu" style={{ left: menu.x, top: menu.y }}>
          {!menu.node.isDir && (
            <>
              <button onClick={() => void openFile(menu.node.path, { newTab: true })}>
                Open in new tab
              </button>
              <button
                onClick={() => {
                  useStore.getState().splitPane()
                  void openFile(menu.node.path)
                }}
              >
                Open to the right
              </button>
              <div className="sep" />
            </>
          )}
          {menu.node.isDir && (
            <>
              <button
                onClick={async () => {
                  const path = joinPath(menu.node.path, 'Untitled.md')
                  await window.onyx.file.create(path, '')
                  await useStore.getState().refreshVault()
                  void openFile(path)
                }}
              >
                New note here
              </button>
              <button
                onClick={() =>
                  useStore.getState().setModal({
                    kind: 'prompt',
                    title: 'New folder name',
                    value: '',
                    onSubmit: async (v) => {
                      if (!v.trim()) return
                      await window.onyx.file.mkdir(joinPath(menu.node.path, v.trim()))
                      await useStore.getState().refreshVault()
                    },
                  })
                }
              >
                New folder here
              </button>
              <button
                onClick={() =>
                  useStore.getState().openView('database', {
                    path: menu.node.path,
                    title: `Database: ${menu.node.name}`,
                  })
                }
              >
                Open as database
              </button>
              <div className="sep" />
            </>
          )}
          <button onClick={() => setRenaming(menu.node.path)}>Rename…</button>
          {!menu.node.isDir && (
            <button onClick={() => void useStore.getState().toggleBookmark(menu.node.path)}>
              {useStore.getState().bookmarks.includes(menu.node.path) ? 'Remove bookmark' : 'Bookmark'}
            </button>
          )}
          <button onClick={() => void window.onyx.file.reveal(menu.node.path)}>
            Show in system explorer
          </button>
          <div className="sep" />
          <button
            className="danger"
            onClick={() =>
              useStore.getState().setModal({
                kind: 'confirm',
                title: `Delete ${menu.node.name}?`,
                body: 'It will be moved to the system trash.',
                onConfirm: async () => {
                  await window.onyx.file.remove(menu.node.path)
                  const st = useStore.getState()
                  await st.refreshVault()
                  await st.refreshGraph()
                },
              })
            }
          >
            Delete
          </button>
        </div>
      )}
    </div>
  )
}

function ensureExt(name: string, original: string): string {
  if (/\.[^.]+$/.test(name)) return name
  const ext = original.match(/\.[^.]+$/)?.[0] ?? '.md'
  return name + ext
}

// ----------------------------------------------------------------- search

export function SearchPane({ initial }: { initial?: string } = {}): JSX.Element {
  const [query, setQuery] = useState(initial ?? '')
  const [hits, setHits] = useState<SearchHit[]>([])
  const [busy, setBusy] = useState(false)
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const openFile = useStore((s) => s.openFile)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  useEffect(() => {
    if (!query.trim()) {
      setHits([])
      return
    }
    setBusy(true)
    const timer = setTimeout(async () => {
      try {
        setHits(await window.onyx.search.query(query))
      } finally {
        setBusy(false)
      }
    }, 180)
    return () => clearTimeout(timer)
  }, [query])

  const total = hits.reduce((n, h) => n + h.matches.length, 0)

  return (
    <div className="search-pane">
      <div className="search-input-wrap">
        <Icon name="search" size={13} />
        <input
          ref={inputRef}
          value={query}
          placeholder="Search…  tag: path: file: line:"
          onChange={(e) => setQuery(e.target.value)}
        />
        {busy && <span className="spinner" />}
        {query && (
          <button className="icon-btn" style={{ width: 18, height: 18 }} onClick={() => setQuery('')}>
            <Icon name="close" size={12} />
          </button>
        )}
      </div>
      {query.trim() !== '' && (
        <div className="section-head">
          {hits.length} file{hits.length === 1 ? '' : 's'} · {total} match{total === 1 ? '' : 'es'}
        </div>
      )}
      {hits.map((hit) => {
        const isCollapsed = collapsed.has(hit.path)
        return (
          <div className="search-result" key={hit.path}>
            <div
              className="search-result-head"
              onClick={() => {
                const next = new Set(collapsed)
                if (next.has(hit.path)) next.delete(hit.path)
                else next.add(hit.path)
                setCollapsed(next)
              }}
            >
              <Icon name={isCollapsed ? 'chevronRight' : 'chevronDown'} size={12} />
              <span
                className="label"
                onClick={(e) => {
                  e.stopPropagation()
                  void openFile(hit.path)
                }}
              >
                {hit.title}
              </span>
              <span className="search-result-count">{hit.matches.length}</span>
            </div>
            {!isCollapsed &&
              hit.matches.map((m, i) => (
                <div
                  className="search-match"
                  key={i}
                  onClick={() => void openFile(hit.path)}
                  title={`Line ${m.line + 1}`}
                >
                  {m.text.slice(Math.max(0, m.from - 30), m.from)}
                  <mark>{m.text.slice(m.from, m.to)}</mark>
                  {m.text.slice(m.to, m.to + 80)}
                </div>
              ))}
          </div>
        )
      })}
      {query.trim() && !busy && !hits.length && <div className="modal-empty">No matches</div>}
    </div>
  )
}

// -------------------------------------------------------------- bookmarks

function BookmarksPane(): JSX.Element {
  const bookmarks = useStore((s) => s.bookmarks)
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const toggleBookmark = useStore((s) => s.toggleBookmark)

  return (
    <div>
      <div className="pane-title">Bookmarks</div>
      <div className="list-pane">
        {!bookmarks.length && (
          <div className="empty-note">
            No bookmarks yet — right-click a note in the file explorer to add one.
          </div>
        )}
        {bookmarks.map((path) => (
          <div className="list-row" key={path} onClick={() => void openFile(path)}>
            <Icon name="star" size={13} />
            <span className="label">{notes.get(path)?.title ?? stem(path)}</span>
            <button
              className="icon-btn"
              style={{ width: 18, height: 18, marginLeft: 'auto' }}
              onClick={(e) => {
                e.stopPropagation()
                void toggleBookmark(path)
              }}
            >
              <Icon name="close" size={11} />
            </button>
          </div>
        ))}
      </div>
    </div>
  )
}

// ------------------------------------------------------------------- tags

export function TagsPane(): JSX.Element {
  const notes = useStore((s) => s.notes)
  const setModal = useStore((s) => s.setModal)

  const tags = useMemo(() => {
    const counts = new Map<string, number>()
    for (const meta of notes.values()) {
      for (const t of meta.tags) counts.set(t, (counts.get(t) ?? 0) + 1)
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
  }, [notes])

  return (
    <div>
      <div className="pane-title">Tags</div>
      <div className="list-pane">
        {!tags.length && <div className="empty-note">No tags in this vault yet.</div>}
        {tags.map(([tag, count]) => (
          <div
            className="list-row"
            key={tag}
            onClick={() => setModal({ kind: 'search', initial: `tag:${tag}` })}
          >
            <span className="label" style={{ color: 'var(--tag)' }}>
              #{tag}
            </span>
            <span className="count">{count}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
