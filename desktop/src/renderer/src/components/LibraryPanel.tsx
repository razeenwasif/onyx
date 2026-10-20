/**
 * The Library: the left-hand side as one sidebar for everything you can open.
 *
 *   Today        the home view, with how many tasks are open
 *   Pinned       bookmarked notes
 *   Notes        the vault's file tree
 *   Ink          Scribe's notebooks, by folder; one opens its latest page
 *   Scratch pad  the quick note (`.onyx/quicknote.md`), folded away
 *
 * At the foot: the vault's name (click to open another) and settings.
 *
 * Sections fold by their heading; which are folded is remembered.
 */

import { useEffect, useMemo, useState } from 'react'
import type { ScribePage } from '@shared/types'
import { useStore } from '../store'
import { runCommand } from '../commands'
import { formatDate, stem } from '../lib/notes'
import { Icon } from './Icon'
import { Resizer } from './Resizer'
import { FileExplorer } from './LeftSidebar'
import { QuicknotePane } from './TodoPane'

type SectionKey = 'pinned' | 'notes' | 'ink' | 'scratch'

function readFolded(): Set<string> {
  try {
    return new Set(JSON.parse(localStorage.getItem('libraryFolded') ?? '["scratch"]') as string[])
  } catch {
    return new Set(['scratch'])
  }
}

export function LibraryPanel(): JSX.Element {
  const width = useStore((s) => s.leftWidth)
  const setWidth = useStore((s) => s.setLeftWidth)
  const [folded, setFolded] = useState<Set<string>>(readFolded)

  const toggle = (key: string): void => {
    const next = new Set(folded)
    if (next.has(key)) next.delete(key)
    else next.add(key)
    setFolded(next)
    try {
      localStorage.setItem('libraryFolded', JSON.stringify([...next]))
    } catch {
      /* a convenience only */
    }
  }

  const head = (key: SectionKey, title: string, extra?: React.ReactNode, actions?: React.ReactNode): JSX.Element => (
    <div className="lib-head">
      <button type="button" className="lib-head-btn" aria-expanded={!folded.has(key)} onClick={() => toggle(key)}>
        <Icon name={folded.has(key) ? 'chevronRight' : 'chevronDown'} size={11} />
        <span>{title}</span>
        {extra}
      </button>
      {actions && <span className="lib-actions">{actions}</span>}
    </div>
  )

  return (
    <aside className="sidebar left library" style={{ width, flex: `0 0 ${width}px` }} aria-label="Library">
      <div className="library-inner">
        <TodayRow />

        <section className="lib-section">
          {head('pinned', 'Pinned')}
          {!folded.has('pinned') && <Pinned />}
        </section>

        <section className="lib-section lib-notes">
          {head(
            'notes',
            'Notes',
            <NoteCount />,
            <>
              <button type="button" className="icon-btn" title="New note" aria-label="New note" onClick={() => runCommand('file:new')}>
                <Icon name="newNote" size={13} />
              </button>
              <button
                type="button"
                className="icon-btn"
                title="New folder"
                aria-label="New folder"
                onClick={() => runCommand('file:new-folder')}
              >
                <Icon name="newFolder" size={13} />
              </button>
            </>,
          )}
          {!folded.has('notes') && (
            <div className="lib-tree">
              <FileExplorer />
            </div>
          )}
        </section>

        <InkSection folded={folded} head={head} />

        <section className="lib-section">
          {head('scratch', 'Scratch pad')}
          {!folded.has('scratch') && (
            <div className="lib-scratch">
              <QuicknotePane />
            </div>
          )}
        </section>
        <VaultFoot />
      </div>
      <Resizer edge="right" value={width} onChange={setWidth} />
    </aside>
  )
}

function VaultFoot(): JSX.Element {
  const vault = useStore((s) => s.vault)
  return (
    <div className="lib-foot">
      <button
        type="button"
        className="lib-vault"
        title={`${vault?.root ?? ''}\nOpen another vault…`}
        onClick={() => runCommand('vault:open')}
      >
        <Icon name="vault" size={14} />
        <span className="lib-row-label">{vault?.name ?? 'Vault'}</span>
        <Icon name="chevronDown" size={11} />
      </button>
      <button
        type="button"
        className="icon-btn"
        title="Settings"
        aria-label="Settings"
        onClick={() => runCommand('settings:open')}
      >
        <Icon name="settings" size={15} />
      </button>
    </div>
  )
}

function NoteCount(): JSX.Element {
  const count = useStore((s) => [...s.notes.keys()].filter((p) => !p.startsWith('.onyx/')).length)
  return <span className="lib-count">{count}</span>
}

/** Today, with how many tasks are open across the vault. */
function TodayRow(): JSX.Element {
  const notes = useStore((s) => s.notes)
  const active = useStore((s) => {
    const pane = s.panes.find((p) => p.id === s.activePaneId)
    return pane?.tabs.find((t) => t.id === pane.activeTabId)?.type === 'empty'
  })
  const [open, setOpen] = useState<number | null>(null)
  const now = new Date()

  useEffect(() => {
    let stale = false
    void window.onyx.search
      .tasks()
      .then((t) => !stale && setOpen(t.length))
      .catch(() => undefined)
    return () => {
      stale = true
    }
  }, [notes])

  return (
    <button
      type="button"
      className={`lib-today${active ? ' is-active' : ''}`}
      onClick={() => runCommand('today:open')}
    >
      <Icon name="calendar" size={15} />
      <span className="lib-today-label">
        {formatDate(now, 'dddd')} {now.getDate()} {formatDate(now, 'MMMM')}
      </span>
      {open ? <span className="lib-count">{open} open</span> : null}
    </button>
  )
}

function Pinned(): JSX.Element {
  const bookmarks = useStore((s) => s.bookmarks)
  const notes = useStore((s) => s.notes)
  const openFile = useStore((s) => s.openFile)
  const activePath = useStore((s) => s.activeTab()?.path)
  if (!bookmarks.length) {
    return <div className="lib-empty">Pin a note with ⌘K → “Toggle bookmark”, or right-click it in Notes.</div>
  }
  return (
    <div className="lib-list">
      {bookmarks.map((path) => (
        <button
          key={path}
          type="button"
          className={`lib-row${path === activePath ? ' is-active' : ''}`}
          onClick={() => void openFile(path)}
        >
          <Icon name="star" size={13} />
          <span className="lib-row-label">{notes.get(path)?.title ?? stem(path)}</span>
        </button>
      ))}
    </div>
  )
}

interface InkNotebook {
  key: string
  name: string
  count: number
  latest: ScribePage
}

/** Scribe's notebooks under their folders, each opening its latest page. */
function InkSection({
  folded,
  head,
}: {
  folded: Set<string>
  head: (key: SectionKey, title: string, extra?: React.ReactNode, actions?: React.ReactNode) => JSX.Element
}): JSX.Element | null {
  const pages = useStore((s) => s.scribePages)
  // Which folders are open; until you choose, the one written in last.
  const [openFolders, setOpenFolders] = useState<Set<string> | null>(() => {
    try {
      const saved = localStorage.getItem('libraryInkOpen')
      return saved ? new Set(JSON.parse(saved) as string[]) : null
    } catch {
      return null
    }
  })

  const folders = useMemo(() => {
    const byFolder = new Map<string, Map<string, InkNotebook>>()
    for (const page of pages.values()) {
      let books = byFolder.get(page.notebook)
      if (!books) byFolder.set(page.notebook, (books = new Map()))
      const book = books.get(page.section)
      if (!book) books.set(page.section, { key: `${page.notebook}/${page.section}`, name: page.section, count: 1, latest: page })
      else {
        book.count++
        if (page.modified > book.latest.modified) book.latest = page
      }
    }
    return [...byFolder.entries()]
      .map(([name, books]) => ({
        name,
        books: [...books.values()].sort((a, b) => b.latest.modified - a.latest.modified),
      }))
      .sort((a, b) => b.books[0].latest.modified - a.books[0].latest.modified)
  }, [pages])

  const isOpen = (name: string): boolean => (openFolders ? openFolders.has(name) : name === folders[0]?.name)
  const flip = (name: string): void => {
    const next = new Set(openFolders ?? (folders[0] ? [folders[0].name] : []))
    if (next.has(name)) next.delete(name)
    else next.add(name)
    setOpenFolders(next)
    try {
      localStorage.setItem('libraryInkOpen', JSON.stringify([...next]))
    } catch {
      /* a convenience only */
    }
  }

  if (!pages.size) return null
  return (
    <section className="lib-section">
      {head('ink', 'Ink', <span className="lib-count">in Scribe</span>)}
      {!folded.has('ink') && (
        <div className="lib-list">
          {folders.map((folder) => {
            const open = isOpen(folder.name)
            return (
              <div key={folder.name}>
                <button
                  type="button"
                  className="lib-row lib-folder"
                  aria-expanded={open}
                  onClick={() => flip(folder.name)}
                >
                  <Icon name={open ? 'chevronDown' : 'chevronRight'} size={11} />
                  <span className="lib-row-label">{folder.name}</span>
                </button>
                {open &&
                  folder.books.map((book) => (
                    <button
                      key={book.key}
                      type="button"
                      className="lib-row lib-book"
                      title={`Open the latest page: ${book.latest.title}`}
                      onClick={() => void window.onyx.apps.scribeOpen(book.latest.path)}
                    >
                      <span className="lib-ink-mark" aria-hidden="true" />
                      <span className="lib-row-label">{book.name}</span>
                      <span className="lib-count">{book.count}</span>
                    </button>
                  ))}
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}
